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
    fun inactiveStandbyKeepsTheOnlyAudibleDeckAtUnity() {
        val activeA = Media3DjCrossfaderPolicy.gainsForState(
            position = 0.5f,
            activeDeckId = "A",
            bothDecksPlaying = false,
        )
        val activeB = Media3DjCrossfaderPolicy.gainsForState(
            position = 0.5f,
            activeDeckId = "B",
            bothDecksPlaying = false,
        )

        assertEquals(1f, activeA.first, 0.0001f)
        assertEquals(0f, activeA.second, 0.0001f)
        assertEquals(0f, activeB.first, 0.0001f)
        assertEquals(1f, activeB.second, 0.0001f)
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
    fun crossfaderCanBePrepositionedWithTwoLoadedDecksAndNoTransition() {
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
        assertTrue(!allowed(activeHasMedia = false))
        assertTrue(!allowed(standbyHasMedia = false))
        // Playback state does not gate fader positioning. applyDeckVolumes
        // keeps the sole audible deck at unity until its partner also plays.
        assertTrue(allowed())
        assertTrue(!allowed(transitionOwnsGain = true))
        assertTrue(!Media3DjCrossfaderPolicy.canApply(
            position = Float.NaN,
            djDualDeckMode = true,
            activeHasMedia = true,
            standbyHasMedia = true,
            activeIsPlaying = true,
            standbyIsPlaying = true,
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
