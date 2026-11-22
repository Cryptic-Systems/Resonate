package com.Aetherion.Resonate

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PcmAnalysisWindowPolicyTest {
    @Test
    fun acceptsOutputFromAWindowWithANonZeroTrackOffset() {
        assertTrue(
            isPcmTimestampWithinWindowEnd(
                presentationTimeUs = 60_000_000L,
                requestedStartMs = 60_000L,
                maxDurationUs = 8_000_000L,
            ),
        )
    }

    @Test
    fun acceptsSeekPrerollAndTheInclusiveWindowEnd() {
        assertTrue(
            isPcmTimestampWithinWindowEnd(
                presentationTimeUs = 58_000_000L,
                requestedStartMs = 60_000L,
                maxDurationUs = 8_000_000L,
            ),
        )
        assertTrue(
            isPcmTimestampWithinWindowEnd(
                presentationTimeUs = 68_000_000L,
                requestedStartMs = 60_000L,
                maxDurationUs = 8_000_000L,
            ),
        )
    }

    @Test
    fun rejectsOutputAfterTheRequestedWindowEnd() {
        assertFalse(
            isPcmTimestampWithinWindowEnd(
                presentationTimeUs = 68_000_001L,
                requestedStartMs = 60_000L,
                maxDurationUs = 8_000_000L,
            ),
        )
    }

    @Test
    fun rejectsInvalidInputsAndSaturatesOverflowingEndTime() {
        assertFalse(isPcmTimestampWithinWindowEnd(-1L, 0L, 8_000_000L))
        assertFalse(isPcmTimestampWithinWindowEnd(1L, -1L, 8_000_000L))
        assertFalse(isPcmTimestampWithinWindowEnd(1L, 0L, -1L))
        assertTrue(
            isPcmTimestampWithinWindowEnd(
                presentationTimeUs = Long.MAX_VALUE,
                requestedStartMs = Long.MAX_VALUE,
                maxDurationUs = Long.MAX_VALUE,
            ),
        )
    }
}
