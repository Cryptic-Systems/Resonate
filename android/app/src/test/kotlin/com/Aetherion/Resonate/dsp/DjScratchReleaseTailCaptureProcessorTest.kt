package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchReleaseTailCaptureProcessorTest {
    @Test
    fun capturesPostDspPcmWithoutChangingMedia3Output() {
        val processor = DjScratchReleaseTailCaptureProcessor()
        processor.configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_16BIT))
        processor.flush()
        assertTrue(processor.beginCapture())

        val input = ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN)
        input.putShort(11).putShort(12).putShort(21).putShort(22).flip()
        processor.queueInput(input)

        val output = processor.output.order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(8, output.remaining())
        assertEquals(11, output.short.toInt())
        assertEquals(12, output.short.toInt())
        assertEquals(21, output.short.toInt())
        assertEquals(22, output.short.toInt())

        val sealed = processor.sealCapture()
        assertNotNull(sealed)
        assertEquals(2, sealed!!.availableFrames)
        assertEquals(2, sealed.remainingFrames)
    }

    @Test
    fun captureCarriesTimestampFromPrecedingScratchProcessor() {
        val processor = DjScratchReleaseTailCaptureProcessor { 2_000_000L }
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()
        assertTrue(processor.beginCapture())
        val input = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN)
        input.putShort(7).putShort(8).flip()
        processor.queueInput(input)

        val tail = processor.sealCapture()
        assertNotNull(tail)
        assertTrue(tail!!.hasValidTimestamps)
        assertEquals(2_000_000L, tail.nextFrameMediaTimeUs())
    }

    @Test
    fun captureIsOptInAndSealDetachesCurrentGeneration() {
        val processor = DjScratchReleaseTailCaptureProcessor()
        processor.configure(AudioProcessor.AudioFormat(44_100, 1, C.ENCODING_PCM_16BIT))
        processor.flush()

        val input = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN)
        input.putShort(1).putShort(2).flip()
        processor.queueInput(input)
        assertEquals(0, processor.sealCapture()?.availableFrames ?: 0)

        assertTrue(processor.beginCapture())
        val captured = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN)
        captured.putShort(3).putShort(4).flip()
        processor.queueInput(captured)
        val tail = processor.sealCapture()
        assertNotNull(tail)
        assertEquals(2, tail!!.availableFrames)
        assertTrue(tail.isSealed)
    }
}
