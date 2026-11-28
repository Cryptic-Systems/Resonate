package com.aetherion.resonate.dsp

import android.media.AudioFormat
import java.nio.ByteBuffer

/**
 * Single control-plane owner for a sealed release-tail transfer.
 *
 * Call only off the audio callback. The caller is responsible for establishing
 * the Media3 silence barrier before invoking this operation; the renderer
 * independently refuses to open without that confirmation.
 */
internal class DjScratchReleaseTransferCoordinator(
    private val ownership: DjScratchReleaseTailOwnership,
    private val renderer: Renderer,
) {
    interface Renderer {
        fun open(contract: DjScratchPcmReleaseRenderer.Contract, media3OutputSilenced: Boolean): Boolean
        fun render(tail: DjScratchReleaseTailBuffer, scratchBuffer: ByteBuffer): Boolean
        fun awaitDrain(): Boolean
        fun close()
        val framesAccepted: Long
    }

    enum class Result {
        DRAINED,
        REJECTED,
        ABORTED,
    }

    /**
     * Transfers a sealed tail exactly once, renders it on the same verified
     * route/session, waits until hardware playback has consumed it, then retires
     * ownership. Any partial failure closes output and aborts the generation.
     */
    @Synchronized
    fun transferAndDrain(
        generation: Long,
        mediaId: String,
        consumerId: String,
        output: DjScratchReleaseTailOwnership.OutputContract,
        rendererContract: DjScratchPcmReleaseRenderer.Contract,
        tail: DjScratchReleaseTailBuffer,
        scratchBuffer: ByteBuffer,
        media3OutputSilenced: Boolean,
    ): Result {
        val state = ownership.snapshot()
        if (!media3OutputSilenced ||
            state.generation != generation ||
            state.mediaId != mediaId ||
            state.phase != DjScratchReleaseTailOwnership.Phase.SEALED ||
            state.output != output ||
            !output.isValid() ||
            output.pcmEncoding != AudioFormat.ENCODING_PCM_16BIT ||
            rendererContract.sampleRate != output.sampleRate ||
            rendererContract.channelCount != output.channelCount ||
            rendererContract.audioSessionId != output.audioSessionId ||
            rendererContract.routeDeviceId != output.routeDeviceId ||
            rendererContract.routeGeneration != output.routeGeneration ||
            rendererContract.processingChainId != output.processingChainId ||
            !tail.isSealed || !tail.hasValidTimestamps ||
            tail.sampleRate != output.sampleRate ||
            tail.channelCount != output.channelCount ||
            tail.remainingFrames != state.remainingFrames ||
            !scratchBuffer.isDirect
        ) return Result.REJECTED

        if (!ownership.transfer(generation, consumerId, output) ||
            !ownership.beginDrain(generation, consumerId)
        ) return Result.REJECTED

        val startFrames = renderer.framesAccepted
        val opened = renderer.open(rendererContract, media3OutputSilenced)
        val rendered = opened && renderer.render(tail, scratchBuffer)
        val accepted = (renderer.framesAccepted - startFrames).coerceAtLeast(0L)
        val fullyDrained = rendered && accepted == state.remainingFrames.toLong() &&
            tail.remainingFrames == 0 && renderer.awaitDrain()

        if (!fullyDrained || accepted > Int.MAX_VALUE ||
            !ownership.recordDrainedFrames(generation, consumerId, accepted.toInt())
        ) {
            renderer.close()
            ownership.abort(generation + 1L)
            return Result.ABORTED
        }

        renderer.close()
        return if (ownership.snapshot().phase == DjScratchReleaseTailOwnership.Phase.DRAINED) {
            Result.DRAINED
        } else {
            ownership.abort(generation + 1L)
            Result.ABORTED
        }
    }
}
