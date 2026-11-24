package com.Aetherion.Resonate.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class Media3DeckPlaybackParametersPolicyTest {
    @Test
    fun replacementTrackStartsAtUnitySpeedAndPitch() {
        val parameters = Media3DeckPlaybackParametersPolicy.forNewTrack()
        assertEquals(1.0f, parameters.speed, 0.0001f)
        assertEquals(1.0f, parameters.pitch, 0.0001f)
    }

    @Test
    fun acceptsIndependentSpeedAndPitchFactors() {
        val parameters = Media3DeckPlaybackParametersPolicy.create(1.06f, 1.0f)
        requireNotNull(parameters)
        assertEquals(1.06f, parameters.speed, 0.0001f)
        assertEquals(1.0f, parameters.pitch, 0.0001f)
    }

    @Test
    fun acceptsSpeedLinkedPitchWhenKeyLockIsOff() {
        val parameters = Media3DeckPlaybackParametersPolicy.create(0.94f, 0.94f)
        requireNotNull(parameters)
        assertEquals(0.94f, parameters.speed, 0.0001f)
        assertEquals(0.94f, parameters.pitch, 0.0001f)
    }

    @Test
    fun rejectsNonFiniteAndOutOfRangeFactors() {
        assertNull(Media3DeckPlaybackParametersPolicy.create(Float.NaN, 1.0f))
        assertNull(Media3DeckPlaybackParametersPolicy.create(1.0f, Float.POSITIVE_INFINITY))
        assertNull(Media3DeckPlaybackParametersPolicy.create(0.49f, 1.0f))
        assertNull(Media3DeckPlaybackParametersPolicy.create(1.0f, 2.01f))
    }
}
