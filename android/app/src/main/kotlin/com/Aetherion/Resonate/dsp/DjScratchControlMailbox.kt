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
        val mediaId: String,
        val active: Boolean,
        val velocity: Double,
        val anchorMediaTimeUs: Long,
    )

    private val sequence = AtomicLong(0L)
    private val latest = AtomicReference<Snapshot?>(null)

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
        latest.updateAndGet {
            Snapshot(
                sequence = sequence.incrementAndGet(),
                mediaId = mediaId,
                active = active,
                velocity = if (active) velocity else 1.0,
                anchorMediaTimeUs = anchorMediaTimeUs,
            )
        }
        return true
    }

    /** Clears only if the caller still owns the same loaded media identity. */
    fun clear(expectedMediaId: String? = null): Boolean {
        while (true) {
            val current = latest.get() ?: return true
            if (expectedMediaId != null && current.mediaId != expectedMediaId) return false
            if (latest.compareAndSet(current, null)) return true
        }
    }

    /** Single atomic read suitable for the audio-processing thread. */
    fun snapshot(): Snapshot? = latest.get()
}
