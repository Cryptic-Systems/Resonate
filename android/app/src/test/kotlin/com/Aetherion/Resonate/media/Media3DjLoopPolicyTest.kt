package com.Aetherion.Resonate.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Media3DjLoopPolicyTest {
    @Test
    fun acceptsValidAbsoluteLoopRangeInsideKnownTrackDuration() {
        val range = Media3DjLoopPolicy.create(
            startMs = 12_000L,
            endMs = 14_000L,
            durationMs = 180_000L,
        )
        assertNotNull(range)
        assertEquals(12_000L, range!!.startMs)
        assertEquals(14_000L, range.endMs)
        assertEquals(2_000L, range.durationMs)
    }

    @Test
    fun rejectsNegativeReversedAndTooShortRanges() {
        assertNull(Media3DjLoopPolicy.create(-1L, 500L, 10_000L))
        assertNull(Media3DjLoopPolicy.create(500L, 500L, 10_000L))
        assertNull(Media3DjLoopPolicy.create(700L, 600L, 10_000L))
        assertNull(
            Media3DjLoopPolicy.create(
                500L,
                500L + Media3DjLoopPolicy.MIN_LOOP_DURATION_MS - 1L,
                10_000L,
            ),
        )
    }

    @Test
    fun requiresKnownDurationAndKeepsEndBeforeTrackBoundary() {
        assertNull(Media3DjLoopPolicy.create(0L, 1_000L, null))
        assertNull(Media3DjLoopPolicy.create(0L, 1_000L, 0L))
        assertNull(Media3DjLoopPolicy.create(9_960L, 10_000L, 10_000L))
        assertNotNull(Media3DjLoopPolicy.create(8_000L, 9_900L, 10_000L))
    }

    @Test
    fun wrapsOnlyForMatchingTrackAtOrBeyondLoopOut() {
        assertTrue(Media3DjLoopPolicy.shouldWrap(true, "track-a", "track-a", 2_000L, 2_000L))
        assertFalse(Media3DjLoopPolicy.shouldWrap(false, "track-a", "track-a", 2_100L, 2_000L))
        assertFalse(Media3DjLoopPolicy.shouldWrap(true, "track-a", "track-b", 2_100L, 2_000L))
        assertFalse(Media3DjLoopPolicy.shouldWrap(true, "track-a", "track-a", 1_999L, 2_000L))
        assertFalse(Media3DjLoopPolicy.shouldWrap(true, "", "track-a", 2_100L, 2_000L))
    }
}
