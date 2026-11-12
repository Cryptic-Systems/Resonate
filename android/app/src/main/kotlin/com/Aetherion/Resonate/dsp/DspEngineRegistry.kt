package com.aetherion.resonate.dsp

import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.pow

/**
 * Live native engine handles for dual-player (A/B) sinks.
 *
 * Sticky DSP settings: when player B is created mid-session, [register] reapplies
 * the last UI settings so both engines stay in sync during crossfade. Registration,
 * unregistration, and updates share the object monitor: otherwise an update can race
 * between sticky-state capture and handle publication and leave the new engine stale.
 */
object DspEngineRegistry {
    private const val TAG = "DspEngineRegistry"

    private data class RegisteredEngine(val handle: Long, val deckId: String)
    private data class EqOverlay(val centersHz: DoubleArray, val gainsDb: DoubleArray)

    private val handles = ConcurrentHashMap<Int, RegisteredEngine>()
    private val temporaryEqOverlays = mutableMapOf<String, EqOverlay>()
    private var activeDeckId: String = "A"

    /** Small native seam so registry inheritance can be tested without loading JNI in JVM tests. */
    internal interface NativeDspApi {
        fun setEnabled(handle: Long, enabled: Boolean)
        fun setProcessingEnabled(handle: Long, enabled: Boolean)
        fun setVolume(handle: Long, linearGain: Double)
        fun setEqBands(handle: Long, centersHz: DoubleArray?, gainsDb: DoubleArray, enabled: Boolean)
        fun setSpeakerMode(handle: Long, enabled: Boolean)
        fun setVirtualBass(handle: Long, amount: Double)
        fun setPreamp(handle: Long, linearGain: Double)
        fun setLimiterCeiling(handle: Long, highDb: Float, lowDb: Float)
        fun setCrossoverHz(handle: Long, freqHz: Float)
    }

    private val jniApi = object : NativeDspApi {
        override fun setEnabled(handle: Long, enabled: Boolean) = DspEngineJni.nativeSetEnabled(handle, enabled)
        override fun setProcessingEnabled(handle: Long, enabled: Boolean) = DspEngineJni.nativeSetProcessingEnabled(handle, enabled)
        override fun setVolume(handle: Long, linearGain: Double) = DspEngineJni.nativeSetVolume(handle, linearGain)
        override fun setEqBands(handle: Long, centersHz: DoubleArray?, gainsDb: DoubleArray, enabled: Boolean) =
            DspEngineJni.nativeSetEqBands(handle, centersHz, gainsDb, enabled)
        override fun setSpeakerMode(handle: Long, enabled: Boolean) = DspEngineJni.nativeSetSpeakerMode(handle, enabled)
        override fun setVirtualBass(handle: Long, amount: Double) = DspEngineJni.nativeSetVirtualBass(handle, amount)
        override fun setPreamp(handle: Long, linearGain: Double) = DspEngineJni.nativeSetPreamp(handle, linearGain)
        override fun setLimiterCeiling(handle: Long, highDb: Float, lowDb: Float) =
            DspEngineJni.nativeSetLimiterCeiling(handle, highDb, lowDb)
        override fun setCrossoverHz(handle: Long, freqHz: Float) = DspEngineJni.nativeSetCrossoverHz(handle, freqHz)
    }

    @Volatile
    internal var nativeApi: NativeDspApi = jniApi

    /**
     * One immutable generation of DSP settings. Publishing the whole state through
     * one volatile reference prevents a newly-created A/B engine from observing a
     * mixed generation (for example, new EQ with old preamp) during rapid UI changes.
     */
    private data class StickyState(
        val linearGain: Double = 1.0,
        val eqEnabled: Boolean = true,
        val dspEnabled: Boolean = true,
        val centersHz: DoubleArray? = null,
        val gainsDb: DoubleArray? = null,
        val speakerMode: Boolean = false,
        val virtualBass: Double = 0.55,
        val preamp: Double = 1.0,
        val limiterHigh: Float = -0.5f,
        val limiterLow: Float = -0.2f,
        val crossoverHz: Float = 120f,
    )

    @Volatile
    private var stickyState = StickyState()

    @JvmStatic
    @Synchronized
    fun register(processorId: Int, handle: Long, deckId: String = "A"): Boolean {
        if (handle == 0L || deckId !in setOf("A", "B")) return false

        // Configure the new engine before publishing it to the live registry.
        // If JNI configuration fails, the caller still owns the handle and can
        // destroy it safely; the registry never exposes a partially configured
        // engine to A/B-wide setting updates.
        if (!applyStickyToHandle(handle, deckId)) {
            Log.w(TAG, "reject id=$processorId handle=$handle: sticky configuration failed")
            return false
        }

        handles[processorId] = RegisteredEngine(handle, deckId)
        Log.i(TAG, "register id=$processorId handle=$handle active=${handles.size}")
        return true
    }

