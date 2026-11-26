package com.Aetherion.Resonate.media

import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Media3DeckTransportPolicyTest {
    @Test
    fun permitsReadyAndEndedDecksToStart() {
        assertTrue(Media3DeckTransportPolicy.canStart(Player.STATE_READY))
        assertTrue(Media3DeckTransportPolicy.canStart(Player.STATE_ENDED))
    }

    @Test
    fun rejectsEmptyOrStillPreparingDecks() {
        assertFalse(Media3DeckTransportPolicy.canStart(Player.STATE_IDLE))
        assertFalse(Media3DeckTransportPolicy.canStart(Player.STATE_BUFFERING))
    }

    @Test
    fun onlyCompletedDecksRestartFromZero() {
        assertTrue(Media3DeckTransportPolicy.shouldRestartFromBeginning(Player.STATE_ENDED))
        assertFalse(Media3DeckTransportPolicy.shouldRestartFromBeginning(Player.STATE_READY))
        assertFalse(Media3DeckTransportPolicy.shouldRestartFromBeginning(Player.STATE_BUFFERING))
    }
}
