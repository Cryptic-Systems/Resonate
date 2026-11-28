package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

/**
 * First Resonate user processor (after Media3 PCM conversion/trimming/channel
 * mapping). It binds each PCM block to the PTS recorded by TimestampedDjAudioSink,
 * captures bounded per-deck PCM history, and applies scratch rendering only
 * while a valid deck control is active. Normal playback remains byte-for-byte
 * pass-through; invalid scratch state fails closed to the untouched input block.
 */
internal class DjScratchTimestampProcessor(
    private val ledger: DjScratchTimestampLedger,
    private val controlMailbox: DjScratchControlMailbox = DjScratchControlMailbox(),
    private val deckId: String = "A",
) : BaseAudioProcessor() {
    @Volatile
    private var lastConsumedTimestamp: DjScratchPcmTimestamp? = null

    // Immutable control snapshot sampled once per input block on the audio thread.
    @Volatile
    private var latestControlSnapshot: DjScratchControlMailbox.Snapshot? = null
    private var lastMailboxGeneration = Long.MIN_VALUE

    internal fun latestControlSnapshotForTest(): DjScratchControlMailbox.Snapshot? =
        latestControlSnapshot

    // One bounded PCM history and render cursor per physical deck.
    private var pcmRing: DjScratchPcmRingBuffer? = null
    @Volatile private var ringCapacityFrames = 0
    @Volatile private var configured = false
    @Volatile private var ringAvailableFrames = 0
    @Volatile private var cursorMediaTimeUs: Long? = null
    // Keep audible scratch disabled until timestamp provenance, speed mapping,
    // and release-to-Media3 catch-up are validated end to end on devices.
    private companion object {
        const val ENABLE_SCRATCH_RENDERING = false
    }

    private val renderPolicy = DjScratchRenderPolicy()
    private val pcmBlocks = AtomicLong()
    private val timestampMatches = AtomicLong()
    private val timestampMisses = AtomicLong()
    private val activeControlBlocks = AtomicLong()
    private val renderedBlocks = AtomicLong()
    private val activeRenderFallbacks = AtomicLong()
    private val historyGenerationResets = AtomicLong()

    internal fun diagnosticsSnapshot(): Map<String, Any?> {
        val control = latestControlSnapshot
        return mapOf(
            "processorPresent" to true,
            "configured" to configured,
            "deckId" to deckId,
            "pcmBlocks" to pcmBlocks.get(),
            "timestampMatches" to timestampMatches.get(),
            "timestampMisses" to timestampMisses.get(),
            "activeControlBlocks" to activeControlBlocks.get(),
            "renderedBlocks" to renderedBlocks.get(),
            "activeRenderFallbacks" to activeRenderFallbacks.get(),
            "historyGenerationResets" to historyGenerationResets.get(),
            "ringCapacityFrames" to ringCapacityFrames,
            "ringAvailableFrames" to ringAvailableFrames,
            "cursorMediaTimeUs" to cursorMediaTimeUs,
            "lastControlActive" to (control?.active == true),
            "lastControlVelocity" to control?.velocity,
            "lastControlAnchorMediaTimeUs" to control?.anchorMediaTimeUs,
            "mailboxGeneration" to lastMailboxGeneration,
        )
    }

    internal fun lastConsumedTimestampForTest(): DjScratchPcmTimestamp? =
        lastConsumedTimestamp

    internal fun pcmRingForTest(): DjScratchPcmRingBuffer? = pcmRing

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        // Timestamp mapping is valid only for the PCM16 path used by the native
        // DSP processor. Other formats are passed through without metadata.
        lastConsumedTimestamp = null
        configured = true
        DspEngineSinkHook.trackScratchProcessor(this, deckId)
        pcmRing = if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT &&
            inputAudioFormat.sampleRate > 0 && inputAudioFormat.channelCount in 1..2
        ) {
            DjScratchPcmRingBuffer(
                sampleRate = inputAudioFormat.sampleRate,
                channelCount = inputAudioFormat.channelCount,
                capacityFrames = (inputAudioFormat.sampleRate * 4L)
                    .coerceAtMost(DjScratchPcmRingBuffer.MAX_CAPACITY_FRAMES.toLong())
                    .toInt(),
            )
        } else {
            null
        }
        ringCapacityFrames = pcmRing?.capacityFrames ?: 0
        ringAvailableFrames = 0
        lastMailboxGeneration = controlMailbox.state().generation
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        pcmBlocks.incrementAndGet()

        // clear() advances the mailbox generation atomically with removing its
        // command. The audio thread observes that boundary and retires all
        // pre-seek/pre-transition PCM before accepting another frame.
        val mailboxState = controlMailbox.state()
        if (mailboxState.generation != lastMailboxGeneration) {
            pcmRing?.clear()
            releaseTailFrames = 0
            renderPolicy.reset()
            latestControlSnapshot = null
            lastMailboxGeneration = mailboxState.generation
            historyGenerationResets.incrementAndGet()
        }
        latestControlSnapshot = mailboxState.snapshot
        if (latestControlSnapshot?.active == true) activeControlBlocks.incrementAndGet()

        val timestamp = ledger.consume(
            inputBuffer,
            inputAudioFormat.sampleRate,
            inputAudioFormat.channelCount,
        )
        lastConsumedTimestamp = timestamp
        if (timestamp != null) {
            timestampMatches.incrementAndGet()
            pcmRing?.append(inputBuffer, timestamp.presentationTimeUs)
        } else {
            timestampMisses.incrementAndGet()
        }
        val output = replaceOutputBuffer(inputBuffer.remaining())
        val ring = pcmRing
        val rendered = ENABLE_SCRATCH_RENDERING && timestamp != null && ring != null &&
            renderPolicy.render(inputBuffer, output, ring, latestControlSnapshot)
        ringAvailableFrames = ring?.availableFrames ?: 0
        cursorMediaTimeUs = if (rendered && ring != null) {
            renderPolicy.cursorMediaTimeUs(ring)
        } else {
            null
        }
        if (rendered) {
            renderedBlocks.incrementAndGet()
            // AudioProcessor.queueInput must consume its input even when the
            // renderer reads from a duplicate for zero-copy-safe history access.
            inputBuffer.position(inputBuffer.limit())
        } else {
            if (latestControlSnapshot?.active == true) activeRenderFallbacks.incrementAndGet()
            // A failed anchor/read must never emit a partially rendered block.
            output.clear()
            output.put(inputBuffer)
            output.flip()
        }
    }

    override fun onFlush() {
        lastConsumedTimestamp = null
        latestControlSnapshot = null
        pcmRing?.clear()
        ringAvailableFrames = 0
        cursorMediaTimeUs = null
        lastMailboxGeneration = controlMailbox.state().generation
        renderPolicy.reset()
    }

    override fun onReset() {
        DspEngineSinkHook.forgetScratchProcessor(this)
        lastConsumedTimestamp = null
        latestControlSnapshot = null
        pcmRing?.clear()
        releaseTailFrames = 0
        pcmRing = null
        ringCapacityFrames = 0
        ringAvailableFrames = 0
        cursorMediaTimeUs = null
        configured = false
        lastMailboxGeneration = controlMailbox.state().generation
        renderPolicy.reset()
        ledger.clear()
    }
}
