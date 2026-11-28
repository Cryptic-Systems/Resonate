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
 * The legacy just_audio overload deliberately returns no processors: it
 * carries only voice/SFX output, outside music DSP.
 *
 * Crash history (2026-09-28): old JNI called dsp_create(double, int) but the
 * real ABI is dsp_create(const DspConfig*). That treated the sample-rate bits
 * as a pointer → SIGSEGV in dsp_create+36. JNI was corrected to build a
 * DspConfig and pass &cfg; native can be ON again.
 */
object DspEngineSinkHook {
    private const val TAG = "DspEngineSinkHook"

    /** Master switch for live native EQ/DVC. */
    private const val ENABLE_NATIVE_LIVE_DSP = true
    private val processorsByDeck = ConcurrentHashMap<String, CopyOnWriteArraySet<DspEngineAudioProcessor>>()
    private val scratchProcessorsByDeck =
        ConcurrentHashMap<String, CopyOnWriteArraySet<DjScratchTimestampProcessor>>()
    private val releaseTailProcessorsByDeck =
        ConcurrentHashMap<String, CopyOnWriteArraySet<DjScratchReleaseTailCaptureProcessor>>()
    // Tracks physical active/fading roles, not only the canonical MediaSession deck.
    private val activeDecks = CopyOnWriteArraySet<String>().apply {
        add("A")
        add("legacy")
    }

    private fun isDeckActive(deckId: String): Boolean =
        deckId == "legacy" || activeDecks.contains(deckId)

    internal fun resetForTests() {
        processorsByDeck.clear()
        scratchProcessorsByDeck.clear()
        releaseTailProcessorsByDeck.clear()
        activeDecks.clear()
        activeDecks.add("A")
        activeDecks.add("legacy")
    }

    /** Legacy just_audio is reserved for short voice/SFX playback, outside music DSP. */
    @JvmStatic
    fun createProcessors(): Array<AudioProcessor> = emptyArray()

    @JvmStatic
    fun createProcessors(deckId: String): Array<AudioProcessor> =
        if (deckId == "legacy") emptyArray() else createDspProcessors(deckId)

    /** Media3 chain: timestamp probe, native DSP, then post-DSP release-tail capture. */
    @JvmStatic
    internal fun createProcessors(
        deckId: String,
        timestampLedger: DjScratchTimestampLedger,
        controlMailbox: DjScratchControlMailbox,
    ): Array<AudioProcessor> {
        val timestampProcessor = DjScratchTimestampProcessor(timestampLedger, controlMailbox, deckId)
        trackScratchProcessor(timestampProcessor, deckId)
        val chain = ArrayList<AudioProcessor>(3)
        chain.add(timestampProcessor)
        try {
            chain.add(createDspProcessor(deckId))
        } catch (t: Throwable) {
            Log.e(TAG, "Native DSP processor unavailable; retaining scratch stage for deck=$deckId", t)
        }
        // Capture processed PCM only; never bypass or double-run the engine.
        val releaseTail = DjScratchReleaseTailCaptureProcessor {
            timestampProcessor.lastConsumedTimestampForTest()?.presentationTimeUs
        }
        releaseTailProcessorsByDeck.computeIfAbsent(deckId) { CopyOnWriteArraySet() }.add(releaseTail)
        chain.add(releaseTail)
        return chain.toTypedArray()
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
        processor.setDeckActive(isDeckActive(deckId))
    }

    /** Tracks the timestamp-aware scratch processor for per-deck diagnostics. */
    @JvmStatic
    internal fun trackScratchProcessor(processor: DjScratchTimestampProcessor, deckId: String) {
        scratchProcessorsByDeck.computeIfAbsent(deckId) { CopyOnWriteArraySet() }.add(processor)
    }

    /** Start a bounded post-DSP PCM capture on the selected physical deck. */
    @JvmStatic
    internal fun beginReleaseTailCapture(deckId: String): Boolean =
        releaseTailProcessorsByDeck[deckId]?.lastOrNull()?.beginCapture() == true

    /** Seal the current post-DSP tail after its in-flight audio callback exits. */
    @JvmStatic
    internal fun sealReleaseTailCapture(deckId: String): DjScratchReleaseTailBuffer? =
        releaseTailProcessorsByDeck[deckId]?.lastOrNull()?.sealCapture()

    /** Latest immutable post-DSP tail for transfer to the independent renderer. */
    @JvmStatic
    internal fun sealedReleaseTail(deckId: String): DjScratchReleaseTailBuffer? =
        releaseTailProcessorsByDeck[deckId]?.lastOrNull()?.sealedTail()

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
        releaseTailProcessorsByDeck.remove(deckId)
    }

    /** Removes released processor instances so a stale deck cannot be reactivated. */
    @JvmStatic
    fun forgetProcessor(processor: DspEngineAudioProcessor) {
        processorsByDeck.values.forEach { it.remove(processor) }
    }

    @JvmStatic
    internal fun forgetScratchProcessor(processor: DjScratchTimestampProcessor) {
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
