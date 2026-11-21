package com.Aetherion.Resonate.media

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Media3PreloadInvalidationPolicyTest {
    @Test
    fun preservesStandbyWhenOutgoingDeckNaturallyEndsDuringFade() {
        assertTrue(
            Media3PreloadInvalidationPolicy.preserveIncomingOnAutomaticTransition(
                crossfadeStatus = "fading",
                isAutomaticTransition = true,
            ),
        )
    }

    @Test
    fun preservesStandbyWhenAutomaticTransitionArrivesAsFadeStarts() {
        assertTrue(
            Media3PreloadInvalidationPolicy.preserveIncomingOnAutomaticTransition(
                crossfadeStatus = "starting",
                isAutomaticTransition = true,
            ),
        )
    }

    @Test
    fun doesNotPreserveStandbyForExplicitSeekDuringFade() {
        assertFalse(
            Media3PreloadInvalidationPolicy.preserveIncomingOnAutomaticTransition(
                crossfadeStatus = "fading",
                isAutomaticTransition = false,
            ),
        )
    }

    @Test
    fun doesNotPreserveStandbyOutsideAnActiveFade() {
        assertFalse(
            Media3PreloadInvalidationPolicy.preserveIncomingOnAutomaticTransition(
                crossfadeStatus = "ready",
                isAutomaticTransition = true,
            ),
        )
        assertFalse(
            Media3PreloadInvalidationPolicy.preserveIncomingOnAutomaticTransition(
                crossfadeStatus = "idle",
                isAutomaticTransition = true,
            ),
        )
    }
}
