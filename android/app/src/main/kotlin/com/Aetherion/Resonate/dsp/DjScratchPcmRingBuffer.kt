package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Fixed-capacity, interleaved PCM16 history for one physical DJ deck.
 *
 * The owner must call every method from the same audio-processing thread.
 * No locks, resizing, callbacks or per-frame objects are used. Absolute frame
 * indices remain monotonic while storage wraps; timestamps are retained per
 * frame so discontinuous input blocks cannot be mistaken for contiguous media.
 *
 * The timestamp processor feeds this history passively before native DSP.
 * It is not part of the output render path; a separate, validated audio-thread
 * control handoff and render policy are required before it can affect output.
 */
internal class DjScratchPcmRingBuffer(
    val sampleRate: Int,
    val channelCount: Int,
    val capacityFrames: Int,
) {
    companion object {
        const val MAX_CAPACITY_FRAMES = 192_000 // Four seconds at 48 kHz.
    }

    private val samples: ShortArray
    private val mediaTimesUs: LongArray

    /** Absolute index assigned to the next appended frame. */
    var nextWriteFrame: Long = 0L
        private set

    /** First absolute frame still valid after wrap or an explicit clear. */
    var oldestFrame: Long = 0L
        private set

    val availableFrames: Int
        get() = (nextWriteFrame - oldestFrame).toInt()

    init {
        require(sampleRate > 0) { "sampleRate must be positive" }
        require(channelCount in 1..2) { "only mono/stereo PCM16 is supported" }
        require(capacityFrames in 1..MAX_CAPACITY_FRAMES) {
            "capacityFrames must be between 1 and $MAX_CAPACITY_FRAMES"
        }
        samples = ShortArray(capacityFrames * channelCount)
        mediaTimesUs = LongArray(capacityFrames)
    }

    /**
     * Copies complete PCM16 frames from [input] and associates every stored
     * frame with its source-media timestamp. [input] is not advanced.
     *
     * If a block exceeds capacity, only its newest frames are retained.
     * Returns the number of frames appended, or zero for malformed/empty data.
     */
    fun append(input: ByteBuffer, presentationTimeUs: Long): Int {
        if (presentationTimeUs < 0L || !input.hasRemaining()) return 0
        val bytesPerFrame = channelCount * Short.SIZE_BYTES
        val byteCount = input.remaining()
        if (byteCount % bytesPerFrame != 0) return 0

        val totalFrames = byteCount / bytesPerFrame
        val skippedFrames = (totalFrames - capacityFrames).coerceAtLeast(0)
        val framesToCopy = totalFrames - skippedFrames
        val source = input.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        source.position(source.position() + skippedFrames * bytesPerFrame)

        val skippedTimeNumerator = skippedFrames.toLong() * 1_000_000L
        var framePtsUs = presentationTimeUs + skippedTimeNumerator / sampleRate
        var ptsRemainder = skippedTimeNumerator % sampleRate
        val ptsStepWholeUs = 1_000_000L / sampleRate
        val ptsStepRemainder = 1_000_000L % sampleRate
        val firstAbsoluteFrame = nextWriteFrame + skippedFrames
        for (frame in 0 until framesToCopy) {
            val absoluteFrame = firstAbsoluteFrame + frame
            val slot = (absoluteFrame % capacityFrames).toInt()
            val sampleOffset = slot * channelCount
            for (channel in 0 until channelCount) {
                samples[sampleOffset + channel] = source.short
            }
            mediaTimesUs[slot] = framePtsUs
            framePtsUs += ptsStepWholeUs
            ptsRemainder += ptsStepRemainder
            if (ptsRemainder >= sampleRate) {
                framePtsUs += ptsRemainder / sampleRate
                ptsRemainder %= sampleRate.toLong()
            }
        }
        nextWriteFrame += totalFrames.toLong()
        oldestFrame = maxOf(oldestFrame, (nextWriteFrame - capacityFrames).coerceAtLeast(0L))
        return framesToCopy
    }

    /** Copies one retained interleaved frame into [destination]. */
    fun readFrame(absoluteFrame: Long, destination: ShortArray, offset: Int = 0): Boolean {
        if (absoluteFrame !in oldestFrame until nextWriteFrame) return false
        if (offset < 0 || offset + channelCount > destination.size) return false
        val slot = (absoluteFrame % capacityFrames).toInt()
        val sourceOffset = slot * channelCount
        for (channel in 0 until channelCount) {
            destination[offset + channel] = samples[sourceOffset + channel]
        }
        return true
    }

    /** Returns the original media PTS associated with a retained frame. */
    fun mediaTimeUsAtFrame(absoluteFrame: Long): Long? {
        if (absoluteFrame !in oldestFrame until nextWriteFrame) return null
        return mediaTimesUs[(absoluteFrame % capacityFrames).toInt()]
    }

    /** Invalidates history in O(1), preserving absolute frame-index monotonicity. */
    fun clear() {
        oldestFrame = nextWriteFrame
    }
}

/**
 * Audio-thread-owned bidirectional playback cursor over a ring's absolute frame
 * range. Velocity is measured in source frames per output frame: 1 is forward
 * normal-rate, -1 reverse, and 0 holds. This is control math only; it does not
 * render audio or imply that reverse playback is enabled in the application.
 */
internal class DjScratchFrameCursor(
    private val maximumAbsVelocity: Double = 4.0,
) {
    var positionFrame: Double = 0.0
        private set

    var velocity: Double = 1.0
        private set

    init {
        require(maximumAbsVelocity.isFinite() && maximumAbsVelocity >= 1.0)
    }

    fun setVelocity(value: Double): Boolean {
        if (!value.isFinite()) return false
        velocity = value.coerceIn(-maximumAbsVelocity, maximumAbsVelocity)
        return true
    }

    fun seekTo(frame: Double, oldestFrame: Long, nextWriteFrame: Long): Boolean {
        if (!frame.isFinite() || nextWriteFrame <= oldestFrame) return false
        positionFrame = frame.coerceIn(oldestFrame.toDouble(), (nextWriteFrame - 1L).toDouble())
        return true
    }

    /**
     * Advances by [outputFrames], clamping to retained history. Returns null
     * when the ring has no frames. A reverse cursor cannot underflow the oldest
     * retained frame; a forward cursor cannot read beyond the newest frame.
     */
    fun advance(
        outputFrames: Int,
        oldestFrame: Long,
        nextWriteFrame: Long,
    ): Double? {
        if (outputFrames < 0 || nextWriteFrame <= oldestFrame) return null
        positionFrame = (positionFrame + velocity * outputFrames)
            .coerceIn(oldestFrame.toDouble(), (nextWriteFrame - 1L).toDouble())
        return positionFrame
    }
}
