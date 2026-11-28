package com.aetherion.resonate.dsp

/**
 * Maps requested audible platter rate to the cursor rate before Media3's
 * downstream Sonic/AudioTrack speed stage.
 *
 * The scratch processor is upstream of Media3 speed processing. Therefore the
 * cursor must advance at platterRate / downstreamSpeed so the later speed
 * stage does not multiply the requested platter rate a second time.
 */
internal object DjScratchSpeedMapping {
    fun cursorVelocity(
        platterVelocity: Double,
        downstreamPlaybackSpeed: Float,
        maximumAbsCursorVelocity: Double = 4.0,
    ): Double? {
        if (!platterVelocity.isFinite() ||
            !downstreamPlaybackSpeed.isFinite() ||
            downstreamPlaybackSpeed <= 0f ||
            !maximumAbsCursorVelocity.isFinite() ||
            maximumAbsCursorVelocity <= 0.0 ||
            kotlin.math.abs(platterVelocity) > 4.0
        ) return null

        val mapped = platterVelocity / downstreamPlaybackSpeed.toDouble()
        return mapped.takeIf { it.isFinite() && kotlin.math.abs(it) <= maximumAbsCursorVelocity }
    }
}
