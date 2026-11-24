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

    /**
     * A crossfader can be pre-positioned whenever both physical decks have
     * media. gainsForState keeps the sole playing deck at unity until both
     * decks are audible, so moving the stored fader cannot attenuate one deck.
     */
    fun canApply(
        position: Float,
        djDualDeckMode: Boolean,
        activeHasMedia: Boolean,
        standbyHasMedia: Boolean,
        transitionOwnsGain: Boolean,
    ): Boolean =
        position.isFinite() &&
            position in 0f..1f &&
            djDualDeckMode &&
            activeHasMedia &&
            standbyHasMedia &&
            !transitionOwnsGain

    /**
     * When only one deck is audible, pin gain to that physical deck regardless
     * of the stored fader position. Once both decks are playing, use the
     * operator's equal-power position.
     */
    fun gainsForState(
        position: Float,
        activeDeckId: String,
        bothDecksPlaying: Boolean,
    ): Pair<Float, Float> =
        if (bothDecksPlaying) {
            gains(position)
        } else if (activeDeckId == "B") {
            gains(1f)
        } else {
            gains(0f)
        }
}
