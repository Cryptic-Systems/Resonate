package com.aetherion.resonate.dsp

/**
 * Control-plane ownership contract for handing a sealed scratch PCM tail to
 * an independent release renderer.
 *
 * This coordinator must be called from a non-realtime control thread. The PCM
 * buffer itself remains single-owner: capture owns it until seal, then the
 * designated consumer owns draining. No AudioTrack, Media3 player, DSP stage,
 * or route is created here.
 */
internal class DjScratchReleaseTailOwnership {
    enum class Phase {
        IDLE,
        CAPTURING,
        SEALED,
        TRANSFERRED,
        DRAINING,
        DRAINED,
        ABORTED,
    }

    /**
     * Exact output contract required for a consumer to avoid silently moving
     * the tail onto a different route or processing chain.
     */
    data class OutputContract(
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val audioSessionId: Int,
        val routeDeviceId: Int,
        val routeGeneration: Long,
        val processingChainId: String,
    ) {
        fun isValid(): Boolean =
            sampleRate > 0 &&
                channelCount in 1..2 &&
                audioSessionId > 0 &&
                routeDeviceId > 0 &&
                routeGeneration >= 0L &&
                processingChainId.isNotBlank()
    }

    data class State(
        val generation: Long,
        val mediaId: String?,
        val output: OutputContract?,
        val consumerId: String?,
        val phase: Phase,
        val totalFrames: Int,
        val remainingFrames: Int,
    )

    private var state = State(
        generation = 0L,
        mediaId = null,
        output = null,
        consumerId = null,
        phase = Phase.IDLE,
        totalFrames = 0,
        remainingFrames = 0,
    )

    /** Snapshot is intended for control-plane diagnostics, not the audio callback. */
    @Synchronized
    fun snapshot(): State = state

    /** Begin capture only for a fresh generation and a fully specified output path. */
    @Synchronized
    fun beginCapture(
        generation: Long,
        mediaId: String,
        output: OutputContract,
    ): Boolean {
        if (generation <= state.generation || mediaId.isBlank() || !output.isValid()) {
            return false
        }
        if (state.phase !in setOf(Phase.IDLE, Phase.DRAINED, Phase.ABORTED)) {
            return false
        }
        state = State(
            generation = generation,
            mediaId = mediaId,
            output = output,
            consumerId = null,
            phase = Phase.CAPTURING,
            totalFrames = 0,
            remainingFrames = 0,
        )
        return true
    }

    /** Freeze capture after the audio-thread owner has sealed the PCM buffer. */
    @Synchronized
    fun seal(generation: Long, retainedFrames: Int): Boolean {
        if (!matches(generation) || state.phase != Phase.CAPTURING ||
            retainedFrames <= 0
        ) return false
        state = state.copy(
            phase = Phase.SEALED,
            totalFrames = retainedFrames,
            remainingFrames = retainedFrames,
        )
        return true
    }

    /**
     * Transfer ownership once, and only to a consumer with the identical
     * sample format, AudioSession, exact routed device, route generation and processing chain.
     */
    @Synchronized
    fun transfer(
        generation: Long,
        consumerId: String,
        output: OutputContract,
    ): Boolean {
        if (!matches(generation) || state.phase != Phase.SEALED ||
            consumerId.isBlank() || output != state.output
        ) return false
        state = state.copy(
            consumerId = consumerId,
            phase = Phase.TRANSFERRED,
        )
        return true
    }

    /** Consumer must explicitly claim the transferred tail before draining. */
    @Synchronized
    fun beginDrain(generation: Long, consumerId: String): Boolean {
        if (!matches(generation) || state.phase != Phase.TRANSFERRED ||
            consumerId != state.consumerId
        ) return false
        state = state.copy(phase = Phase.DRAINING)
        return true
    }

    /** Account for frames actually accepted by the consumer's output path. */
    @Synchronized
    fun recordDrainedFrames(
        generation: Long,
        consumerId: String,
        frames: Int,
    ): Boolean {
        if (!matches(generation) || state.phase != Phase.DRAINING ||
            consumerId != state.consumerId || frames <= 0 ||
            frames > state.remainingFrames
        ) return false
        val remaining = state.remainingFrames - frames
        state = state.copy(
            remainingFrames = remaining,
            phase = if (remaining == 0) Phase.DRAINED else Phase.DRAINING,
        )
        return true
    }

    /** Retire a tail after route, transport, media or output ownership changes. */
    @Synchronized
    fun abort(nextGeneration: Long): Boolean {
        if (nextGeneration <= state.generation ||
            state.phase in setOf(Phase.IDLE, Phase.DRAINED, Phase.ABORTED)
        ) return false
        state = State(
            generation = nextGeneration,
            mediaId = null,
            output = null,
            consumerId = null,
            phase = Phase.ABORTED,
            totalFrames = 0,
            remainingFrames = 0,
        )
        return true
    }

    private fun matches(generation: Long): Boolean =
        state.generation == generation
}
