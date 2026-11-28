package com.aetherion.resonate.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchControlMailboxTest {
    @Test
    fun publishesAtomicSnapshotAndMonotonicSequence() {
        val mailbox = DjScratchControlMailbox()
        assertTrue(mailbox.publish("track-A", true, -1.5, 12_000L))
        val first = mailbox.snapshot()!!
        assertEquals("track-A", first.mediaId)
        assertEquals(-1.5, first.velocity, 0.0)
        assertTrue(first.active)

        assertTrue(mailbox.publish("track-A", true, 2.0, 13_000L))
        val second = mailbox.snapshot()!!
        assertTrue(second.sequence > first.sequence)
        assertEquals(2.0, second.velocity, 0.0)
    }

    @Test
    fun rejectsInvalidControlsWithoutReplacingLastGoodSnapshot() {
        val mailbox = DjScratchControlMailbox()
        assertTrue(mailbox.publish("track-B", true, 1.0, 0L))
        val before = mailbox.snapshot()
        assertFalse(mailbox.publish("", true, 1.0, 0L))
        assertFalse(mailbox.publish("track-B", true, Double.NaN, 0L))
        assertFalse(mailbox.publish("track-B", true, 5.0, 0L))
        assertFalse(mailbox.publish("track-B", true, 1.0, -1L))
        assertEquals(before, mailbox.snapshot())
    }

    @Test
    fun inactiveCommandNormalizesVelocityAndRetainsMediaAnchor() {
        val mailbox = DjScratchControlMailbox()
        assertTrue(mailbox.publish("track-C", false, -3.0, 99_000L))
        val command = mailbox.snapshot()!!
        assertFalse(command.active)
        assertEquals(1.0, command.velocity, 0.0)
        assertEquals(99_000L, command.anchorMediaTimeUs)
    }

    @Test
    fun clearCannotEraseAReplacementTrackCommand() {
        val mailbox = DjScratchControlMailbox()
        assertTrue(mailbox.publish("old-track", true, 1.0, 0L))
        assertTrue(mailbox.publish("new-track", true, 1.0, 50_000L))
        assertFalse(mailbox.clear("old-track"))
        assertEquals("new-track", mailbox.snapshot()!!.mediaId)
        assertTrue(mailbox.clear("new-track"))
        assertNull(mailbox.snapshot())
    }
    @Test
    fun sameMediaIdQueueOccurrenceTransitionRetiresPreviousScratchCommand() {
        val mailbox = DjScratchControlMailbox()
        assertTrue(mailbox.publish("same-track-id", true, -2.0, 42_000L))

        // A repeated queue occurrence can have the same mediaId. The native
        // media-transition callback must clear by occurrence boundary, not ID.
        assertTrue(mailbox.clear())
        assertNull(mailbox.snapshot())
    }

}
