package com.Aetherion.Resonate.media

import androidx.media3.common.C
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchAudioTrackRouteTest {
    private fun snapshot(
        audioSessionId: Int = 7,
        routeDeviceId: Int = 3,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        pcmEncoding: Int = C.ENCODING_PCM_16BIT,
        tunneling: Boolean = false,
        offload: Boolean = false,
    ) = DjScratchAudioTrackRoute.Snapshot(
        audioSessionId = audioSessionId,
        routeDeviceId = routeDeviceId,
        sampleRate = sampleRate,
        channelCount = channelCount,
        pcmEncoding = pcmEncoding,
        tunneling = tunneling,
        offload = offload,
    )

    @Test fun exactInitializedPcmRouteIsEligible() {
        assertTrue(snapshot().isUsableForScratch())
    }

    @Test fun missingIdentityOrInvalidFormatFailsClosed() {
        assertFalse(snapshot(routeDeviceId = 0).isUsableForScratch())
        assertFalse(snapshot(audioSessionId = 0).isUsableForScratch())
        assertFalse(snapshot(sampleRate = 0).isUsableForScratch())
        assertFalse(snapshot(channelCount = 6).isUsableForScratch())
        assertFalse(snapshot(pcmEncoding = C.ENCODING_PCM_FLOAT).isUsableForScratch())
    }

    @Test fun offloadAndTunnelingAreNotScratchRoutes() {
        assertFalse(snapshot(offload = true).isUsableForScratch())
        assertFalse(snapshot(tunneling = true).isUsableForScratch())
    }
}
