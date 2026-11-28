package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Fixed-capacity capture of the most recently emitted scratch PCM.
 *
 * The audio thread owns capture. After [seal], ownership may be transferred to
 * a dedicated release renderer, which drains the immutable tail after the
 * Media3 player has flushed its own sink for catch-up. This class does not
 * create an output device or claim gapless playback by itself.
 */
internal class DjScratchReleaseTailBuffer(
    val channelCount: Int,
    val capacityFrames: Int,
) {
    private val samples: ShortArray
    private var nextWriteFrame = 0L
    private var oldestFrame = 0L
    private var readFrame = 0L
    private var sealed = false

    val availableFrames: Int
        get() = (nextWriteFrame - oldestFrame).toInt()

    val remainingFrames: Int
        get() = (nextWriteFrame - readFrame).coerceAtLeast(0L).toInt()

    val isSealed: Boolean
        get() = sealed

    init {
        require(channelCount in 1..2)
        require(capacityFrames in 1..MAX_CAPACITY_FRAMES)
        samples = ShortArray(capacityFrames * channelCount)
    }

    /** Capture a complete PCM16 block without advancing [input]. */
    fun append(input: ByteBuffer): Int {
        if (sealed || !input.hasRemaining()) return 0
        val bytesPerFrame = channelCount * Short.SIZE_BYTES
        val byteCount = input.remaining()
        if (byteCount % bytesPerFrame != 0) return 0
        val totalFrames = byteCount / bytesPerFrame
        val skippedFrames = (totalFrames - capacityFrames).coerceAtLeast(0)
        val framesToCopy = totalFrames - skippedFrames
        val source = input.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        source.position(source.position() + skippedFrames * bytesPerFrame)
        val firstFrame = nextWriteFrame + skippedFrames
        for (frame in 0 until framesToCopy) {
            val slot = ((firstFrame + frame) % capacityFrames).toInt() * channelCount
            for (channel in 0 until channelCount) {
                samples[slot + channel] = source.short
            }
        }
        nextWriteFrame += totalFrames.toLong()
        oldestFrame = maxOf(oldestFrame, nextWriteFrame - capacityFrames)
        return framesToCopy
    }

    /**
     * Freeze capture and rewind the read cursor to the oldest retained frame.
     * Call once before transferring ownership to the release renderer.
     */
    fun seal() {
        if (sealed) return
        sealed = true
        readFrame = oldestFrame
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
        sealed = false
    }

    companion object {
        const val MAX_CAPACITY_FRAMES = 24_000 // 500 ms at 48 kHz.
        const val DEFAULT_TAIL_MS = 250
    }
}
