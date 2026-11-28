package com.aetherion.resonate.dsp

import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Lock-free control handoff from UI/control threads to one deck's audio thread.
 *
 * Publishing replaces one immutable snapshot; the audio thread reads the
 * latest complete command without locks or allocations on its own thread.
 * This is deliberately a control mailbox, not an audio renderer.
 */
internal class DjScratchControlMailbox(
    private val maximumAbsVelocity: Double = 4.0,
) {
    data class Snapshot(
        val sequence: Long,
        val generation: Long,
        val mediaId: String,
        val active: Boolean,
        val velocity: Double,
        val anchorMediaTimeUs: Long,
    )

    data class State(
        val generation: Long,
        val snapshot: Snapshot?,
    )

    private val sequence = AtomicLong(0L)
    private val state = AtomicReference(State(generation = 0L, snapshot = null))

    init {
        require(maximumAbsVelocity.isFinite() && maximumAbsVelocity >= 1.0)
    }

    /** Rejects stale/invalid identity, timestamp or velocity without changing state. */
    fun publish(
        mediaId: String,
        active: Boolean,
        velocity: Double,
        anchorMediaTimeUs: Long,
    ): Boolean {
        if (mediaId.isBlank() || !velocity.isFinite() || anchorMediaTimeUs < 0L ||
            kotlin.math.abs(velocity) > maximumAbsVelocity
        ) return false
        state.updateAndGet { current ->
            Snapshot(
                sequence = sequence.incrementAndGet(),
                generation = current.generation,
                mediaId = mediaId,
                active = active,
                velocity = if (active) velocity else 1.0,
                anchorMediaTimeUs = anchorMediaTimeUs,
            ).let { State(current.generation, it) }
        }
        return true
    }

    /**
     * Retires the current scratch timeline. The generation increment and
     * snapshot removal are one atomic state change, so a concurrent publish
     * cannot be accidentally erased or tagged with the retired generation.
     */
    fun clear(expectedMediaId: String? = null): Boolean {
        while (true) {
            val current = state.get()
            val snapshot = current.snapshot
            if (expectedMediaId != null && snapshot != null &&
                snapshot.mediaId != expectedMediaId
            ) return false
            val next = State(generation = current.generation + 1L, snapshot = null)
            if (state.compareAndSet(current, next)) return true
        }
    }

    /** Single atomic state read suitable for the audio-processing thread. */
    fun state(): State = state.get()

    /** Latest command snapshot, retained for diagnostics and control validation. */
    fun snapshot(): Snapshot? = state.get().snapshot
}
