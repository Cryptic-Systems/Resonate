package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class DjScratchReleaseTailBufferTest {
    @Test
    fun captureKeepsNewestBoundedFramesAndDoesNotAdvanceInput() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 1, capacityFrames = 3)
        val input = ByteBuffer.allocate(10).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(1).putShort(2).putShort(3).putShort(4).putShort(5)
        input.flip()

        assertEquals(3, tail.append(input))
        assertEquals(0, input.position())
        assertEquals(3, tail.availableFrames)
        assertFalse(tail.isSealed)
    }

    @Test
    fun sealedTailDrainsInOrderAcrossPartialDestinationBuffers() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 2, capacityFrames = 4)
        val input = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(1).putShort(2)
            .putShort(3).putShort(4)
            .putShort(5).putShort(6)
            .putShort(7).putShort(8)
        input.flip()
        assertEquals(4, tail.append(input))
        tail.seal()

        // One stereo frame is two PCM16 samples (four bytes).
        val first = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(1, tail.drainTo(first))
        first.flip()
        assertEquals(1, first.short.toInt())
        assertEquals(2, first.short.toInt())

        val second = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(3, tail.drainTo(second))
        second.flip()
        val expected = shortArrayOf(3, 4, 5, 6, 7, 8)
        expected.forEach { assertEquals(it.toInt(), second.short.toInt()) }
        assertEquals(0, tail.remainingFrames)
    }

    @Test
    fun captureStopsAfterSealAndClearStartsNewGeneration() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 1, capacityFrames = 2)
        val block = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(10).putShort(20)
        block.flip()
        assertEquals(2, tail.append(block))
        tail.seal()
        assertEquals(0, tail.append(block))
        assertEquals(2, tail.remainingFrames)

        tail.clear()
        assertFalse(tail.isSealed)
        assertEquals(0, tail.availableFrames)
        assertEquals(2, tail.append(block))
    }

    @Test
    fun overflowRetainsNewestFramesInChronologicalOrder() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 1, capacityFrames = 3)
        val input = ByteBuffer.allocate(10).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(1).putShort(2).putShort(3).putShort(4).putShort(5)
        input.flip()
        assertEquals(3, tail.append(input))
        tail.seal()

        val output = ByteBuffer.allocate(6).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(3, tail.drainTo(output))
        output.flip()
        shortArrayOf(3, 4, 5).forEach {
            assertEquals(it.toInt(), output.short.toInt())
        }
    }

    @Test
    fun discardBeforeAudibleMediaTimeDropsOnlyAlreadyPlayedFrames() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 1, capacityFrames = 4)
        val input = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(10).putShort(20).putShort(30).putShort(40)
        input.flip()
        assertEquals(4, tail.append(input, presentationTimeUs = 1_000_000L, sampleRate = 1_000))
        tail.seal()

        assertEquals(2, tail.discardBeforeMediaTimeUs(1_002_000L))
        assertEquals(1_002_000L, tail.nextFrameMediaTimeUs())
        val output = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(2, tail.drainTo(output))
        output.flip()
        assertEquals(30, output.short.toInt())
        assertEquals(40, output.short.toInt())
    }

    @Test
    fun timestampTrimFailsClosedWhenAnyCapturedBlockLacksTimestamp() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 1, capacityFrames = 4)
        val input = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putShort(1).putShort(2)
        input.flip()
        tail.append(input, presentationTimeUs = 1_000_000L, sampleRate = 1_000)
        tail.append(input)
        tail.seal()

        assertEquals(0, tail.discardBeforeMediaTimeUs(1_001_000L))
        assertEquals(null, tail.nextFrameMediaTimeUs())
    }

    @Test
    fun malformedPartialFrameIsRejected() {
        val tail = DjScratchReleaseTailBuffer(channelCount = 2, capacityFrames = 8)
        assertEquals(0, tail.append(ByteBuffer.allocate(6)))
        assertEquals(0, tail.availableFrames)
    }
}
