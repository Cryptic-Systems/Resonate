package com.Aetherion.Resonate.media

import android.media.AudioManager
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCommunicationGuardTest {
    @Test
    fun normalAudioModeAllowsMediaPlayback() {
        assertFalse(AudioCommunicationGuard.isActive(AudioManager.MODE_NORMAL))
    }

    @Test
    fun telephonyAndVoipModesBlockMediaPlayback() {
        assertTrue(AudioCommunicationGuard.isActive(AudioManager.MODE_IN_CALL))
        assertTrue(AudioCommunicationGuard.isActive(AudioManager.MODE_IN_COMMUNICATION))
        assertTrue(AudioCommunicationGuard.isActive(AudioManager.MODE_RINGTONE))
    }
}
