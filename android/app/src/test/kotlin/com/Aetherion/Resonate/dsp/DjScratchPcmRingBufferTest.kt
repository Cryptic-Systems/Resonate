package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchPcmRingBufferTest {
    private fun pcm16(vararg samples: Int): ByteBuffer =
        ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            samples.forEach { putShort(it.toShort()) }
            flip()
        }

    @Test
    fun appendsAndReadsInterleavedStereoFramesWithoutAdvancingInput() {
        val ring = DjScratchPcmRingBuffer(48_000, 2, 8)
        val input = pcm16(10, 11, 20, 21, 30, 31)

        assertEquals(3, ring.append(input, 1_000_000L))
        assertEquals(0, input.position())
        assertEquals(3, ring.availableFrames)

        val frame = ShortArray(2)
        assertTrue(ring.readFrame(1L, frame))
        assertEquals(20, frame[0].toInt())
        assertEquals(21, frame[1].toInt())
    }

    @Test
    fun wrapsAndRetainsOnlyNewestCapacityFrames() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 4)
        assertEquals(3, ring.append(pcm16(1, 2, 3), 0L))
        assertEquals(4, ring.append(pcm16(4, 5, 6, 7), 3_000L))

        assertEquals(7L, ring.nextWriteFrame)
        assertEquals(3L, ring.oldestFrame)
        assertEquals(4, ring.availableFrames)
        val sample = ShortArray(1)
        for (frame in 3L..6L) {
            assertTrue(ring.readFrame(frame, sample))
            assertEquals((frame + 1L).toInt(), sample[0].toInt())
        }
        assertFalse(ring.readFrame(2L, sample))
    }

    @Test
    fun storesMediaTimePerFrameAcrossDiscontinuousBlocks() {
        val ring = DjScratchPcmRingBuffer(48_000, 1, 16)
        ring.append(pcm16(1, 2, 3), 1_000_000L)
        ring.append(pcm16(4, 5), 2_000_000L)

        assertEquals(1_000_020L, ring.mediaTimeUsAtFrame(1L))
        assertEquals(2_000_000L, ring.mediaTimeUsAtFrame(3L))
        assertNull(ring.mediaTimeUsAtFrame(-1L))
    }

    @Test
    fun oversizedAppendKeepsNewestFramesAndCorrectPts() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 3)
        assertEquals(3, ring.append(pcm16(1, 2, 3, 4, 5), 10_000L))

        val sample = ShortArray(1)
        assertEquals(2L, ring.oldestFrame)
        assertTrue(ring.readFrame(2L, sample))
        assertEquals(3, sample[0].toInt())
        assertEquals(12_000L, ring.mediaTimeUsAtFrame(2L))
    }

    @Test
    fun interpolatesFractionalFramesAndRejectsMediaDiscontinuities() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 8)
        ring.append(pcm16(0, 1_000, 2_000), 10_000L)
        val sample = FloatArray(1)
        assertTrue(ring.readInterpolatedFrame(0.5, sample))
        assertEquals(500.0, sample[0].toDouble(), 0.0)
        assertTrue(ring.readInterpolatedFrame(2.0, sample))
        assertEquals(2_000.0, sample[0].toDouble(), 0.0)
        assertFalse(ring.readInterpolatedFrame(2.5, sample))

        ring.append(pcm16(3_000), 90_000L)
        assertFalse(ring.readInterpolatedFrame(2.5, sample))
    }

    @Test
    fun mapsMediaTimeToFractionalFrameAndRejectsOutsideHistory() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 8)
        ring.append(pcm16(0, 1_000, 2_000, 3_000), 10_000L)

        assertEquals(0.0, ring.framePositionAtMediaTimeUs(10_000L)!!, 0.0)
        assertEquals(1.5, ring.framePositionAtMediaTimeUs(11_500L)!!, 0.0)
        assertEquals(3.0, ring.framePositionAtMediaTimeUs(13_000L)!!, 0.0)
        assertNull(ring.framePositionAtMediaTimeUs(9_999L))
        assertNull(ring.framePositionAtMediaTimeUs(13_001L))
    }

    @Test
    fun rejectsMediaTimeAnchorsThatWouldCrossTimestampGaps() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 8)
        ring.append(pcm16(0, 1_000, 2_000), 10_000L)
        ring.append(pcm16(3_000, 4_000), 90_000L)

        assertNull(ring.framePositionAtMediaTimeUs(50_000L))
        assertEquals(3.0, ring.framePositionAtMediaTimeUs(90_000L)!!, 0.0)
    }

    @Test
    fun rejectsMediaTimeLookupAfterBackwardTimestampDiscontinuityUntilClear() {
        val ring = DjScratchPcmRingBuffer(1_000, 1, 8)
        ring.append(pcm16(0, 1_000), 10_000L)
        ring.append(pcm16(2_000, 3_000), 5_000L)

        assertNull(ring.framePositionAtMediaTimeUs(10_000L))
        ring.clear()
        ring.append(pcm16(4_000, 5_000), 20_000L)
        assertEquals(1.0, ring.framePositionAtMediaTimeUs(21_000L)!!, 0.0)
    }

    @Test
    fun rejectsMalformedAndNegativeTimestampBlocks() {
        val ring = DjScratchPcmRingBuffer(48_000, 2, 8)
        assertEquals(0, ring.append(ByteBuffer.allocate(3), 1_000L))
        assertEquals(0, ring.append(pcm16(1, 2), -1L))
        assertEquals(0, ring.availableFrames)
    }

    @Test
    fun clearInvalidatesAllFramesWithoutReusingOldFrameIndices() {
        val ring = DjScratchPcmRingBuffer(48_000, 1, 8)
        ring.append(pcm16(1, 2), 100L)
        ring.clear()

        assertEquals(2L, ring.nextWriteFrame)
        assertEquals(2L, ring.oldestFrame)
        assertEquals(0, ring.availableFrames)
        assertNull(ring.mediaTimeUsAtFrame(1L))

        ring.append(pcm16(3), 200L)
        assertEquals(3L, ring.nextWriteFrame)
        assertEquals(200L, ring.mediaTimeUsAtFrame(2L))
        assertNull(ring.mediaTimeUsAtFrame(1L))
    }

    @Test
    fun cursorSupportsForwardHoldReverseAndClampsToRetainedWindow() {
        val cursor = DjScratchFrameCursor()
        assertTrue(cursor.seekTo(10.0, 5L, 20L))
        assertEquals(12.0, cursor.advance(2, 5L, 20L)!!, 0.0)

        assertTrue(cursor.setVelocity(0.0))
        assertEquals(12.0, cursor.advance(8, 5L, 20L)!!, 0.0)

        assertTrue(cursor.setVelocity(-2.0))
        assertEquals(8.0, cursor.advance(2, 5L, 20L)!!, 0.0)
        assertEquals(5.0, cursor.advance(8, 5L, 20L)!!, 0.0)
        assertEquals(-2.0, cursor.velocity, 0.0)
    }

    @Test
    fun cursorRejectsNonFiniteControlsAndBoundsVelocity() {
        val cursor = DjScratchFrameCursor(maximumAbsVelocity = 3.0)
        assertFalse(cursor.setVelocity(Double.NaN))
        assertFalse(cursor.setVelocity(Double.POSITIVE_INFINITY))
        assertTrue(cursor.setVelocity(-9.0))
        assertEquals(-3.0, cursor.velocity, 0.0)
        assertFalse(cursor.seekTo(Double.NaN, 0L, 10L))
        assertFalse(cursor.seekTo(2.0, 4L, 4L))
        assertNotNull(cursor.advance(1, 0L, 10L))
    }
}
