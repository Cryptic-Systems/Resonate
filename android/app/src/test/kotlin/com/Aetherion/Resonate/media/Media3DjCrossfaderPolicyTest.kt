package com.Aetherion.Resonate.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Media3DjCrossfaderPolicyTest {
    @Test
    fun endpointsIsolateTheOppositeDeck() {
        val left = Media3DjCrossfaderPolicy.gains(0f)
        val right = Media3DjCrossfaderPolicy.gains(1f)

        assertEquals(1f, left.first, 0.0001f)
        assertEquals(0f, left.second, 0.0001f)
        assertEquals(0f, right.first, 0.0001f)
        assertEquals(1f, right.second, 0.0001f)
    }

    @Test
    fun centerHasEqualPowerOnBothDecks() {
        val (deckA, deckB) = Media3DjCrossfaderPolicy.gains(0.5f)

        assertEquals(deckA, deckB, 0.0001f)
        assertEquals(1f, deckA * deckA + deckB * deckB, 0.0001f)
        assertTrue(deckA > 0.7f && deckA < 0.72f)
    }

    @Test
    fun invalidAndOutOfRangePositionsAreBounded() {
        assertEquals(
            Media3DjCrossfaderPolicy.gains(0.5f),
            Media3DjCrossfaderPolicy.gains(Float.NaN),
        )
        assertEquals(
            Media3DjCrossfaderPolicy.gains(1f),
            Media3DjCrossfaderPolicy.gains(2f),
        )
        assertEquals(
            Media3DjCrossfaderPolicy.gains(0f),
            Media3DjCrossfaderPolicy.gains(-1f),
        )
    }
}
