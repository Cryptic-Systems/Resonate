package com.Aetherion.Resonate.media

import android.media.AudioManager

/**
 * Prevents Resonate from requesting media focus while Android is in a call
 * or another active communication session. This is deliberately a read-only
 * guard: it does not change the system audio mode or call state.
 */
internal object AudioCommunicationGuard {
    fun isActive(mode: Int): Boolean =
        mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION ||
            mode == AudioManager.MODE_RINGTONE
}
