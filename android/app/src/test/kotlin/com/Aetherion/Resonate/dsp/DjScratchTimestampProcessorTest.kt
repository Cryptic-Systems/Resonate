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
    fun activeDeckControlRendersReverseAndForwardPcmInsideMedia3Processor() {
        val ledger = DjScratchTimestampLedger()
        val mailbox = DjScratchControlMailbox()
        val processor = DjScratchTimestampProcessor(ledger, mailbox)
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()

        // Prime the per-deck history with earlier source PCM.
        val history = ByteBuffer.allocateDirect(10).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(0, 1_000, 2_000, 3_000, 4_000).forEach { putShort(it.toShort()) }
            flip()
        }
        ledger.record(history, 10_000L)
        processor.queueInput(history)

        val reverseInput = ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(5_000, 6_000, 7_000, 8_000).forEach { putShort(it.toShort()) }
            flip()
        }
        ledger.record(reverseInput, 15_000L)
        assertTrue(mailbox.publish("track-1", true, -1.0, 17_000L))
        processor.queueInput(reverseInput)

        val reversed = processor.output.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(listOf(7_000, 6_000, 5_000, 4_000), List(4) { reversed.short.toInt() })
        assertEquals(reverseInput.limit(), reverseInput.position())

        // A newer forward command re-anchors the cursor and reads at 2x source
        // rate. This proves the PCM entering the native DSP stage is modified,
        // rather than merely recording touch telemetry and passing input through.
        val forwardInput = ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(9_000, 10_000, 11_000, 12_000).forEach { putShort(it.toShort()) }
            flip()
        }
        ledger.record(forwardInput, 19_000L)
        assertTrue(mailbox.publish("track-1", true, 2.0, 11_000L))
        processor.queueInput(forwardInput)

        val forwarded = processor.output.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(listOf(1_000, 3_000, 5_000, 7_000), List(4) { forwarded.short.toInt() })
        assertEquals(13, processor.pcmRingForTest()!!.availableFrames)
        val diagnostics = processor.diagnosticsSnapshot()
        assertEquals(3L, diagnostics["timestampMatches"])
        assertEquals(0L, diagnostics["timestampMisses"])
        assertEquals(2L, diagnostics["activeControlBlocks"])
        assertEquals(2L, diagnostics["renderedBlocks"])
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
            val diagnostics = DspEngineSinkHook.scratchDiagnostics("A")
            assertEquals(true, diagnostics["processorPresent"])
            assertEquals(false, diagnostics["configured"])
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
