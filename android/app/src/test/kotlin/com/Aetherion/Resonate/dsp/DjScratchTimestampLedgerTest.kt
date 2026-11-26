package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchTimestampLedgerTest {
    @Test
    fun recordsTimestampByBufferIdentityAndConsumesOnce() {
        val ledger = DjScratchTimestampLedger()
        val first = ByteBuffer.allocateDirect(4096)
        val equalButDistinct = ByteBuffer.allocateDirect(4096)

        ledger.record(first, 1_250_000L)
        assertNull(ledger.consume(equalButDistinct, 48_000, 2))

        val block = ledger.consume(first, 48_000, 2)
        assertEquals(1_250_000L, block?.presentationTimeUs)
        assertEquals(512, block?.frameCount)
        assertEquals(48_000, block?.sampleRate)
        assertEquals(2, block?.channelCount)
        assertNull(ledger.consume(first, 48_000, 2))
    }

    @Test
    fun retryDoesNotReplaceOriginalTimestamp() {
        val ledger = DjScratchTimestampLedger()
        val buffer = ByteBuffer.allocateDirect(2048)

        ledger.record(buffer, 2_000_000L)
        ledger.record(buffer, 2_100_000L)

        assertEquals(2_000_000L, ledger.consume(buffer, 44_100, 2)?.presentationTimeUs)
    }

    @Test
    fun rejectsInvalidFormatAndMisalignedPcmWithoutRetainingEntry() {
        val ledger = DjScratchTimestampLedger()
        val mono = ByteBuffer.allocateDirect(5)
        ledger.record(mono, 100L)
        assertNull(ledger.consume(mono, 48_000, 1))
        assertEquals(0, ledger.pendingCountForTest())

        val unsupported = ByteBuffer.allocateDirect(8)
        ledger.record(unsupported, 200L)
        assertNull(ledger.consume(unsupported, 48_000, 6))
        assertEquals(0, ledger.pendingCountForTest())
    }

    @Test
    fun mapsFrameOffsetsToMediaTimeAndRejectsOutOfRangeOffsets() {
        val ledger = DjScratchTimestampLedger()
        val buffer = ByteBuffer.allocateDirect(800)
        ledger.record(buffer, 1_000_000L)
        val block = ledger.consume(buffer, 48_000, 2)!!

        assertEquals(1_000_000L, block.presentationTimeUsAtFrame(0))
        assertEquals(1_000_500L, block.presentationTimeUsAtFrame(24))
        assertEquals(1_004_166L, block.presentationTimeUsAtFrame(200))
        assertNull(block.presentationTimeUsAtFrame(201))
        assertNull(block.presentationTimeUsAtFrame(-1))
    }

    @Test
    fun clearInvalidatesOutstandingBuffers() {
        val ledger = DjScratchTimestampLedger()
        val buffer = ByteBuffer.allocateDirect(64)
        ledger.record(buffer, 300L)
        assertEquals(1, ledger.pendingCountForTest())

        ledger.clear()

        assertTrue(ledger.pendingCountForTest() == 0)
        assertFalse(ledger.consume(buffer, 48_000, 2) != null)
    }
}
