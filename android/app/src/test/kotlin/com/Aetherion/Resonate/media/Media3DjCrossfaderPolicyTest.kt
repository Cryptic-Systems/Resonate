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
    fun crossfaderTracksPhysicalPositionWhenOnlyOneDeckIsPlaying() {
        for (position in listOf(0f, 0.25f, 0.5f, 0.75f, 1f)) {
            val expected = Media3DjCrossfaderPolicy.gains(position)
            assertEquals(expected, Media3DjCrossfaderPolicy.gainsForPosition(position))
        }
    }

    @Test
    fun bothPlayingDecksUseTheOperatorEqualPowerPosition() {
        val expected = Media3DjCrossfaderPolicy.gains(0.25f)
        assertEquals(
            expected,
            Media3DjCrossfaderPolicy.gainsForState(
                position = 0.25f,
                activeDeckId = "B",
                bothDecksPlaying = true,
            ),
        )
    }

    @Test
    fun crossfaderCanBePositionedWithEitherDeckLoadedAndNoTransition() {
        fun allowed(
            activeHasMedia: Boolean = true,
            standbyHasMedia: Boolean = true,
            transitionOwnsGain: Boolean = false,
        ) = Media3DjCrossfaderPolicy.canApply(
            position = 0.5f,
            djDualDeckMode = true,
            activeHasMedia = activeHasMedia,
            standbyHasMedia = standbyHasMedia,
            transitionOwnsGain = transitionOwnsGain,
        )

        assertTrue(allowed())
        assertTrue(!Media3DjCrossfaderPolicy.canApply(
            position = 0.5f,
            djDualDeckMode = false,
            activeHasMedia = true,
            standbyHasMedia = true,
            transitionOwnsGain = false,
        ))
        assertTrue(allowed(standbyHasMedia = false))
        assertTrue(allowed(activeHasMedia = false, standbyHasMedia = true))
        assertTrue(!allowed(activeHasMedia = false, standbyHasMedia = false))
        // A single loaded deck remains crossfader-controllable so moving to
        // the empty side correctly mutes the loaded deck.
        assertTrue(!allowed(transitionOwnsGain = true))
        assertTrue(!Media3DjCrossfaderPolicy.canApply(
            position = Float.NaN,
            djDualDeckMode = true,
            activeHasMedia = true,
            standbyHasMedia = true,
            transitionOwnsGain = false,
        ))
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
