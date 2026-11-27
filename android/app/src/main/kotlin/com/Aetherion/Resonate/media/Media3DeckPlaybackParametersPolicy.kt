package com.Aetherion.Resonate.media

import androidx.media3.common.PlaybackParameters

/** Validates complete per-deck Media3 playback parameters. */
internal object Media3DeckPlaybackParametersPolicy {
    const val MIN_FACTOR = 0.5f
    const val MAX_FACTOR = 2.0f

    /** New media must never inherit a previous track's DJ tempo or pitch. */
    fun forNewTrack(): PlaybackParameters = PlaybackParameters(1.0f, 1.0f)

    fun create(speed: Float, pitch: Float): PlaybackParameters? {
        if (!speed.isFinite() || speed !in MIN_FACTOR..MAX_FACTOR) return null
        if (!pitch.isFinite() || pitch !in MIN_FACTOR..MAX_FACTOR) return null
        return PlaybackParameters(speed, pitch)
    }
}