    @Synchronized
    internal fun resetForTests() {
        handles.clear()
        stickyState = StickyState()
        temporaryEqOverlays.clear()
        activeDeckId = "A"
        nativeApi = jniApi
    }

    @JvmStatic
    @Synchronized
    fun unregister(processorId: Int) {
        val engine = handles.remove(processorId)
        Log.i(TAG, "unregister id=$processorId handle=${engine?.handle} active=${handles.size}")
    }

    @JvmStatic
    fun activeCount(): Int = handles.size

    @JvmStatic
    fun snapshotHandles(): List<Long> = handles.values.map { it.handle }.filter { it != 0L }

    /** Phone-speaker delivery: HPF + virtual bass + tighter limiter. */
    @JvmStatic
    @Synchronized
    fun applySpeakerModeAll(enabled: Boolean) {
        stickyState = stickyState.copy(speakerMode = enabled)
        val list = snapshotHandles()
        for (h in list) {
            try {
                nativeApi.setSpeakerMode(h, enabled)
                nativeApi.setVirtualBass(h, stickyState.virtualBass)
            } catch (t: Throwable) {
                Log.w(TAG, "setSpeakerMode failed handle=$h", t)
            }
        }
        Log.i(TAG, "applySpeakerModeAll enabled=$enabled targets=${list.size}")
    }

    @JvmStatic
    @Synchronized
    fun applyVirtualBassAll(amount: Double) {
        stickyState = stickyState.copy(virtualBass = amount.coerceIn(0.0, 1.0))
        if (!stickyState.speakerMode) return
        val list = snapshotHandles()
        for (h in list) {
            try {
                nativeApi.setVirtualBass(h, stickyState.virtualBass)
            } catch (t: Throwable) {
                Log.w(TAG, "setVirtualBass failed handle=$h", t)
            }
        }
    }

    /** Aggregate Phase-2 latency across all live engines. */
    @JvmStatic
    fun latencySnapshot(): Map<String, Any> {
        var calls = 0.0
        var avgUs = 0.0
        var maxUs = 0.0
        var overruns = 0.0
        var lastFrames = 0.0
        var sampleRate = 0.0
        var n = 0
        for (h in snapshotHandles()) {
            try {
                val s = DspEngineJni.nativeGetStats(h) ?: continue
                if (s.size < 6) continue
                calls += s[0]
                avgUs += s[1]
                if (s[2] > maxUs) maxUs = s[2]
                overruns += s[3]
                lastFrames = s[4]
                sampleRate = s[5]
                n++
            } catch (_: Throwable) {
            }
        }
        if (n > 0) avgUs /= n.toDouble()
        return mapOf(
            "processCalls" to calls,
            "avgUs" to avgUs,
            "maxUs" to maxUs,
            "overruns" to overruns,
            "lastFrames" to lastFrames,
            "sampleRate" to sampleRate,
            "engines" to n,
        )
    }

    @JvmStatic
    fun statusMap(): Map<String, Any> {
        val base = mutableMapOf<String, Any>(
            "activeEngines" to activeCount(),
            "gateTripped" to DspSessionGate.isTripped(),
            "nativeAllowed" to DspSessionGate.isNativeAllowed(),
            "linearGain" to stickyState.linearGain,
            "eqEnabled" to stickyState.eqEnabled,
            "dspEnabled" to stickyState.dspEnabled,
            "eqBands" to (stickyState.gainsDb?.size ?: 0),
            "speakerMode" to stickyState.speakerMode,
            "virtualBass" to stickyState.virtualBass,
            // These are the registry's last-requested values and the defaults
            // inherited by new engines, not a hardware measurement.
            "preampLinearGain" to stickyState.preamp,
            "limiterHighDb" to stickyState.limiterHigh,
            "limiterLowDb" to stickyState.limiterLow,
            "crossoverHz" to stickyState.crossoverHz,
        )
        base.putAll(latencySnapshot())
        return base
    }


    /** Master native DSP enable; independent from EQ-band enable and DVC gain. */
    @JvmStatic
    @Synchronized
    fun applyEnabledAll(enabled: Boolean) {
        // Compatibility entry point only: Resonate's processing chain is
        // intentionally always on. No caller can bypass EQ/DSP at runtime.
        stickyState = stickyState.copy(dspEnabled = true, eqEnabled = true)
        val state = stickyState
        val engines = handles.values.toList()
        for (engine in engines) {
            try {
                nativeApi.setProcessingEnabled(engine.handle, true)
                val gains = state.gainsDb
                if (gains != null && gains.isNotEmpty() || temporaryEqOverlays.containsKey(engine.deckId)) {
                    applyEqForEngine(engine.handle, engine.deckId, state)
                } else {
                    nativeApi.setEnabled(engine.handle, true)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "applyEnabledAll failed handle=${engine.handle}", t)
            }
        }
        Log.i(TAG, "applyEnabledAll forced-on (requested=$enabled) targets=${engines.size}")
    }

