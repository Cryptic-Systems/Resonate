package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchTimestampLedgerTest {
    private fun stereoFrames(count: Int): ByteBuffer =
        ByteBuffer.allocateDirect(count * 2 * Short.SIZE_BYTES)

    @Test
    fun consumesSinkSpansInFifoOrderRatherThanBufferIdentityOrder() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
        val first = stereoFrames(4)
        val second = stereoFrames(4)
        ledger.record(first, 1_250_000L)
        ledger.record(second, 1_250_083L)

        // The downstream processor receives a new buffer spanning both source
        // buffers after Media3's built-in processors have run.
        val output = stereoFrames(8)
        val timestamp = ledger.consume(output, 48_000, 2)

        assertEquals(1_250_000L, timestamp?.presentationTimeUs)
        assertEquals(8, timestamp?.frameCount)
        assertEquals(0, ledger.pendingCountForTest())
    }

    @Test
    fun encoderDelayIsSkippedAcrossInputBufferBoundaries() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 1_000, channelCount = 2, encoderDelayFrames = 3)
        ledger.record(stereoFrames(2), 10_000L)
        ledger.record(stereoFrames(4), 12_000L)

        val timestamp = ledger.consume(stereoFrames(3), 1_000, 2)

        assertEquals(13_000L, timestamp?.presentationTimeUs)
        assertEquals(3, timestamp?.frameCount)
        assertEquals(0, ledger.trimFramesRemainingForTest())
        assertEquals(0, ledger.pendingCountForTest())
    }

    @Test
    fun channelRemappingPreservesFrameTimeline() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
        ledger.record(stereoFrames(2), 3_000_000L)

        // Media3 may remap stereo input to mono before the user processor.
        val monoOutput = ByteBuffer.allocateDirect(2 * Short.SIZE_BYTES)
        val timestamp = ledger.consume(monoOutput, 48_000, 1)

        assertEquals(3_000_000L, timestamp?.presentationTimeUs)
        assertEquals(2, timestamp?.frameCount)
        assertEquals(1, timestamp?.channelCount)
    }

    @Test
    fun retriedSinkBufferKeepsOriginalPtsAndIsNotQueuedTwice() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 44_100, channelCount = 2, encoderDelayFrames = 0)
        val buffer = stereoFrames(256)

        ledger.record(buffer, 2_000_000L)
        ledger.record(buffer, 2_100_000L)

        assertEquals(1, ledger.pendingCountForTest())
        assertEquals(2_000_000L, ledger.consume(stereoFrames(256), 44_100, 2)?.presentationTimeUs)
    }

    @Test
    fun rejectsMisalignedAndUnsupportedPcmWithoutRetainingStaleSpans() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 48_000, channelCount = 1, encoderDelayFrames = 0)
        val malformed = ByteBuffer.allocateDirect(5)
        ledger.record(malformed, 100L)
        assertEquals(0, ledger.pendingCountForTest())

        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
        ledger.record(stereoFrames(2), 200L)
        assertNull(ledger.consume(ByteBuffer.allocateDirect(24), 48_000, 6))
        assertEquals(0, ledger.pendingCountForTest())
    }

    @Test
    fun mapsFrameOffsetsToMediaTimeAndRejectsOutOfRangeOffsets() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
        ledger.record(stereoFrames(200), 1_000_000L)
        val block = ledger.consume(stereoFrames(200), 48_000, 2)!!

        assertEquals(1_000_000L, block.presentationTimeUsAtFrame(0))
        assertEquals(1_000_500L, block.presentationTimeUsAtFrame(24))
        assertEquals(1_004_166L, block.presentationTimeUsAtFrame(200))
        assertNull(block.presentationTimeUsAtFrame(201))
        assertNull(block.presentationTimeUsAtFrame(-1))
    }

    @Test
    fun discontinuityInvalidatesOldSpansWithoutReapplyingEncoderDelay() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 1_000, channelCount = 2, encoderDelayFrames = 2)
        ledger.record(stereoFrames(4), 1_000L)

        ledger.handleDiscontinuity()

        assertEquals(0, ledger.pendingCountForTest())
        assertEquals(0, ledger.trimFramesRemainingForTest())
        ledger.record(stereoFrames(2), 20_000L)
        assertEquals(20_000L, ledger.consume(stereoFrames(2), 1_000, 2)?.presentationTimeUs)
    }

    @Test
    fun flushRestoresConfiguredEncoderDelay() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 1_000, channelCount = 2, encoderDelayFrames = 2)
        ledger.record(stereoFrames(4), 10_000L)
        assertEquals(2, ledger.trimFramesRemainingForTest())

        ledger.resetForFlush()

        assertEquals(2, ledger.trimFramesRemainingForTest())
        assertEquals(0, ledger.pendingCountForTest())
        ledger.record(stereoFrames(4), 10_000L)
        assertEquals(12_000L, ledger.consume(stereoFrames(2), 1_000, 2)?.presentationTimeUs)
    }

    @Test
    fun clearInvalidatesOutstandingBuffersAndFormat() {
        val ledger = DjScratchTimestampLedger()
        ledger.configure(sampleRate = 48_000, channelCount = 2, encoderDelayFrames = 0)
        val buffer = stereoFrames(8)
        ledger.record(buffer, 300L)
        assertEquals(1, ledger.pendingCountForTest())

        ledger.clear()

        assertEquals(0, ledger.pendingCountForTest())
        assertFalse(ledger.consume(buffer, 48_000, 2) != null)
    }
}
