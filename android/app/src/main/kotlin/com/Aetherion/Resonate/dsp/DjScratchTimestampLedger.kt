package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.util.IdentityHashMap

/**
 * Associates Media3 input-buffer identities with their media presentation
 * timestamps until the first PCM processor consumes those exact buffers.
 *
 * Identity, rather than ByteBuffer equality, is intentional: Media3 may retry
 * handleBuffer with the same object while back-pressured, and distinct buffers
 * can have equal contents/positions.
 */
internal class DjScratchTimestampLedger {
    private companion object { const val MAX_PENDING_BUFFERS = 64 }
    private val timestamps = IdentityHashMap<ByteBuffer, Long>()

    @Synchronized
    fun record(buffer: ByteBuffer, presentationTimeUs: Long) {
        if (presentationTimeUs < 0L || !buffer.hasRemaining()) return
        // A retry of the same Media3 buffer must not replace its original PTS.
        if (!timestamps.containsKey(buffer)) {
            if (timestamps.size >= MAX_PENDING_BUFFERS) timestamps.clear()
            timestamps[buffer] = presentationTimeUs
        }
    }

    @Synchronized
    fun consume(
        buffer: ByteBuffer,
        sampleRate: Int,
        channelCount: Int,
    ): DjScratchPcmTimestamp? {
        val presentationTimeUs = timestamps.remove(buffer) ?: return null
        if (sampleRate <= 0 || channelCount !in 1..2) return null
        val bytesPerFrame = channelCount * Short.SIZE_BYTES
        val byteCount = buffer.remaining()
        if (byteCount <= 0 || byteCount % bytesPerFrame != 0) return null
        return DjScratchPcmTimestamp(
            presentationTimeUs = presentationTimeUs,
            frameCount = byteCount / bytesPerFrame,
            sampleRate = sampleRate,
            channelCount = channelCount,
            bytesPerFrame = bytesPerFrame,
        )
    }

    @Synchronized
    fun clear() {
        timestamps.clear()
    }

    @Synchronized
    internal fun pendingCountForTest(): Int = timestamps.size
}

internal data class DjScratchPcmTimestamp(
    val presentationTimeUs: Long,
    val frameCount: Int,
    val sampleRate: Int,
    val channelCount: Int,
    val bytesPerFrame: Int,
) {
    fun presentationTimeUsAtFrame(frameOffset: Int): Long? {
        if (frameOffset !in 0..frameCount) return null
        return presentationTimeUs + frameOffset.toLong() * 1_000_000L / sampleRate
    }
}
