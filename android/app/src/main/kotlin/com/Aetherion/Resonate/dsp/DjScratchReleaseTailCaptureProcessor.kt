package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Captures a bounded copy of PCM after native DSP, preserving the source-media
 * timestamp supplied by the preceding timestamp processor.
 *
 * Capture is opt-in and never changes the PCM delivered to Media3.
 */
internal class DjScratchReleaseTailCaptureProcessor(
    private val timestampProvider: () -> Long? = { null },
) : BaseAudioProcessor() {
    private val activeBuffer = AtomicReference<DjScratchReleaseTailBuffer?>(null)
    private val sealedBuffer = AtomicReference<DjScratchReleaseTailBuffer?>(null)
    private val writers = AtomicInteger(0)

    @Volatile private var configuredChannels = 0
    @Volatile private var configuredSampleRate = 0

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT ||
            inputAudioFormat.channelCount !in 1..2 ||
            inputAudioFormat.sampleRate <= 0
        ) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        configuredChannels = inputAudioFormat.channelCount
        configuredSampleRate = inputAudioFormat.sampleRate
        return inputAudioFormat
    }

    /** Prepare a fresh 250 ms capture window. Call from the control thread. */
    fun beginCapture(): Boolean {
        val channels = configuredChannels
        val rate = configuredSampleRate
        if (channels !in 1..2 || rate <= 0 || activeBuffer.get() != null) return false
        val capacity = (rate * DjScratchReleaseTailBuffer.DEFAULT_TAIL_MS / 1000)
            .coerceIn(1, DjScratchReleaseTailBuffer.MAX_CAPACITY_FRAMES)
        val next = DjScratchReleaseTailBuffer(channels, capacity)
        sealedBuffer.set(null)
        return activeBuffer.compareAndSet(null, next)
    }

    /**
     * Stop capture and publish an immutable tail. This waits only on the
     * control thread for a bounded in-flight copy; the audio callback never
     * waits for the control thread and performs no allocation.
     */
    fun sealCapture(): DjScratchReleaseTailBuffer? {
        val buffer = activeBuffer.getAndSet(null) ?: return sealedBuffer.get()
        while (writers.get() != 0) Thread.yield()
        buffer.seal()
        sealedBuffer.set(buffer)
        return buffer.takeIf { it.availableFrames > 0 }
    }

    fun sealedTail(): DjScratchReleaseTailBuffer? =
        sealedBuffer.get()?.takeIf { it.isSealed && it.remainingFrames > 0 }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val capture = activeBuffer.get()
        if (capture != null) {
            writers.incrementAndGet()
            try {
                if (activeBuffer.get() === capture) {
                    capture.append(inputBuffer, timestampProvider(), configuredSampleRate)
                }
            } finally {
                writers.decrementAndGet()
            }
        }
        val output = replaceOutputBuffer(inputBuffer.remaining())
        output.put(inputBuffer)
        output.flip()
    }

    override fun onReset() {
        activeBuffer.set(null)
        sealedBuffer.set(null)
        configuredChannels = 0
        configuredSampleRate = 0
    }
}
