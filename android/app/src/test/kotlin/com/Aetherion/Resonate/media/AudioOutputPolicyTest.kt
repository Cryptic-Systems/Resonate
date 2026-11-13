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

    @Test
    fun onlyCanonicalActiveDeckMayOwnAudioFocus() {
        assertTrue(
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = true,
                focusHandlingEnabled = true,
            ),
        )
        assertFalse(
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = false,
                focusHandlingEnabled = true,
            ),
        )
    }

    @Test
    fun focusRequestsRemainDisabledUntilProviderEnablesThem() {
        assertFalse(
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = true,
                focusHandlingEnabled = false,
            ),
        )
        assertFalse(
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = false,
                focusHandlingEnabled = false,
            ),
        )
    }
}
