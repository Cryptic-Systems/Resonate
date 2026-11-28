package com.aetherion.resonate.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchReleaseTailOwnershipTest {
    private val output = DjScratchReleaseTailOwnership.OutputContract(
        sampleRate = 48_000,
        channelCount = 2,
        pcmEncoding = 2,
        audioSessionId = 41,
        routeDeviceId = 9,
        routeGeneration = 7L,
        processingChainId = "resonate-dsp-v1",
    )

    @Test
    fun ownershipMovesCaptureToSealToSingleConsumerAndDrain() {
        val ownership = DjScratchReleaseTailOwnership()
        assertTrue(ownership.beginCapture(1L, "track-occurrence-3", output))
        assertTrue(ownership.seal(1L, retainedFrames = 120))
        assertEquals(
            DjScratchReleaseTailOwnership.Phase.SEALED,
            ownership.snapshot().phase,
        )

        assertTrue(ownership.transfer(1L, "release-renderer-1", output))
        assertFalse(ownership.transfer(1L, "second-renderer", output))
        assertFalse(ownership.beginDrain(1L, "second-renderer"))
        assertTrue(ownership.beginDrain(1L, "release-renderer-1"))

        assertTrue(ownership.recordDrainedFrames(1L, "release-renderer-1", 48))
        assertEquals(72, ownership.snapshot().remainingFrames)
        assertEquals(
            DjScratchReleaseTailOwnership.Phase.DRAINING,
            ownership.snapshot().phase,
        )

        assertTrue(ownership.recordDrainedFrames(1L, "release-renderer-1", 72))
        assertEquals(0, ownership.snapshot().remainingFrames)
        assertEquals(
            DjScratchReleaseTailOwnership.Phase.DRAINED,
            ownership.snapshot().phase,
        )
    }

    @Test
    fun transferRejectsDifferentRouteSessionFormatOrProcessingChain() {
        val ownership = DjScratchReleaseTailOwnership()
        assertTrue(ownership.beginCapture(1L, "track-a", output))
        assertTrue(ownership.seal(1L, retainedFrames = 32))

        val wrongSession = output.copy(audioSessionId = 42)
        val wrongRoute = output.copy(routeDeviceId = 10)
        val wrongRouteGeneration = output.copy(routeGeneration = 8L)
        val wrongFormat = output.copy(sampleRate = 44_100)
        val wrongChain = output.copy(processingChainId = "raw-audiotrack")

        assertFalse(ownership.transfer(1L, "renderer", wrongSession))
        assertFalse(ownership.transfer(1L, "renderer", wrongRoute))
        assertFalse(ownership.transfer(1L, "renderer", wrongRouteGeneration))
        assertFalse(ownership.transfer(1L, "renderer", wrongFormat))
        assertFalse(ownership.transfer(1L, "renderer", wrongChain))
        assertEquals(
            DjScratchReleaseTailOwnership.Phase.SEALED,
            ownership.snapshot().phase,
        )
        assertTrue(ownership.transfer(1L, "renderer", output))
    }

    @Test
    fun staleGenerationAndInvalidDrainCountsAreRejected() {
        val ownership = DjScratchReleaseTailOwnership()
        assertTrue(ownership.beginCapture(3L, "track-b", output))
        assertFalse(ownership.seal(2L, retainedFrames = 10))
        assertFalse(ownership.seal(3L, retainedFrames = 0))
        assertTrue(ownership.seal(3L, retainedFrames = 10))
        assertTrue(ownership.transfer(3L, "renderer", output))
        assertTrue(ownership.beginDrain(3L, "renderer"))

        assertFalse(ownership.recordDrainedFrames(2L, "renderer", 1))
        assertFalse(ownership.recordDrainedFrames(3L, "other-renderer", 1))
        assertFalse(ownership.recordDrainedFrames(3L, "renderer", 0))
        assertFalse(ownership.recordDrainedFrames(3L, "renderer", 11))
        assertEquals(10, ownership.snapshot().remainingFrames)
    }

    @Test
    fun abortInvalidatesOutstandingConsumerAndAllowsFreshGeneration() {
        val ownership = DjScratchReleaseTailOwnership()
        assertTrue(ownership.beginCapture(4L, "track-c", output))
        assertTrue(ownership.seal(4L, retainedFrames = 64))
        assertTrue(ownership.transfer(4L, "renderer", output))
        assertTrue(ownership.abort(5L))

        assertEquals(
            DjScratchReleaseTailOwnership.Phase.ABORTED,
            ownership.snapshot().phase,
        )
        assertFalse(ownership.beginDrain(4L, "renderer"))
        assertFalse(ownership.beginCapture(5L, "track-d", output))
        assertTrue(ownership.beginCapture(6L, "track-d", output))
    }

    @Test
    fun invalidOutputContractsCannotStartCapture() {
        val ownership = DjScratchReleaseTailOwnership()
        assertFalse(ownership.beginCapture(1L, "track", output.copy(sampleRate = 0)))
        assertFalse(ownership.beginCapture(1L, "track", output.copy(audioSessionId = 0)))
        assertFalse(ownership.beginCapture(1L, "track", output.copy(routeDeviceId = 0)))
        assertFalse(ownership.beginCapture(1L, "track", output.copy(processingChainId = " ")))
        assertFalse(ownership.beginCapture(1L, " ", output))
    }
}
