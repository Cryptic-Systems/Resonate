package com.Aetherion.Resonate

/**
 * MediaCodec output timestamps are absolute positions on the source timeline.
 * A requested PCM window is bounded by its absolute end, not by its duration
 * measured from zero. Negative/invalid inputs fail closed.
 *
 * Earlier timestamps are accepted because SEEK_TO_CLOSEST_SYNC may begin at
 * the preceding sync sample; callers retain the actual first output timestamp.
 */
internal fun isPcmTimestampWithinWindowEnd(
    presentationTimeUs: Long,
    requestedStartMs: Long,
    maxDurationUs: Long,
): Boolean {
    if (presentationTimeUs < 0L || requestedStartMs < 0L || maxDurationUs < 0L) {
        return false
    }
    val startUs = if (requestedStartMs > Long.MAX_VALUE / 1_000L) {
        Long.MAX_VALUE
    } else {
        requestedStartMs * 1_000L
    }
    val endUs = if (maxDurationUs > Long.MAX_VALUE - startUs) {
        Long.MAX_VALUE
    } else {
        startUs + maxDurationUs
    }
    return presentationTimeUs <= endUs
}
