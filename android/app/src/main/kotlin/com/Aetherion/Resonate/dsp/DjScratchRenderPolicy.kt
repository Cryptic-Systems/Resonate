package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Per-physical-deck PCM render policy, owned exclusively by the audio thread.
 *
 * Active platter control reads timestamp-anchored frames from that deck's
 * bounded PCM history. Releasing the platter crossfades back to the live
 * Media3 input over a short fixed interval. Any invalid anchor/history/layout
 * fails closed: the caller must forward the untouched input block.
 *
 * No locks, callbacks, collection operations, or per-frame allocations occur
 * in render(). The two-sample scratch array is allocated once per policy.
 */
internal class DjScratchRenderPolicy(
    private val releaseFadeMs: Int = DEFAULT_RELEASE_FADE_MS,
) {
    companion object {
        const val DEFAULT_RELEASE_FADE_MS = 5
        private const val MAX_ABS_VELOCITY = 4.0
    }

    private val interpolated = FloatArray(2)
    private var cursorFrame = 0.0
    private var velocity = 1.0
    private var lastSequence = Long.MIN_VALUE
    private var releaseFramesRemaining = 0
    private var releaseFramesTotal = 0
    private var scratchActive = false

    init {
        require(releaseFadeMs in 1..50) { "releaseFadeMs must be between 1 and 50" }
    }

    internal fun isScratchActiveForTest(): Boolean = scratchActive
    internal fun cursorFrameForTest(): Double = cursorFrame

    /**
     * Renders a complete PCM16 block into [output]. The input buffer is never
     * advanced or modified. Returns true only when output contains a complete
     * scratch/release block; false means the caller must pass input through.
     */
    fun render(
        input: ByteBuffer,
        output: ByteBuffer,
        ring: DjScratchPcmRingBuffer,
        snapshot: DjScratchControlMailbox.Snapshot?,
    ): Boolean {
        val inputBytes = input.remaining()
        val bytesPerFrame = ring.channelCount * Short.SIZE_BYTES
        if (snapshot == null || inputBytes == 0 || inputBytes % bytesPerFrame != 0 ||
            output.capacity() < inputBytes || ring.availableFrames == 0
        ) {
            reset()
            return false
        }

        val frameCount = inputBytes / bytesPerFrame
        val source = input.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        output.clear()
        output.order(ByteOrder.LITTLE_ENDIAN)

        if (snapshot.active) {
            if (!snapshot.velocity.isFinite() ||
                kotlin.math.abs(snapshot.velocity) > MAX_ABS_VELOCITY
            ) {
                reset()
                return false
            }
            if (snapshot.sequence != lastSequence) {
                val anchor = ring.framePositionAtMediaTimeUs(snapshot.anchorMediaTimeUs)
                if (anchor == null) {
                    reset()
                    return false
                }
                cursorFrame = anchor
                velocity = snapshot.velocity
                lastSequence = snapshot.sequence
            }
            for (frame in 0 until frameCount) {
                if (!ring.readInterpolatedFrame(cursorFrame, interpolated)) {
                    reset()
                    return false
                }
                for (channel in 0 until ring.channelCount) {
                    output.putShort(toPcm16(interpolated[channel]))
                }
                cursorFrame += velocity
            }
            scratchActive = true
            releaseFramesRemaining = 0
            releaseFramesTotal = 0
            output.flip()
            return true
        }

        if (!scratchActive) return false
        if (snapshot.sequence != lastSequence) {
            lastSequence = snapshot.sequence
            releaseFramesTotal = maxOf(1, ring.sampleRate * releaseFadeMs / 1_000)
            releaseFramesRemaining = releaseFramesTotal
        }
        if (releaseFramesRemaining <= 0) {
            reset()
            return false
        }

        val liveStartPosition = source.position()
        val fadeFrames = minOf(frameCount, releaseFramesRemaining)
        for (frame in 0 until fadeFrames) {
            if (!ring.readInterpolatedFrame(cursorFrame, interpolated)) {
                reset()
                return false
            }
            val liveOffset = liveStartPosition + frame * bytesPerFrame
            val alpha = 1.0f -
                (releaseFramesRemaining - frame).toFloat() / releaseFramesTotal.toFloat()
            for (channel in 0 until ring.channelCount) {
                val liveSample = source.getShort(liveOffset + channel * Short.SIZE_BYTES).toFloat()
                val mixed = interpolated[channel] * (1.0f - alpha) + liveSample * alpha
                output.putShort(toPcm16(mixed))
            }
            cursorFrame += 1.0
        }
        releaseFramesRemaining -= fadeFrames

        val remainingFrames = frameCount - fadeFrames
        if (remainingFrames > 0) {
            val remainingBytes = remainingFrames * bytesPerFrame
            source.position(liveStartPosition + fadeFrames * bytesPerFrame)
            val liveTail = source.slice().order(ByteOrder.LITTLE_ENDIAN)
            liveTail.limit(remainingBytes)
            output.put(liveTail)
        }

        if (releaseFramesRemaining == 0) {
            scratchActive = false
            velocity = 1.0
            lastSequence = Long.MIN_VALUE
        }
        output.flip()
        return true
    }

    /** Clears per-track/per-flush cursor state without touching the PCM ring. */
    fun reset() {
        cursorFrame = 0.0
        velocity = 1.0
        lastSequence = Long.MIN_VALUE
        releaseFramesRemaining = 0
        releaseFramesTotal = 0
        scratchActive = false
    }

    private fun toPcm16(sample: Float): Short =
        sample.coerceIn(Short.MIN_VALUE.toFloat(), Short.MAX_VALUE.toFloat())
            .roundToInt().toShort()
}
