package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.IdentityHashMap
import kotlin.math.abs

/**
 * Maps sink-submitted PCM frame spans to the PCM16 blocks delivered to the
 * first user processor. DefaultAudioSink may trim encoder delay and remap
 * channels before that processor, so matching ByteBuffer identity alone is
 * insufficient. Spans are consumed in sink FIFO order and frame offsets are
 * carried across buffer boundaries.
 */
internal class DjScratchTimestampLedger {
    private companion object {
        const val MAX_PENDING_BUFFERS = 64
    }

    private data class PendingSpan(
        val buffer: ByteBuffer,
        val presentationTimeUs: Long,
        val sampleRate: Int,
        val sourceChannelCount: Int,
        val totalFrames: Int,
        var consumedFrames: Int = 0,
    )

    private val byIdentity = IdentityHashMap<ByteBuffer, PendingSpan>()
    private val pending = ArrayDeque<PendingSpan>()
    private var configuredSampleRate = 0
    private var configuredSourceChannels = 0
    private var configuredEncoderDelayFrames = 0
    private var trimFramesRemaining = 0

    @Synchronized
    fun configure(sampleRate: Int, channelCount: Int, encoderDelayFrames: Int) {
        clearPending()
        configuredSampleRate = sampleRate.takeIf { it > 0 } ?: 0
        configuredSourceChannels = channelCount.takeIf { it > 0 } ?: 0
        configuredEncoderDelayFrames = encoderDelayFrames.coerceAtLeast(0)
        trimFramesRemaining = configuredEncoderDelayFrames
    }

    @Synchronized
    fun record(buffer: ByteBuffer, presentationTimeUs: Long) {
        if (presentationTimeUs < 0L || !buffer.hasRemaining() ||
            configuredSampleRate <= 0 || configuredSourceChannels <= 0
        ) return

        // handleBuffer may be retried with the same ByteBuffer while the sink
        // is back-pressured. Retain the original PTS and original frame span.
        if (byIdentity.containsKey(buffer)) return
        val bytesPerFrame = configuredSourceChannels * Short.SIZE_BYTES
        val byteCount = buffer.remaining()
        if (byteCount <= 0 || byteCount % bytesPerFrame != 0) return

        if (pending.size >= MAX_PENDING_BUFFERS) {
            // Losing any span invalidates FIFO association. Fail closed rather
            // than allowing later PCM to inherit an old timestamp.
            clearPending()
            trimFramesRemaining = 0
        }
        val span = PendingSpan(
            buffer = buffer,
            presentationTimeUs = presentationTimeUs,
            sampleRate = configuredSampleRate,
            sourceChannelCount = configuredSourceChannels,
            totalFrames = byteCount / bytesPerFrame,
        )
        byIdentity[buffer] = span
        pending.addLast(span)
    }

    /**
     * Consumes the next output frame range. Channel mapping preserves frame
     * count; encoder delay is removed from the leading source spans. If the
     * processor output crosses a PTS gap or an unsupported sample-rate change,
     * the entire association is rejected.
     */
    @Synchronized
    fun consume(
        buffer: ByteBuffer,
        sampleRate: Int,
        channelCount: Int,
    ): DjScratchPcmTimestamp? {
        val bytesPerFrame = channelCount * Short.SIZE_BYTES
        val byteCount = buffer.remaining()
        if (sampleRate <= 0 || channelCount !in 1..2 ||
            byteCount <= 0 || byteCount % bytesPerFrame != 0
        ) {
            return null
        }

        var framesNeeded = byteCount / bytesPerFrame
        val outputFrameCount = framesNeeded
        var firstPresentationTimeUs: Long? = null
        var framesFromFirst = 0
        var contiguous = true
        var expectedNextTimeUs = 0L

        while (framesNeeded > 0) {
            val span = pending.peekFirst() ?: run {
                clearPending()
                return null
            }

            if (span.sampleRate != sampleRate || span.sampleRate != configuredSampleRate) {
                clearPending()
                trimFramesRemaining = 0
                return null
            }

            val spanRemaining = span.totalFrames - span.consumedFrames
            if (spanRemaining <= 0) {
                removeFirstSpan()
                continue
            }

            if (trimFramesRemaining > 0) {
                val skipped = minOf(trimFramesRemaining, spanRemaining)
                span.consumedFrames += skipped
                trimFramesRemaining -= skipped
                if (span.consumedFrames == span.totalFrames) removeFirstSpan()
                continue
            }

            val spanTimeUs = span.presentationTimeUs +
                span.consumedFrames.toLong() * 1_000_000L / span.sampleRate
            if (firstPresentationTimeUs == null) {
                firstPresentationTimeUs = spanTimeUs
            } else {
                val toleranceUs = (1_000_000L / sampleRate).coerceAtLeast(1L)
                if (abs(spanTimeUs - expectedNextTimeUs) > toleranceUs) {
                    contiguous = false
                }
            }

            val taken = minOf(framesNeeded, spanRemaining)
            span.consumedFrames += taken
            framesNeeded -= taken
            framesFromFirst += taken
            expectedNextTimeUs = checkNotNull(firstPresentationTimeUs) +
                framesFromFirst.toLong() * 1_000_000L / sampleRate

            if (span.consumedFrames == span.totalFrames) removeFirstSpan()
        }

        if (!contiguous || firstPresentationTimeUs == null) return null
        return DjScratchPcmTimestamp(
            presentationTimeUs = firstPresentationTimeUs,
            frameCount = outputFrameCount,
            sampleRate = sampleRate,
            channelCount = channelCount,
            bytesPerFrame = bytesPerFrame,
        )
    }

    /** A seek/discontinuity invalidates queued PTS but does not re-trim delay. */
    @Synchronized
    fun handleDiscontinuity() {
        clearPending()
        trimFramesRemaining = 0
    }

    /** AudioSink.flush resets its trimming processor, so restore encoder delay. */
    @Synchronized
    fun resetForFlush() {
        clearPending()
        trimFramesRemaining = configuredEncoderDelayFrames
    }

    @Synchronized
    fun clear() {
        clearPending()
        configuredSampleRate = 0
        configuredSourceChannels = 0
        configuredEncoderDelayFrames = 0
        trimFramesRemaining = 0
    }

    private fun removeFirstSpan() {
        val removed = pending.pollFirst() ?: return
        byIdentity.remove(removed.buffer)
    }

    private fun clearPending() {
        byIdentity.clear()
        pending.clear()
    }

    @Synchronized
    internal fun pendingCountForTest(): Int = pending.size

    @Synchronized
    internal fun trimFramesRemainingForTest(): Int = trimFramesRemaining
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
