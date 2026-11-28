package com.aetherion.resonate.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchReleaseHandoffTest {
    @Test
    fun releaseFreezesCursorTargetAndAllowsOnlyOneSeekClaim() {
        val handoff = DjScratchReleaseHandoff()
        assertTrue(handoff.begin(4L, "track-a"))
        assertEquals(2_345_000L, handoff.requestRelease(4L, "track-a", 2_345_000L))
        assertEquals(DjScratchReleaseHandoff.Phase.RELEASE_REQUESTED, handoff.snapshot().phase)
        assertTrue(handoff.markSeekIssued(4L, "track-a"))
        assertFalse(handoff.markSeekIssued(4L, "track-a"))
        assertEquals(2_345_000L, handoff.snapshot().targetPositionUs)
    }

    @Test
    fun liveDecoderPcmMustAlignBeforeCrossfadeCanBegin() {
        val handoff = DjScratchReleaseHandoff(alignmentToleranceUs = 10_000L)
        assertTrue(handoff.begin(2L, "track-b"))
        handoff.requestRelease(2L, "track-b", 5_000_000L)
        handoff.markSeekIssued(2L, "track-b")

        assertFalse(handoff.observePostSeekPcm(2L, "track-b", 4_900_000L))
        assertFalse(handoff.observePostSeekPcm(2L, "track-b", 5_011_000L))
        assertEquals(DjScratchReleaseHandoff.Phase.WAITING_FOR_ALIGNMENT, handoff.snapshot().phase)
        assertTrue(handoff.observePostSeekPcm(2L, "track-b", 5_009_000L))
        assertEquals(DjScratchReleaseHandoff.Phase.CROSSFADE_READY, handoff.snapshot().phase)
        assertTrue(handoff.complete(2L, "track-b"))
        assertEquals(DjScratchReleaseHandoff.Phase.COMPLETE, handoff.snapshot().phase)
    }

    @Test
    fun staleGenerationOrTrackCannotAdvanceHandoff() {
        val handoff = DjScratchReleaseHandoff()
        assertTrue(handoff.begin(8L, "track-a"))
        assertNull(handoff.requestRelease(8L, "track-b", 100L))
        assertNull(handoff.requestRelease(7L, "track-a", 100L))
        assertEquals(DjScratchReleaseHandoff.Phase.SCRATCHING, handoff.snapshot().phase)

        handoff.abort(9L)
        assertFalse(handoff.markSeekIssued(8L, "track-a"))
        assertFalse(handoff.observePostSeekPcm(8L, "track-a", 100L))
        assertEquals(DjScratchReleaseHandoff.Phase.ABORTED, handoff.snapshot().phase)
    }

    @Test
    fun invalidReleaseTargetDoesNotMutateState() {
        val handoff = DjScratchReleaseHandoff()
        assertTrue(handoff.begin(1L, "track-a"))
        assertNull(handoff.requestRelease(1L, "track-a", -1L))
        assertEquals(DjScratchReleaseHandoff.Phase.SCRATCHING, handoff.snapshot().phase)
    }
}
