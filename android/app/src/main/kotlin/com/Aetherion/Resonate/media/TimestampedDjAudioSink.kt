package com.aetherion.resonate.media

import androidx.media3.common.Format
import androidx.media3.exoplayer.audio.AudioSink
import com.aetherion.resonate.dsp.DjScratchTimestampLedger
import java.nio.ByteBuffer

/**
 * Captures the source PCM format and input PTS before DefaultAudioSink applies
 * encoder-delay trimming and channel mapping. Delegation preserves the sink
 * transport contract; the ledger performs frame-span association downstream.
 */
@androidx.media3.common.util.UnstableApi
internal class TimestampedDjAudioSink(
    private val delegate: AudioSink,
    private val ledger: DjScratchTimestampLedger,
) : AudioSink by delegate {
    override fun configure(
        inputFormat: Format,
        specifiedBufferSize: Int,
        outputChannels: IntArray?,
    ) {
        // Let Media3 validate/configure first. If it rejects this format, the
        // current timestamp timeline must remain untouched.
        delegate.configure(inputFormat, specifiedBufferSize, outputChannels)
        ledger.configure(
            sampleRate = inputFormat.sampleRate,
            channelCount = inputFormat.channelCount,
            encoderDelayFrames = inputFormat.encoderDelay,
        )
    }

    override fun handleBuffer(
        buffer: ByteBuffer,
        presentationTimeUs: Long,
        encodedAccessUnitCount: Int,
    ): Boolean {
        ledger.record(buffer, presentationTimeUs)
        return delegate.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
    }

    override fun handleDiscontinuity() {
        ledger.handleDiscontinuity()
        delegate.handleDiscontinuity()
    }

    override fun flush() {
        ledger.resetForFlush()
        delegate.flush()
    }

    override fun reset() {
        ledger.clear()
        delegate.reset()
    }
}
