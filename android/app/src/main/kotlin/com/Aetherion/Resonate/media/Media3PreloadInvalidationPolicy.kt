package com.Aetherion.Resonate.media

/**
 * Prevents an outgoing deck's natural end-of-item callback from retiring the
 * prepared incoming deck after a crossfade has already begun. Explicit seeks
 * and non-transition transport changes still invalidate standby immediately.
 */
internal object Media3PreloadInvalidationPolicy {
    fun preserveIncomingOnAutomaticTransition(
        crossfadeStatus: String,
        isAutomaticTransition: Boolean,
    ): Boolean = isAutomaticTransition && crossfadeStatus in setOf("starting", "fading")
}