    /** True preamp (v0.4) — separate from DVC/volume. */
    @JvmStatic
    @Synchronized
    fun applyPreampAll(linearGain: Double) {
        val g = linearGain.coerceIn(0.0, 4.0)
        stickyState = stickyState.copy(preamp = g)
        val list = snapshotHandles()
        for (h in list) {
            try {
                nativeApi.setPreamp(h, g)
            } catch (t: Throwable) {
                Log.w(TAG, "setPreamp failed handle=$h", t)
            }
        }
        Log.i(TAG, "applyPreampAll gain=$g targets=${list.size}")
    }

    @JvmStatic
    @Synchronized
    fun applyLimiterCeilingAll(highDb: Float, lowDb: Float) {
        stickyState = stickyState.copy(limiterHigh = highDb.coerceIn(-6f, -0.1f), limiterLow = lowDb.coerceIn(-6f, -0.1f))
        val list = snapshotHandles()
        for (h in list) {
            try {
                nativeApi.setLimiterCeiling(h, stickyState.limiterHigh, stickyState.limiterLow)
            } catch (t: Throwable) {
                Log.w(TAG, "setLimiter failed handle=$h", t)
            }
        }
    }

    @JvmStatic
    @Synchronized
    fun applyCrossoverHzAll(hz: Float) {
        stickyState = stickyState.copy(crossoverHz = hz.coerceIn(80f, 200f))
        val list = snapshotHandles()
        for (h in list) {
            try {
                nativeApi.setCrossoverHz(h, stickyState.crossoverHz)
            } catch (t: Throwable) {
                Log.w(TAG, "setCrossover failed handle=$h", t)
            }
        }
    }

    /** Preamp / DVC — linear gain (1.0 = unity). Call off the audio thread. */
    @JvmStatic
    @Synchronized
    fun applyVolumeAll(linearGain: Double) {
        val g = linearGain.coerceIn(0.0, 4.0)
        stickyState = stickyState.copy(linearGain = g)
        val list = snapshotHandles()
        for (h in list) {
            try {
                nativeApi.setVolume(h, g)
            } catch (t: Throwable) {
                Log.w(TAG, "setVolume failed handle=$h", t)
            }
        }
        Log.i(TAG, "applyVolumeAll gain=$g targets=${list.size}")
    }

    /** Studio curve → all live engines. */
    @JvmStatic
    @Synchronized
    fun applyEqBandsAll(centersHz: DoubleArray?, gainsDb: DoubleArray, enabled: Boolean) {
        // `enabled` is the persisted EQ preference, not the effective gate.
        // Master DSP can be off while EQ remains selected for the next enable.
        stickyState = stickyState.copy(
            eqEnabled = true,
            dspEnabled = true,
            centersHz = centersHz?.copyOf(),
            gainsDb = gainsDb.copyOf(),
        )
        val state = stickyState
        val effectiveEqEnabled = true
        val engines = handles.values.toList()
        for (engine in engines) {
            try {
                applyEqForEngine(engine.handle, engine.deckId, state)
            } catch (t: Throwable) {
                Log.w(TAG, "setEqBands failed handle=${engine.handle}", t)
            }
        }
        Log.i(TAG, "applyEqBandsAll bands=${gainsDb.size} eqEnabled=$enabled effective=$effectiveEqEnabled targets=${engines.size}")
    }


    /**
     * The active/standby labels are logical roles. The service updates this
     * mapping when its two ExoPlayers exchange roles after a completed fade.
     */
    @JvmStatic
    @Synchronized
    fun setActiveDeck(deckId: String): Boolean {
        if (deckId !in setOf("A", "B")) return false
        activeDeckId = deckId
        return true
    }

    @JvmStatic
    @Synchronized
    fun setTemporaryEqOverlay(
        deckRole: String,
        centersHz: DoubleArray,
        gainsDb: DoubleArray,
    ): Boolean {
        if (deckRole !in setOf("active", "standby") ||
            centersHz.isEmpty() || centersHz.size != gainsDb.size ||
            centersHz.size > 31 ||
            centersHz.any { !it.isFinite() || it !in 20.0..20000.0 } ||
            gainsDb.any { !it.isFinite() || it !in -12.0..12.0 }
        ) return false

        val deckId = if (deckRole == "active") activeDeckId else if (activeDeckId == "A") "B" else "A"
        val overlay = EqOverlay(centersHz.copyOf(), gainsDb.copyOf())
        temporaryEqOverlays[deckId] = overlay
        val state = stickyState
        for (engine in handles.values.filter { it.deckId == deckId }) {
            try {
                applyEqForEngine(engine.handle, deckId, state)
            } catch (t: Throwable) {
                Log.w(TAG, "setTemporaryEqOverlay failed deck=$deckRole handle=${engine.handle}", t)
                return false
            }
        }
        return true
    }

