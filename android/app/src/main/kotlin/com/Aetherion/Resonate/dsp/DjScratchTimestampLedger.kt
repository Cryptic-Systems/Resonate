package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.IdentityHashMap

/**
 * Associates Media3 input-buffer identities with their media presentation
 * timestamps until the first PCM processor consumes those buffers.
 *
 * Identity is the fast path because Media3 may retry handleBuffer with the same
 * object. A bounded FIFO fallback handles AudioSink implementations that pass
 * a duplicate/slice to the first processor; PCM buffers are delivered in order.
 */
internal class DjScratchTimestampLedger {
    private companion object { const val MAX_PENDING_BUFFERS = 64 }
    private data class Pending(val buffer: ByteBuffer, val presentationTimeUs: Long)

    private val timestamps = IdentityHashMap<ByteBuffer, Long>()
    private val pending = ArrayDeque<Pending>()

    @Synchronized
    fun record(buffer: ByteBuffer, presentationTimeUs: Long) {
        if (presentationTimeUs < 0L || !buffer.hasRemaining()) return
        // A retry of the same Media3 buffer must not replace its original PTS.
        if (!timestamps.containsKey(buffer)) {
            if (timestamps.size >= MAX_PENDING_BUFFERS) clear()
            timestamps[buffer] = presentationTimeUs
            pending.addLast(Pending(buffer, presentationTimeUs))
        }
    }

    @Synchronized
    fun consume(
        buffer: ByteBuffer,
        sampleRate: Int,
        channelCount: Int,
    ): DjScratchPcmTimestamp? {
        // Prefer exact identity. If the sink passes a duplicate/slice instead,
        // consume the oldest outstanding PTS; Media3's sink processes PCM FIFO.
        val exact = timestamps.remove(buffer)
        val presentationTimeUs = if (exact != null) {
            val iterator = pending.iterator()
            while (iterator.hasNext()) {
                if (iterator.next().buffer === buffer) {
                    iterator.remove()
                    break
                }
            }
            exact
        } else {
            val next = pending.pollFirst() ?: return null
            timestamps.remove(next.buffer)
            next.presentationTimeUs
        }
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
        pending.clear()
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
