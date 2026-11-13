package com.Aetherion.Resonate.media

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioOutputPolicyTest {
    @Test
    fun canonicalActiveDeckHandlesHeadphoneAndRouteDisconnects() {
        assertTrue(AudioOutputPolicy.handlesBecomingNoisy(isCanonicalActiveDeck = true))
    }

    @Test
    fun standbyDeckNeverOwnsNoisyOutputHandling() {
        assertFalse(AudioOutputPolicy.handlesBecomingNoisy(isCanonicalActiveDeck = false))
    }
}
