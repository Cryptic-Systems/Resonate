package com.Aetherion.Resonate.media

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Util
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
    @Volatile private var resetForRelease = false

    /** Media-time position reported by Media3's AudioTrack playback-head tracker. */
    fun audibleMediaPositionUs(): Long? {
        if (resetForRelease) return null
        val positionUs = delegate.getCurrentPositionUs(false)
        return positionUs.takeIf { it != C.TIME_UNSET && it >= 0L }
    }
    override fun configure(
        inputFormat: Format,
        specifiedBufferSize: Int,
        outputChannels: IntArray?,
    ) {
        // Let Media3 validate/configure first. If it rejects this format, the
        // current timestamp timeline must remain untouched.
        delegate.configure(inputFormat, specifiedBufferSize, outputChannels)
        resetForRelease = false
        ledger.configure(
            sampleRate = inputFormat.sampleRate,
            channelCount = inputFormat.channelCount,
            encoderDelayFrames = inputFormat.encoderDelay,
            sourceBytesPerFrame = if (inputFormat.sampleMimeType == MimeTypes.AUDIO_RAW) {
                Util.getPcmFrameSize(inputFormat.pcmEncoding, inputFormat.channelCount)
            } else {
                0
            },
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
        resetForRelease = true
        ledger.clear()
        delegate.reset()
    }
}
