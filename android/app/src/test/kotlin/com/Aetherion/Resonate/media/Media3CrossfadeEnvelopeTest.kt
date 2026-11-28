package com.Aetherion.Resonate.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Media3CrossfadeEnvelopeTest {
    @Test
    fun endpointsMoveAllGainFromOutgoingToIncomingDeck() {
        val start = Media3CrossfadeEnvelope.gains(0f)
        val end = Media3CrossfadeEnvelope.gains(1f)

        assertEquals(1f, start.first, 0.0001f)
        assertEquals(0f, start.second, 0.0001f)
        assertEquals(0f, end.first, 0.0001f)
        assertEquals(1f, end.second, 0.0001f)
    }

    @Test
    fun midpointHasEqualAudiblePowerOnBothDecks() {
        val (active, standby) = Media3CrossfadeEnvelope.gains(0.5f)

        assertEquals(active, standby, 0.0001f)
        assertEquals(1f, active * active + standby * standby, 0.0001f)
        assertTrue(active > 0.7f && active < 0.72f)
    }

    @Test
    fun cancellationRestoresOutgoingGainContinuouslyAndMutesIncomingDeck() {
        val startProgress = 0.5f
        val startGains = Media3CrossfadeEnvelope.gains(startProgress)
        val middleProgress = Media3CrossfadeEnvelope.restorationProgress(
            startProgress = startProgress,
            elapsedFraction = 0.5f,
        )
        val middleGains = Media3CrossfadeEnvelope.gains(middleProgress)
        val endProgress = Media3CrossfadeEnvelope.restorationProgress(
            startProgress = startProgress,
            elapsedFraction = 1f,
        )
        val endGains = Media3CrossfadeEnvelope.gains(endProgress)

        val initialRestoreProgress = Media3CrossfadeEnvelope.restorationProgress(
            startProgress = startProgress,
            elapsedFraction = 0f,
        )
        assertEquals(startProgress, initialRestoreProgress, 0f)
        assertEquals(startGains.first, Media3CrossfadeEnvelope.gains(initialRestoreProgress).first, 0f)
        assertTrue(middleGains.first > startGains.first)
        assertTrue(endGains.first > middleGains.first)
        assertEquals(1f, endGains.first, 0.0001f)
        assertEquals(0f, endProgress, 0f)
    }

    @Test
    fun staleOrInterruptedRampCannotAdvance() {
        assertTrue(
            Media3CrossfadeEnvelope.shouldAdvanceRamp(
                generationMatches = true,
                status = "fading",
            ),
        )
        assertFalse(
            Media3CrossfadeEnvelope.shouldAdvanceRamp(
                generationMatches = false,
                status = "fading",
            ),
        )
        assertFalse(
            Media3CrossfadeEnvelope.shouldAdvanceRamp(
                generationMatches = true,
                status = "cancelled",
            ),
        )
    }

    @Test
    fun cancellationGainRestoreRejectsStaleGenerationAndDeckIdentity() {
        assertTrue(
            Media3CrossfadeEnvelope.shouldRestoreCancelledGain(
                generationMatches = true,
                canonicalDeckMatches = true,
            ),
        )
        assertFalse(
            Media3CrossfadeEnvelope.shouldRestoreCancelledGain(
                generationMatches = false,
                canonicalDeckMatches = true,
            ),
        )
        assertFalse(
            Media3CrossfadeEnvelope.shouldRestoreCancelledGain(
                generationMatches = true,
                canonicalDeckMatches = false,
            ),
        )
    }

    @Test
    fun progressIsClampedAndNonFiniteValuesAreSafe() {
        assertEquals(
            Media3CrossfadeEnvelope.gains(0f),
            Media3CrossfadeEnvelope.gains(Float.NaN),
        )
        assertEquals(
            Media3CrossfadeEnvelope.gains(1f),
            Media3CrossfadeEnvelope.gains(2f),
        )
        assertEquals(
            Media3CrossfadeEnvelope.gains(0f),
            Media3CrossfadeEnvelope.gains(-1f),
        )
    }
}
