package com.Aetherion.Resonate.media

/**
 * Validates native DJ A/B loop ranges against the current Media3 item.
 *
 * Loop points are absolute media positions. Keeping them on the native media
 * clock avoids Flutter timer drift and leaves the playlist timeline untouched.
 */
internal data class Media3DjLoopRange(
    val startMs: Long,
    val endMs: Long,
) {
    val durationMs: Long get() = endMs - startMs
}

internal object Media3DjLoopPolicy {
    const val MIN_LOOP_DURATION_MS = 120L
    const val END_GUARD_MS = 40L

    fun create(
        startMs: Long,
        endMs: Long,
        durationMs: Long?,
    ): Media3DjLoopRange? {
        if (startMs < 0L || endMs <= startMs) return null
        if (endMs - startMs < MIN_LOOP_DURATION_MS) return null
        if (durationMs == null || durationMs <= 0L) return null
        if (endMs > durationMs - END_GUARD_MS) return null
        return Media3DjLoopRange(startMs, endMs)
    }

    fun shouldWrap(
        loopActive: Boolean,
        expectedMediaId: String,
        currentMediaId: String?,
        positionMs: Long,
        endMs: Long,
    ): Boolean = loopActive &&
        expectedMediaId.isNotBlank() &&
        currentMediaId == expectedMediaId &&
        positionMs >= endMs
}
