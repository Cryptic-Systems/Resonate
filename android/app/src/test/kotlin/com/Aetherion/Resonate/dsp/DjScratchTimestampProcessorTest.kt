package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchTimestampProcessorTest {
    private fun stereoPcm(): ByteBuffer =
        ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(100)
            putShort(101)
            putShort(200)
            putShort(201)
            flip()
        }

    private fun bytes(buffer: ByteBuffer): ByteArray {
        val copy = buffer.duplicate()
        return ByteArray(copy.remaining()).also(copy::get)
    }

    @Test
    fun capturesTimestampedPcmBeforeDspAndPassesOriginalAudioThrough() {
        val ledger = DjScratchTimestampLedger()
        val processor = DjScratchTimestampProcessor(ledger)
        processor.configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_16BIT))
        val input = stereoPcm()
        val original = bytes(input)
        ledger.record(input, 1_000_000L)

        processor.queueInput(input)

        assertTrue(bytes(processor.output).contentEquals(original))
        assertEquals(0, input.position())
        assertEquals(1_000_000L, processor.lastConsumedTimestampForTest()?.presentationTimeUs)
        val ring = processor.pcmRingForTest()!!
        assertEquals(2, ring.availableFrames)
        assertEquals(1_000_020L, ring.mediaTimeUsAtFrame(1L))
        val frame = ShortArray(2)
        assertTrue(ring.readFrame(1L, frame))
        assertEquals(200, frame[0].toInt())
        assertEquals(201, frame[1].toInt())
    }

    @Test
    fun untimestampedBlocksRemainPassThroughAndAreNotAddedToHistory() {
        val ledger = DjScratchTimestampLedger()
        val processor = DjScratchTimestampProcessor(ledger)
        processor.configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_16BIT))
        val input = stereoPcm()

        processor.queueInput(input)

        assertTrue(bytes(processor.output).contentEquals(bytes(input)))
        assertEquals(0, processor.pcmRingForTest()!!.availableFrames)
        assertNull(processor.lastConsumedTimestampForTest())
    }

    @Test
    fun flushInvalidatesCapturedHistoryAndResetReleasesIt() {
        val ledger = DjScratchTimestampLedger()
        val processor = DjScratchTimestampProcessor(ledger)
        processor.configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_16BIT))
        val input = stereoPcm()
        ledger.record(input, 1_000L)
        processor.queueInput(input)
        val ring = processor.pcmRingForTest()!!
        assertEquals(2, ring.availableFrames)

        processor.flush()

        assertEquals(0, ring.availableFrames)
        assertNull(processor.lastConsumedTimestampForTest())

        processor.reset()
        assertNull(processor.pcmRingForTest())
    }

    @Test
    fun unsupportedPcmLayoutDoesNotAllocateScratchHistory() {
        val processor = DjScratchTimestampProcessor(DjScratchTimestampLedger())
        processor.configure(AudioProcessor.AudioFormat(48_000, 6, C.ENCODING_PCM_16BIT))

        assertNull(processor.pcmRingForTest())
    }
}
