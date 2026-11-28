package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Fixed-capacity capture of the most recently emitted post-DSP PCM.
 *
 * Frame timestamps travel with the samples so a future renderer can discard
 * audio already passed by the audible Media3 clock before transferring the
 * remaining tail. A tail without complete timestamp provenance is not safe
 * for handoff.
 */
internal class DjScratchReleaseTailBuffer(
    val channelCount: Int,
    val capacityFrames: Int,
) {
    private val samples: ShortArray
    private val mediaTimesUs: LongArray
    private var nextWriteFrame = 0L
    private var oldestFrame = 0L
    private var readFrame = 0L
    @Volatile private var sealed = false
    private var timestampsComplete = true

    val availableFrames: Int
        get() = (nextWriteFrame - oldestFrame).toInt()

    val remainingFrames: Int
        get() = (nextWriteFrame - readFrame).coerceAtLeast(0L).toInt()

    val isSealed: Boolean
        get() = sealed

    val hasValidTimestamps: Boolean
        get() = sealed && timestampsComplete && availableFrames > 0

    init {
        require(channelCount in 1..2)
        require(capacityFrames in 1..MAX_CAPACITY_FRAMES)
        samples = ShortArray(capacityFrames * channelCount)
        mediaTimesUs = LongArray(capacityFrames)
    }

    /** Capture a complete PCM16 block without advancing [input]. */
    fun append(
        input: ByteBuffer,
        presentationTimeUs: Long? = null,
        sampleRate: Int = 0,
    ): Int {
        if (sealed || !input.hasRemaining()) return 0
        val bytesPerFrame = channelCount * Short.SIZE_BYTES
        val byteCount = input.remaining()
        if (byteCount % bytesPerFrame != 0) return 0
        val totalFrames = byteCount / bytesPerFrame
        if (presentationTimeUs == null || presentationTimeUs < 0L || sampleRate <= 0) {
            timestampsComplete = false
        }
        val skippedFrames = (totalFrames - capacityFrames).coerceAtLeast(0)
        val framesToCopy = totalFrames - skippedFrames
        val source = input.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        source.position(source.position() + skippedFrames * bytesPerFrame)
        val firstFrame = nextWriteFrame + skippedFrames
        for (frame in 0 until framesToCopy) {
            val absoluteFrame = firstFrame + frame
            val slotFrame = (absoluteFrame % capacityFrames).toInt()
            val slot = slotFrame * channelCount
            for (channel in 0 until channelCount) {
                samples[slot + channel] = source.short
            }
            if (presentationTimeUs != null && presentationTimeUs >= 0L && sampleRate > 0) {
                val sourceFrame = skippedFrames + frame
                mediaTimesUs[slotFrame] =
                    presentationTimeUs + sourceFrame * 1_000_000L / sampleRate
            }
        }
        nextWriteFrame += totalFrames.toLong()
        oldestFrame = maxOf(oldestFrame, nextWriteFrame - capacityFrames)
        return framesToCopy
    }

    /** Freeze capture and rewind the read cursor to the oldest retained frame. */
    fun seal() {
        if (sealed) return
        sealed = true
        readFrame = oldestFrame
    }

    /**
     * Drop frames strictly before an independently measured audible media time.
     * This is intentionally unavailable until the tail is sealed and fully
     * timestamped; guessing the splice point would duplicate or skip audio.
     */
    fun discardBeforeMediaTimeUs(audibleMediaTimeUs: Long): Int {
        if (!sealed || !timestampsComplete || audibleMediaTimeUs < 0L) return 0
        val initial = readFrame
        while (readFrame < nextWriteFrame) {
            val slot = (readFrame % capacityFrames).toInt()
            if (mediaTimesUs[slot] >= audibleMediaTimeUs) break
            readFrame++
        }
        return (readFrame - initial).toInt()
    }

    /** First retained frame's media timestamp, or null if provenance is incomplete. */
    fun nextFrameMediaTimeUs(): Long? {
        if (!sealed || !timestampsComplete || readFrame >= nextWriteFrame) return null
        return mediaTimesUs[(readFrame % capacityFrames).toInt()]
    }

    /** Drain complete frames into a caller-owned PCM16 buffer without allocating. */
    fun drainTo(destination: ByteBuffer): Int {
        if (!sealed) return 0
        val bytesPerFrame = channelCount * Short.SIZE_BYTES
        val frameCapacity = destination.remaining() / bytesPerFrame
        val frames = minOf(frameCapacity, remainingFrames)
        if (frames <= 0) return 0
        val output = destination.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        output.limit(output.position() + frames * bytesPerFrame)
        for (frame in 0 until frames) {
            val slot = ((readFrame + frame) % capacityFrames).toInt() * channelCount
            for (channel in 0 until channelCount) {
                output.putShort(samples[slot + channel])
            }
        }
        destination.position(destination.position() + frames * bytesPerFrame)
        readFrame += frames.toLong()
        return frames
    }

    /** Retire the tail at a new scratch/media generation. */
    fun clear() {
        nextWriteFrame = 0L
        oldestFrame = 0L
        readFrame = 0L
        timestampsComplete = true
        sealed = false
    }

    companion object {
        const val MAX_CAPACITY_FRAMES = 24_000 // 500 ms at 48 kHz.
        const val DEFAULT_TAIL_MS = 250
    }
}
