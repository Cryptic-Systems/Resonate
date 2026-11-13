package com.Aetherion.Resonate.media

/**
 * Selects the one Media3 deck allowed to react to physical audio-route loss.
 *
 * During crossfade both physical players can briefly be active. Only the deck
 * currently attached to the canonical MediaSession may own this policy.
 */
internal object AudioOutputPolicy {
    fun handlesBecomingNoisy(isCanonicalActiveDeck: Boolean): Boolean =
        isCanonicalActiveDeck

    /** Only the canonical MediaSession player may request transient/permanent focus. */
    fun handlesAudioFocus(
        isCanonicalActiveDeck: Boolean,
        focusHandlingEnabled: Boolean,
    ): Boolean = isCanonicalActiveDeck && focusHandlingEnabled
}
