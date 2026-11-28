package com.aetherion.resonate.dsp

/**
 * Pure release/catch-up protocol for a future scratch audio-thread integration.
 *
 * Media3 continues decoding while a scratch cursor substitutes PCM, so its live
 * output is not a valid release target. This protocol requires one seek to the
 * cursor's media timestamp, then waits for timestamped post-seek PCM to align
 * before allowing a release crossfade. It deliberately owns no Player or thread.
 */
internal class DjScratchReleaseHandoff(
    private val alignmentToleranceUs: Long = DEFAULT_ALIGNMENT_TOLERANCE_US,
) {
    enum class Phase {
        IDLE,
        SCRATCHING,
        RELEASE_REQUESTED,
        SEEK_ISSUED,
        WAITING_FOR_ALIGNMENT,
        CROSSFADE_READY,
        COMPLETE,
        ABORTED,
    }

    data class State(
        val generation: Long,
        val mediaId: String?,
        val phase: Phase,
        val targetPositionUs: Long?,
    )

    companion object {
        const val DEFAULT_ALIGNMENT_TOLERANCE_US = 20_000L
    }

    private var state = State(0L, null, Phase.IDLE, null)

    init {
        require(alignmentToleranceUs >= 0L)
    }

    fun snapshot(): State = state

    fun begin(generation: Long, mediaId: String): Boolean {
        if (generation < 0L || mediaId.isBlank()) return false
        if (state.phase in setOf(
                Phase.RELEASE_REQUESTED,
                Phase.SEEK_ISSUED,
                Phase.WAITING_FOR_ALIGNMENT,
                Phase.CROSSFADE_READY,
            )
        ) return false
        state = State(generation, mediaId, Phase.SCRATCHING, null)
        return true
    }

    /**
     * Freezes the cursor's media-time destination. The returned position is
     * the only seek target permitted for this release generation.
     */
    fun requestRelease(
        generation: Long,
        mediaId: String,
        cursorMediaTimeUs: Long,
    ): Long? {
        if (!matches(generation, mediaId) || state.phase != Phase.SCRATCHING ||
            cursorMediaTimeUs < 0L
        ) return null
        state = state.copy(
            phase = Phase.RELEASE_REQUESTED,
            targetPositionUs = cursorMediaTimeUs,
        )
        return cursorMediaTimeUs
    }

    /** Claims the single native seek. Repeated calls never issue another seek. */
    fun markSeekIssued(generation: Long, mediaId: String): Boolean {
        if (!matches(generation, mediaId) || state.phase != Phase.RELEASE_REQUESTED) {
            return false
        }
        state = state.copy(phase = Phase.WAITING_FOR_ALIGNMENT)
        return true
    }

    /**
     * Accepts only a post-seek PCM block whose source PTS is close to the
     * frozen cursor destination. Earlier decoder output is explicitly rejected.
     */
    fun observePostSeekPcm(
        generation: Long,
        mediaId: String,
        presentationTimeUs: Long,
    ): Boolean {
        if (!matches(generation, mediaId) ||
            state.phase != Phase.WAITING_FOR_ALIGNMENT ||
            presentationTimeUs < 0L
        ) return false
        val target = state.targetPositionUs ?: return false
        val delta = if (presentationTimeUs >= target) {
            presentationTimeUs - target
        } else {
            target - presentationTimeUs
        }
        if (delta > alignmentToleranceUs) return false
        state = state.copy(phase = Phase.CROSSFADE_READY)
        return true
    }

    /** Complete only after the audio thread has rendered the aligned fade. */
    fun complete(generation: Long, mediaId: String): Boolean {
        if (!matches(generation, mediaId) || state.phase != Phase.CROSSFADE_READY) {
            return false
        }
        state = state.copy(phase = Phase.COMPLETE)
        return true
    }

    /** Any transport/track interruption retires the whole handoff generation. */
    fun abort(nextGeneration: Long) {
        if (nextGeneration <= state.generation) return
        state = State(nextGeneration, null, Phase.ABORTED, null)
    }

    private fun matches(generation: Long, mediaId: String): Boolean =
        state.generation == generation && state.mediaId == mediaId
}
