package com.aetherion.resonate.dsp

import java.util.concurrent.atomic.AtomicLong

/**
 * Monotonic generation for Android output-device topology.
 *
 * Any add/remove notification invalidates an in-flight release-tail contract.
 * It deliberately does not guess the selected device; a consumer must still
 * verify the AudioTrack route before accepting PCM.
 */
internal class DjScratchOutputRouteGeneration(initialGeneration: Long = 0L) {
    private val generation = AtomicLong(initialGeneration.also { require(it >= 0L) })

    fun snapshot(): Long = generation.get()

    fun onOutputDevicesChanged(): Long = generation.incrementAndGet()
}
