package com.Aetherion.Resonate.media

import androidx.media3.common.Player

/** Small, deterministic transport rules shared by the Media3 deck controller. */
internal object Media3DeckTransportPolicy {
    fun canStart(playbackState: Int): Boolean =
        playbackState == Player.STATE_READY || playbackState == Player.STATE_ENDED

    fun shouldRestartFromBeginning(playbackState: Int): Boolean =
        playbackState == Player.STATE_ENDED
}
