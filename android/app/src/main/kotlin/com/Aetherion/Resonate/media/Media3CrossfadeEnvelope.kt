package com.Aetherion.Resonate.media

import kotlin.math.cos
import kotlin.math.sin

/**
 * Equal-power gains for the active and incoming Media3 decks.
 *
 * The service uses this exact envelope for every ramp tick, while JVM tests
 * verify the audible overlap independently of Android/ExoPlayer runtime.
 */
internal object Media3CrossfadeEnvelope {
    fun gains(progress: Float): Pair<Float, Float> {
        val t = if (progress.isFinite()) progress.coerceIn(0f, 1f) else 0f
        val angle = t * Math.PI.toFloat() / 2f
        return cos(angle).coerceIn(0f, 1f) to sin(angle).coerceIn(0f, 1f)
    }

    /**
     * Reverse an interrupted fade toward its outgoing deck without jumping
     * the active gain. The caller mutes/pauses the incoming deck, then samples
     * this progress over a short recovery window until it reaches zero.
     */
    fun restorationProgress(startProgress: Float, elapsedFraction: Float): Float {
        val start = if (startProgress.isFinite()) startProgress.coerceIn(0f, 1f) else 0f
        val elapsed = if (elapsedFraction.isFinite()) elapsedFraction.coerceIn(0f, 1f) else 1f
        return (start * (1f - elapsed)).coerceIn(0f, 1f)
    }

    /** A scheduled gain tick is valid only while this exact fade still owns both outputs. */
    fun shouldAdvanceRamp(
        generationMatches: Boolean,
        status: String,
        activeIsPlaying: Boolean,
        incomingIsPlaying: Boolean,
    ): Boolean =
        generationMatches &&
            status == "fading" &&
            activeIsPlaying &&
            incomingIsPlaying
}
