package com.Aetherion.Resonate.media

import kotlin.math.cos
import kotlin.math.sin

/** Physical A/B equal-power gains for the operator-owned DJ crossfader. */
internal object Media3DjCrossfaderPolicy {
    fun gains(position: Float): Pair<Float, Float> {
        val t = if (position.isFinite()) position.coerceIn(0f, 1f) else 0.5f
        val angle = t * Math.PI.toFloat() / 2f
        return cos(angle).coerceIn(0f, 1f) to sin(angle).coerceIn(0f, 1f)
    }
}
