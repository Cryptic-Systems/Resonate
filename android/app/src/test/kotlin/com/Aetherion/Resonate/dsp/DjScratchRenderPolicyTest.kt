package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchRenderPolicyTest {
    private fun pcm16(vararg samples: Int): ByteBuffer =
        ByteBuffer.allocate(samples.size * Short.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .apply {
                samples.forEach { putShort(it.toShort()) }
                flip()
            }

    private fun samples(buffer: ByteBuffer): List<Int> {
        val copy = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        val result = ArrayList<Int>(copy.remaining() / Short.SIZE_BYTES)
        while (copy.remaining() >= Short.SIZE_BYTES) result += copy.short.toInt()
        return result
    }

    private fun command(
        sequence: Long,
        active: Boolean,
        velocity: Double,
        anchorUs: Long,
    ) = DjScratchControlMailbox.Snapshot(
        sequence = sequence,
        mediaId = "track-1",
        active = active,
        velocity = velocity,
        anchorMediaTimeUs = anchorUs,
    )

    @Test
    fun rendersForwardReverseAndHeldPlatterPositionsFromAnchoredPcm() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 32)
        ring.append(pcm16(0, 1_000, 2_000, 3_000, 4_000), 10_000L)
        val live = pcm16(5_000, 6_000)
        ring.append(live, 15_000L)
        val output = ByteBuffer.allocate(live.remaining())

        val forward = DjScratchRenderPolicy()
        assertTrue(forward.render(live, output, ring, command(1L, true, 1.0, 11_000L)))
        assertEquals(listOf(1_000, 2_000), samples(output))

        val reverse = DjScratchRenderPolicy()
        assertTrue(reverse.render(live, output, ring, command(1L, true, -1.0, 13_000L)))
        assertEquals(listOf(3_000, 2_000), samples(output))

        val held = DjScratchRenderPolicy()
        assertTrue(held.render(live, output, ring, command(1L, true, 0.0, 12_000L)))
        assertEquals(listOf(2_000, 2_000), samples(output))
    }

    @Test
    fun releaseCrossfadesToLiveMediaAndThenReturnsToPassThrough() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 32)
        ring.append(pcm16(0, 1_000, 2_000, 3_000, 4_000), 10_000L)
        val firstLiveBlock = pcm16(5_000, 6_000)
        ring.append(firstLiveBlock, 15_000L)
        val output = ByteBuffer.allocate(10)

        val policy = DjScratchRenderPolicy(releaseFadeMs = 5)
        assertTrue(
            policy.render(
                firstLiveBlock,
                output,
                ring,
                command(1L, true, 1.0, 12_000L),
            ),
        )
        assertEquals(listOf(2_000, 3_000), samples(output))
        assertTrue(policy.isScratchActiveForTest())

        val releaseLiveBlock = pcm16(7_000, 8_000, 9_000, 10_000, 11_000)
        ring.append(releaseLiveBlock, 17_000L)
        assertTrue(
            policy.render(
                releaseLiveBlock,
                output,
                ring,
                command(2L, false, 1.0, 17_000L),
            ),
        )
        assertEquals(listOf(4_000, 5_750, 7_500, 9_250, 11_000), samples(output))
        assertFalse(policy.isScratchActiveForTest())

        val nextLiveBlock = pcm16(12_000, 13_000)
        ring.append(nextLiveBlock, 22_000L)
        assertFalse(policy.render(nextLiveBlock, output, ring, null))
    }

    @Test
    fun forwardLookAheadMissFallsBackAndResumesFromSameCursorWhenPcmArrives() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 16)
        ring.append(pcm16(0, 1_000, 2_000, 3_000), 10_000L)
        val firstLiveBlock = pcm16(4_000, 5_000)
        ring.append(firstLiveBlock, 14_000L)
        val output = ByteBuffer.allocate(firstLiveBlock.remaining())
        val policy = DjScratchRenderPolicy()
        val control = command(1L, true, 1.0, 15_000L)

        assertFalse(policy.render(firstLiveBlock, output, ring, control))
        assertFalse(policy.isScratchActiveForTest())

        val nextLiveBlock = pcm16(6_000, 7_000)
        ring.append(nextLiveBlock, 16_000L)
        assertTrue(policy.render(nextLiveBlock, output, ring, control))
        assertEquals(listOf(5_000, 6_000), samples(output))
        assertTrue(policy.isScratchActiveForTest())
    }

    @Test
    fun invalidAnchorFailsClosedWithoutLeavingScratchActive() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 8)
        ring.append(pcm16(0, 1_000, 2_000), 10_000L)
        val input = pcm16(3_000)
        val output = ByteBuffer.allocate(input.remaining())
        val policy = DjScratchRenderPolicy()

        assertFalse(policy.render(input, output, ring, command(1L, true, 1.0, 99_000L)))
        assertFalse(policy.isScratchActiveForTest())
    }

    @Test
    fun rejectsOutOfRangeVelocityAndPreservesNormalPlaybackFallback() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 8)
        ring.append(pcm16(0, 1_000), 10_000L)
        val input = pcm16(0, 1_000)
        val output = ByteBuffer.allocate(input.remaining())
        val policy = DjScratchRenderPolicy()

        assertFalse(policy.render(input, output, ring, command(1L, true, 8.0, 10_000L)))
        assertFalse(policy.isScratchActiveForTest())
        assertEquals(listOf(0, 1_000), samples(input))
    }
    @Test
    fun defaultReleaseEnvelopeIsLongEnoughToAvoidAnAbruptPlatterCut() {
        assertEquals(20, DjScratchRenderPolicy.DEFAULT_RELEASE_FADE_MS)
        assertEquals(20, DjScratchRenderPolicy().releaseFadeMsForTest())
    }

    @Test
    fun defaultReleaseBlendsAcrossPcmBlocksAndEndsAtLiveSignal() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 128)
        ring.append(pcm16(*IntArray(100) { it * 100 }.toTypedArray().toIntArray()), 0L)
        val activeInput = pcm16(10_000, 10_100)
        ring.append(activeInput, 100_000L)
        val output = ByteBuffer.allocate(40)
        val policy = DjScratchRenderPolicy()

        assertTrue(policy.render(activeInput, output, ring, command(1L, true, 1.0, 10_000L)))

        val releaseFirst = pcm16(*IntArray(10) { 20_000 }.toTypedArray().toIntArray())
        ring.append(releaseFirst, 102_000L)
        assertTrue(policy.render(releaseFirst, output, ring, command(2L, false, 1.0, 102_000L)))
        val firstHalf = samples(output)
        assertEquals(1_200, firstHalf.first())
        assertTrue(firstHalf.last() > firstHalf.first())
        assertTrue(policy.isScratchActiveForTest())

        val releaseSecond = pcm16(*IntArray(10) { 24_000 }.toTypedArray().toIntArray())
        ring.append(releaseSecond, 112_000L)
        assertTrue(policy.render(releaseSecond, output, ring, command(2L, false, 1.0, 102_000L)))
        val secondHalf = samples(output)
        assertEquals(24_000, secondHalf.last())
        assertFalse(policy.isScratchActiveForTest())
    }

}
