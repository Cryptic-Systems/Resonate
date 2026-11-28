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
        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
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
        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
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
    fun activeMailboxRemainsPassThroughWhileAudibleScratchGateIsClosed() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 1_000, channelCount = 1, encoderDelayFrames = 0)
        val mailbox = DjScratchControlMailbox()
        val processor = DjScratchTimestampProcessor(ledger, mailbox)
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()

        val history = ByteBuffer.allocateDirect(10).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(0, 1_000, 2_000, 3_000, 4_000).forEach { putShort(it.toShort()) }
            flip()
        }
        val historyOriginal = bytes(history)
        ledger.record(history, 10_000L)
        processor.queueInput(history)
        assertTrue(bytes(processor.output).contentEquals(historyOriginal))

        val activeInput = ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(5_000, 6_000, 7_000, 8_000).forEach { putShort(it.toShort()) }
            flip()
        }
        val original = bytes(activeInput)
        ledger.record(activeInput, 15_000L)
        assertTrue(mailbox.publish("track-1", true, -1.0, 17_000L))
        processor.queueInput(activeInput)

        assertTrue(bytes(processor.output).contentEquals(original))
        assertEquals(activeInput.limit(), activeInput.position())
        assertEquals(9, processor.pcmRingForTest()!!.availableFrames)
        val diagnostics = processor.diagnosticsSnapshot()
        assertEquals(2L, diagnostics["timestampMatches"])
        assertEquals(0L, diagnostics["timestampMisses"])
        assertEquals(1L, diagnostics["activeControlBlocks"])
        assertEquals(0L, diagnostics["renderedBlocks"])
        assertEquals(1L, diagnostics["activeRenderFallbacks"])
    }


    @Test
    fun postDspCaptureTimestampFollowsScratchCursorInsteadOfDecoderAheadPts() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 1_000, channelCount = 1, encoderDelayFrames = 0)
        val mailbox = DjScratchControlMailbox()
        val processor = DjScratchTimestampProcessor(
            ledger = ledger,
            controlMailbox = mailbox,
            enableScratchRendering = true,
        )
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()

        val history = ByteBuffer.allocateDirect(10).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(100, 200, 300, 400, 500).forEach { putShort(it.toShort()) }
            flip()
        }
        ledger.record(history, 10_000L)
        processor.queueInput(history)

        val active = ByteBuffer.allocateDirect(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            listOf(600, 700, 800, 900).forEach { putShort(it.toShort()) }
            flip()
        }
        ledger.record(active, 15_000L)
        assertTrue(mailbox.publish("track-1", true, 1.0, 12_000L))
        processor.queueInput(active)

        assertEquals(15_000L, processor.lastConsumedTimestampForTest()?.presentationTimeUs)
        assertEquals(12_000L, processor.releaseTailTimestampUs())
        assertEquals(16_000L, processor.diagnosticsSnapshot()["cursorMediaTimeUs"])
    }

    @Test
    fun allocatesFourSecondsOfScratchHistoryPerDeck() {
        val processor = DjScratchTimestampProcessor(DjScratchTimestampLedger())
        processor.configure(AudioProcessor.AudioFormat(1_000, 1, C.ENCODING_PCM_16BIT))
        processor.flush()

        assertEquals(4_000, processor.pcmRingForTest()?.capacityFrames)
    }

    @Test
    fun media3FactoryInstallsTimestampScratchBeforeNativeDspAndReleaseCaptureAfterDsp() {
        val chain = DspEngineSinkHook.createProcessors(
            "A",
            DjScratchTimestampLedger(),
            DjScratchControlMailbox(),
        )
        try {
            assertEquals(3, chain.size)
            assertTrue(chain[0] is DjScratchTimestampProcessor)
            assertTrue(chain[1] is DspEngineAudioProcessor)
            assertTrue(chain[2] is DjScratchReleaseTailCaptureProcessor)
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