    @JvmStatic
    @Synchronized
    fun clearTemporaryEqOverlay(deckRole: String): Boolean {
        if (deckRole !in setOf("active", "standby")) return false
        val deckId = if (deckRole == "active") activeDeckId else if (activeDeckId == "A") "B" else "A"
        temporaryEqOverlays.remove(deckId)
        val state = stickyState
        for (engine in handles.values.filter { it.deckId == deckId }) {
            try {
                val gains = state.gainsDb
                if (gains != null && gains.isNotEmpty()) {
                    nativeApi.setEqBands(engine.handle, state.centersHz, gains, true)
                } else {
                    // Restore a neutral 31-band curve when there is no saved
                    // user curve, rather than leaving the last DJ filter active.
                    val centers = defaultCenters(31)
                    nativeApi.setEqBands(engine.handle, centers, DoubleArray(31), true)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "clearTemporaryEqOverlay failed deck=$deckRole handle=${engine.handle}", t)
                return false
            }
        }
        return true
    }

    @JvmStatic
    @Synchronized
    fun clearAllTemporaryEqOverlays() {
        clearTemporaryEqOverlay("active")
        clearTemporaryEqOverlay("standby")
    }

    private fun applyEqForEngine(handle: Long, deckId: String, state: StickyState) {
        val base = state.gainsDb
        val overlay = temporaryEqOverlays[deckId]
        if (overlay == null) {
            if (base != null && base.isNotEmpty()) {
                nativeApi.setEqBands(handle, state.centersHz, base, true)
            }
            return
        }
        if (base.isNullOrEmpty()) {
            nativeApi.setEqBands(handle, overlay.centersHz, overlay.gainsDb, true)
            return
        }
        val centers = state.centersHz?.takeIf { it.size >= base.size }?.copyOf(base.size)
            ?: defaultCenters(base.size)
        val combined = DoubleArray(base.size) { index ->
            (base[index] + interpolateDb(overlay, centers[index])).coerceIn(-24.0, 24.0)
        }
        nativeApi.setEqBands(handle, centers, combined, true)
    }

    private fun interpolateDb(overlay: EqOverlay, frequencyHz: Double): Double {
        val pairs = overlay.centersHz.indices
            .map { overlay.centersHz[it] to overlay.gainsDb[it] }
            .sortedBy { it.first }
        if (frequencyHz <= pairs.first().first) return pairs.first().second
        if (frequencyHz >= pairs.last().first) return pairs.last().second
        for (index in 0 until pairs.lastIndex) {
            val (lowHz, lowDb) = pairs[index]
            val (highHz, highDb) = pairs[index + 1]
            if (frequencyHz in lowHz..highHz) {
                val fraction = (kotlin.math.ln(frequencyHz) - kotlin.math.ln(lowHz)) /
                    (kotlin.math.ln(highHz) - kotlin.math.ln(lowHz))
                return lowDb + (highDb - lowDb) * fraction
            }
        }
        return 0.0
    }

    private fun defaultCenters(count: Int): DoubleArray =
        DoubleArray(count) { index ->
            20.0 * 1000.0.pow(index.toDouble() / (count - 1).coerceAtLeast(1))
        }

    private fun applyStickyToHandle(handle: Long, deckId: String): Boolean {
        val state = stickyState
        try {
            nativeApi.setVolume(handle, state.linearGain)
            nativeApi.setProcessingEnabled(handle, state.dspEnabled)
            val gains = state.gainsDb
            if (gains != null && gains.isNotEmpty()) {
                applyEqForEngine(handle, deckId, state)
            } else {
                // With no persistent curve, a deck-local overlay can still
                // provide its own EQ curve. Otherwise keep the native EQ gate
                // enabled and leave the processor's flat default untouched.
                val overlay = temporaryEqOverlays[deckId]
                if (overlay != null) {
                    nativeApi.setEqBands(handle, overlay.centersHz, overlay.gainsDb, true)
                } else {
                    nativeApi.setEnabled(handle, state.eqEnabled && state.dspEnabled)
                }
            }
            nativeApi.setSpeakerMode(handle, state.speakerMode)
            nativeApi.setVirtualBass(handle, state.virtualBass)
            nativeApi.setPreamp(handle, state.preamp)
            nativeApi.setLimiterCeiling(handle, state.limiterHigh, state.limiterLow)
            nativeApi.setCrossoverHz(handle, state.crossoverHz)
        } catch (t: Throwable) {
            Log.w(TAG, "applySticky failed handle=$handle", t)
            return false
        }
        return true
    }
}
