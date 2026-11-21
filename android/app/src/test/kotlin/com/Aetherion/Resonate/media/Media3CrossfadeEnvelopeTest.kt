package com.Aetherion.Resonate.media

import org.junit.Assert.assertEquals
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
