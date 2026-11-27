package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

/**
 * First processor in the DJ sink chain. It binds each PCM block to the PTS
 * recorded by TimestampedDjAudioSink, captures bounded per-deck PCM history,
 * and applies scratch rendering only while a valid deck control is active.
 * Normal playback remains byte-for-byte pass-through; invalid scratch state
 * fails closed to the untouched Media3 input block.
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

    internal fun latestControlSnapshotForTest(): DjScratchControlMailbox.Snapshot? =
        latestControlSnapshot

    // One bounded PCM history and render cursor per physical deck.
    private var pcmRing: DjScratchPcmRingBuffer? = null
    @Volatile private var ringCapacityFrames = 0
    @Volatile private var ringAvailableFrames = 0
    private val renderPolicy = DjScratchRenderPolicy()
    private val pcmBlocks = AtomicLong()
    private val timestampMatches = AtomicLong()
    private val timestampMisses = AtomicLong()
    private val activeControlBlocks = AtomicLong()
    private val renderedBlocks = AtomicLong()
    private val activeRenderFallbacks = AtomicLong()

    internal fun diagnosticsSnapshot(): Map<String, Any?> {
        val control = latestControlSnapshot
        return mapOf(
            "processorPresent" to true,
            "deckId" to deckId,
            "pcmBlocks" to pcmBlocks.get(),
            "timestampMatches" to timestampMatches.get(),
            "timestampMisses" to timestampMisses.get(),
            "activeControlBlocks" to activeControlBlocks.get(),
            "renderedBlocks" to renderedBlocks.get(),
            "activeRenderFallbacks" to activeRenderFallbacks.get(),
            "ringCapacityFrames" to ringCapacityFrames,
            "ringAvailableFrames" to ringAvailableFrames,
            "lastControlActive" to (control?.active == true),
            "lastControlVelocity" to control?.velocity,
            "lastControlAnchorMediaTimeUs" to control?.anchorMediaTimeUs,
        )
    }

    internal fun lastConsumedTimestampForTest(): DjScratchPcmTimestamp? =
        lastConsumedTimestamp

    internal fun pcmRingForTest(): DjScratchPcmRingBuffer? = pcmRing

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        // Timestamp mapping is valid only for the PCM16 path used by the native
        // DSP processor. Other formats are passed through without metadata.
        lastConsumedTimestamp = null
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
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        pcmBlocks.incrementAndGet()
        latestControlSnapshot = controlMailbox.snapshot()
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
        val rendered = timestamp != null && ring != null &&
            renderPolicy.render(inputBuffer, output, ring, latestControlSnapshot)
        ringAvailableFrames = ring?.availableFrames ?: 0
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
        renderPolicy.reset()
    }

    override fun onReset() {
        DspEngineSinkHook.forgetScratchProcessor(this)
        lastConsumedTimestamp = null
        latestControlSnapshot = null
        pcmRing?.clear()
        pcmRing = null
        ringCapacityFrames = 0
        ringAvailableFrames = 0
        renderPolicy.reset()
        ledger.clear()
    }
}
