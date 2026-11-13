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
}
