package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer

/**
 * First processor in the DJ sink chain. It binds each PCM block to the PTS
 * recorded by TimestampedDjAudioSink, then passes the PCM through unchanged.
 *
 * It passively captures timestamped PCM into a bounded per-deck history, then
 * passes the same PCM onward unchanged. It does not alter audible playback.
 */
internal class DjScratchTimestampProcessor(
    private val ledger: DjScratchTimestampLedger,
) : BaseAudioProcessor() {
    @Volatile
    private var lastConsumedTimestamp: DjScratchPcmTimestamp? = null

    // One bounded PCM history per physical deck. It is passive capture only;
    // normal Media3 output remains byte-for-byte pass-through at this stage.
    private var pcmRing: DjScratchPcmRingBuffer? = null

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
        output.put(inputBuffer)
        output.flip()
    }

    override fun onFlush() {
        lastConsumedTimestamp = null
        pcmRing?.clear()
    }

    override fun onReset() {
        lastConsumedTimestamp = null
        pcmRing?.clear()
        pcmRing = null
        ledger.clear()
    }
}
