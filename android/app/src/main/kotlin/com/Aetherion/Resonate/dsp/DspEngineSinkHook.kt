package com.aetherion.resonate.dsp

import androidx.media3.common.audio.AudioProcessor
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Factory for native DSP AudioProcessors installed in Media3 DefaultAudioSink.
 *
 * Media3 calls [createProcessors] once per deck, so dual playback receives
 * independent DSP processors and native handles for decks A and B. The
 * no-argument overload remains as compatibility for the legacy just_audio
 * injection hook while that backend is being retired.
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
        activeDecks.clear()
        activeDecks.add("A")
        activeDecks.add("legacy")
    }

    /** Compatibility overload used only by the legacy just_audio sink patch. */
    @JvmStatic
    fun createProcessors(): Array<AudioProcessor> = createProcessors("legacy")

    @JvmStatic
    fun createProcessors(deckId: String): Array<AudioProcessor> =
        createDspProcessors(deckId)

    /** Media3-only chain: timestamp probe first, then the unchanged native DSP stage. */
    @JvmStatic
    internal fun createProcessors(
        deckId: String,
        timestampLedger: DjScratchTimestampLedger,
        controlMailbox: DjScratchControlMailbox,
    ): Array<AudioProcessor> {
        return try {
            val timestampProcessor = DjScratchTimestampProcessor(timestampLedger, controlMailbox)
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

    /** Drops all processor references when the owning ExoPlayer is released. */
    @JvmStatic
    fun forgetDeck(deckId: String) {
        processorsByDeck.remove(deckId)
    }

    /** Removes released processor instances so a stale deck cannot be reactivated. */
    @JvmStatic
    fun forgetProcessor(processor: DspEngineAudioProcessor) {
        processorsByDeck.values.forEach { it.remove(processor) }
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
