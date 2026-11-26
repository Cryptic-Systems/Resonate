package com.Aetherion.Resonate.media

import androidx.media3.exoplayer.audio.AudioSink
import com.aetherion.resonate.dsp.DjScratchTimestampLedger
import java.nio.ByteBuffer

/**
 * Captures the exact Media3 input-buffer PTS before DefaultAudioSink forwards
 * that buffer through its processor pipeline. Delegation preserves every
 * other AudioSink contract unchanged.
 */
@androidx.media3.common.util.UnstableApi
internal class TimestampedDjAudioSink(
    private val delegate: AudioSink,
    private val ledger: DjScratchTimestampLedger,
) : AudioSink by delegate {
    override fun handleBuffer(
        buffer: ByteBuffer,
        presentationTimeUs: Long,
        encodedAccessUnitCount: Int,
    ): Boolean {
        ledger.record(buffer, presentationTimeUs)
        return delegate.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
    }

    override fun flush() {
        ledger.clear()
        delegate.flush()
    }

    override fun reset() {
        ledger.clear()
        delegate.reset()
    }
}
