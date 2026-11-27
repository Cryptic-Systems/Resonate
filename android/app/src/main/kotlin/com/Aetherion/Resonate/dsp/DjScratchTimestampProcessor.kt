package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer

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
    private val renderPolicy = DjScratchRenderPolicy()

    internal fun lastConsumedTimestampForTest(): DjScratchPcmTimestamp? =
        lastConsumedTimestamp

    internal fun pcmRingForTest(): DjScratchPcmRingBuffer? = pcmRing

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        // Timestamp mapping is valid only for the PCM16 path used by the native
        // DSP processor. Other formats are passed through without metadata.
        lastConsumedTimestamp = null
        pcmRing = if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT &&
            inputAudioFormat.sampleRate > 0 && inputAudioFormat.channelCount in 1..2
        ) {
            DjScratchPcmRingBuffer(
                sampleRate = inputAudioFormat.sampleRate,
                channelCount = inputAudioFormat.channelCount,
                capacityFrames = (inputAudioFormat.sampleRate * 2L)
                    .coerceAtMost(DjScratchPcmRingBuffer.MAX_CAPACITY_FRAMES.toLong())
                    .toInt(),
            )
        } else {
            null
        }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        latestControlSnapshot = controlMailbox.snapshot()
        val timestamp = ledger.consume(
            inputBuffer,
            inputAudioFormat.sampleRate,
            inputAudioFormat.channelCount,
        )
        lastConsumedTimestamp = timestamp
        if (timestamp != null) {
            pcmRing?.append(inputBuffer, timestamp.presentationTimeUs)
        }
        val output = replaceOutputBuffer(inputBuffer.remaining())
        val ring = pcmRing
        val rendered = timestamp != null && ring != null &&
            renderPolicy.render(inputBuffer, output, ring, latestControlSnapshot)
        if (rendered) {
            // AudioProcessor.queueInput must consume its input even when the
            // renderer reads from a duplicate for zero-copy-safe history access.
            inputBuffer.position(inputBuffer.limit())
        } else {
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
        renderPolicy.reset()
    }

    override fun onReset() {
        lastConsumedTimestamp = null
        latestControlSnapshot = null
        pcmRing?.clear()
        pcmRing = null
        renderPolicy.reset()
        ledger.clear()
    }
}
