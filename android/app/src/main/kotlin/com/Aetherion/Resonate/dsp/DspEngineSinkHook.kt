package com.aetherion.resonate.dsp

import androidx.media3.common.audio.AudioProcessor
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Factory for native DSP AudioProcessors installed in Media3 DefaultAudioSink.
 *
 * Media3 calls the deck-aware [createProcessors] overload once per deck, so dual
 * playback receives independent DSP processors and native handles for A and B.
 * The legacy just_audio overload deliberately returns no processors: that
 * backend now carries only voice/SFX output and must bypass music DSP.
 *
 * Crash history (2026-09-28): old JNI called dsp_create(double, int) but the
 * real ABI is dsp_create(const DspConfig*). That treated the sample-rate bits
 * as a pointer → SIGSEGV in dsp_create+36. JNI was corrected to build a
 * DspConfig and pass &cfg; native can be ON again.
 */
object DspEngineSinkHook {
    private const val TAG = "DspEngineSinkHook"

    /**
     * Master switch for live native EQ/DVC.
     * Requires libdsp_engine.so in the APK and ABI-matched JNI.
     */
    private const val ENABLE_NATIVE_LIVE_DSP = true
    private val processorsByDeck = ConcurrentHashMap<String, CopyOnWriteArraySet<DspEngineAudioProcessor>>()
    private val scratchProcessorsByDeck =
        ConcurrentHashMap<String, CopyOnWriteArraySet<DjScratchTimestampProcessor>>()
    // Tracks the service's physical active/fading roles, not only the single
    // canonical MediaSession deck. A fading incoming deck must remain active.
    private val activeDecks = CopyOnWriteArraySet<String>().apply {
        add("A")
        add("legacy")
    }

    private fun isDeckActive(deckId: String): Boolean =
        deckId == "legacy" || activeDecks.contains(deckId)

    internal fun resetForTests() {
        processorsByDeck.clear()
        scratchProcessorsByDeck.clear()
        activeDecks.clear()
        activeDecks.add("A")
        activeDecks.add("legacy")
    }

    /**
     * The legacy just_audio backend is no longer a music-playback authority.
     * Its remaining production use is short voice/SFX playback, which must stay
     * outside the music DSP chain (EQ, DVC, limiter and deck analysis). Media3
     * deck processors are created through the explicit deckId overload below.
     */
    @JvmStatic
    fun createProcessors(): Array<AudioProcessor> = emptyArray()

    @JvmStatic
    fun createProcessors(deckId: String): Array<AudioProcessor> =
        if (deckId == "legacy") emptyArray() else createDspProcessors(deckId)

    /** Media3-only chain: timestamp probe first, then the unchanged native DSP stage. */
    @JvmStatic
    internal fun createProcessors(
        deckId: String,
        timestampLedger: DjScratchTimestampLedger,
        controlMailbox: DjScratchControlMailbox,
    ): Array<AudioProcessor> {
        return try {
            val timestampProcessor = DjScratchTimestampProcessor(timestampLedger, controlMailbox, deckId)
            val dspProcessor = createDspProcessor(deckId)
            arrayOf(timestampProcessor, dspProcessor)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to create timestamp-aware DJ processor chain", t)
            emptyArray()
        }
    }

    private fun createDspProcessors(deckId: String): Array<AudioProcessor> = try {
        arrayOf(createDspProcessor(deckId))
    } catch (t: Throwable) {
        Log.e(TAG, "Failed to create DspEngineAudioProcessor", t)
        emptyArray()
    }

    private fun createDspProcessor(deckId: String): DspEngineAudioProcessor {
        val allow = ENABLE_NATIVE_LIVE_DSP && DspSessionGate.isNativeAllowed()
        val proc = DspEngineAudioProcessor(deckId)
        proc.setNativeProcessEnabled(allow)
        proc.setDeckActive(isDeckActive(deckId))
        processorsByDeck.computeIfAbsent(deckId) { CopyOnWriteArraySet() }.add(proc)
        val active = DspEngineRegistry.activeCount()
        Log.i(
            TAG,
            "Injected native DSP processor native=${if (allow) "ON" else "pass-through"} " +
                "deck=$deckId registry_active=$active"
        )
        return proc
    }

    /** Re-registers a processor if Media3 resets and later reconfigures its sink. */
    @JvmStatic
    fun trackProcessor(processor: DspEngineAudioProcessor, deckId: String) {
        processorsByDeck.computeIfAbsent(deckId) { CopyOnWriteArraySet() }.add(processor)
        // Media3 can reset and later reconfigure the same AudioProcessor after
        // a queue clear. Reconcile its logical role at configuration time:
        // the earlier activateDeck() may have run while this processor was
        // temporarily absent from the registry after onReset().
        processor.setDeckActive(isDeckActive(deckId))
    }

    /** Tracks the timestamp-aware scratch processor for per-deck diagnostics. */
    @JvmStatic
    fun trackScratchProcessor(processor: DjScratchTimestampProcessor, deckId: String) {
        scratchProcessorsByDeck.computeIfAbsent(deckId) { CopyOnWriteArraySet() }.add(processor)
    }

    /** Latest scratch pipeline counters; no PCM data is exposed or retained here. */
    @JvmStatic
    fun scratchDiagnostics(deckId: String): Map<String, Any?> {
        val processor = scratchProcessorsByDeck[deckId]?.lastOrNull()
        return processor?.diagnosticsSnapshot() ?: mapOf(
            "processorPresent" to false,
            "deckId" to deckId,
        )
    }

    /** Drops all processor references when the owning ExoPlayer is released. */
    @JvmStatic
    fun forgetDeck(deckId: String) {
        processorsByDeck.remove(deckId)
        scratchProcessorsByDeck.remove(deckId)
    }

    /** Removes released processor instances so a stale deck cannot be reactivated. */
    @JvmStatic
    fun forgetProcessor(processor: DspEngineAudioProcessor) {
        processorsByDeck.values.forEach { it.remove(processor) }
    }

    @JvmStatic
    fun forgetScratchProcessor(processor: DjScratchTimestampProcessor) {
        scratchProcessorsByDeck.values.forEach { it.remove(processor) }
    }

    /** Activates a deck's native handle immediately before it is allowed to output. */
    @JvmStatic
    fun activateDeck(deckId: String) {
        activeDecks.add(deckId)
        processorsByDeck[deckId]?.forEach { it.setDeckActive(true) }
    }

    /** Releases a deck's native handle while its ExoPlayer remains reusable as standby. */
    @JvmStatic
    fun suspendDeck(deckId: String) {
        activeDecks.remove(deckId)
        processorsByDeck[deckId]?.forEach { it.setDeckActive(false) }
    }
}
