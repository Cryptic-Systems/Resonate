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
        processor.flush() // Activate the configured format before queueInput.
        val input = stereoPcm()
        val original = bytes(input)
        ledger.record(input, 1_000_000L)

        processor.queueInput(input)

        assertTrue(bytes(processor.output).contentEquals(original))
        assertEquals(input.limit(), input.position())
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
        processor.flush()
        val input = stereoPcm()
        val original = bytes(input)

        processor.queueInput(input)

        assertTrue(bytes(processor.output).contentEquals(original))
        assertEquals(0, processor.pcmRingForTest()!!.availableFrames)
        assertNull(processor.lastConsumedTimestampForTest())
    }

    @Test
    fun flushInvalidatesCapturedHistoryAndResetReleasesIt() {
        val ledger = DjScratchTimestampLedger()
        val processor = DjScratchTimestampProcessor(ledger)
        processor.configure(AudioProcessor.AudioFormat(48_000, 2, C.ENCODING_PCM_16BIT))
        processor.flush()
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
    fun activeDeckControlRendersAnchoredPcmInsideMedia3Processor() {
        val ledger = DjScratchTimestampLedger()
        val mailbox = DjScratchControlMailbox()
        val processor = DjScratchTimestampProcessor(ledger, mailbox)
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()
        val sinkInput = ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(0)
            putShort(1_000)
            putShort(2_000)
            putShort(3_000)
            flip()
        }
        // The sink records its input identity, while the processor receives a
        // duplicate view. FIFO timestamp fallback must still anchor scratch.
        val input = sinkInput.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        ledger.record(sinkInput, 10_000L)
        assertTrue(mailbox.publish("track-1", true, 1.0, 10_000L))

        processor.queueInput(input)

        val rendered = processor.output.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0, rendered.short.toInt())
        assertEquals(1_000, rendered.short.toInt())
        assertEquals(2_000, rendered.short.toInt())
        assertEquals(3_000, rendered.short.toInt())
        assertEquals(4, processor.pcmRingForTest()!!.availableFrames)
        assertEquals(input.limit(), input.position())
        val diagnostics = processor.diagnosticsSnapshot()
        assertEquals(1L, diagnostics["timestampMatches"])
        assertEquals(0L, diagnostics["timestampMisses"])
        assertEquals(1L, diagnostics["activeControlBlocks"])
        assertEquals(1L, diagnostics["renderedBlocks"])
        assertEquals(0L, diagnostics["activeRenderFallbacks"])
    }

    @Test
    fun allocatesFourSecondsOfScratchHistoryPerDeck() {
        val processor = DjScratchTimestampProcessor(DjScratchTimestampLedger())
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()

        assertEquals(4_000, processor.pcmRingForTest()?.capacityFrames)
    }

    @Test
    fun media3FactoryInstallsTimestampScratchBeforeNativeDsp() {
        val chain = DspEngineSinkHook.createProcessors(
            "A",
            DjScratchTimestampLedger(),
            DjScratchControlMailbox(),
        )
        try {
            assertEquals(2, chain.size)
            assertTrue(chain[0] is DjScratchTimestampProcessor)
            assertTrue(chain[1] is DspEngineAudioProcessor)
        } finally {
            DspEngineSinkHook.forgetDeck("A")
        }
    }

    @Test
    fun unsupportedPcmLayoutDoesNotAllocateScratchHistory() {
        val processor = DjScratchTimestampProcessor(DjScratchTimestampLedger())
        processor.configure(AudioProcessor.AudioFormat(48_000, 6, C.ENCODING_PCM_16BIT))
        processor.flush()

        assertNull(processor.pcmRingForTest())
    }
}
