package com.aetherion.resonate.dsp

import android.media.AudioFormat
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DjScratchReleaseTransferCoordinatorTest {
    private class FakeRenderer : DjScratchReleaseTransferCoordinator.Renderer {
        override var framesAccepted: Long = 0
            private set
        var openAllowed = true
        var drainAllowed = true
        var opened = false
        var closed = false

        override fun open(
            contract: DjScratchPcmReleaseRenderer.Contract,
            media3OutputSilenced: Boolean,
        ): Boolean {
            opened = media3OutputSilenced && openAllowed
            return opened
        }

        override fun render(tail: DjScratchReleaseTailBuffer, scratchBuffer: ByteBuffer): Boolean {
            if (!opened) return false
            while (tail.remainingFrames > 0) {
                scratchBuffer.clear()
                val frames = tail.drainTo(scratchBuffer)
                if (frames <= 0) return false
                framesAccepted += frames
            }
            return true
        }

        override fun awaitDrain(): Boolean = drainAllowed
        override fun close() { closed = true }
    }

    private data class Fixture(
        val ownership: DjScratchReleaseTailOwnership,
        val renderer: FakeRenderer,
        val coordinator: DjScratchReleaseTransferCoordinator,
        val output: DjScratchReleaseTailOwnership.OutputContract,
        val rendererContract: DjScratchPcmReleaseRenderer.Contract,
        val tail: DjScratchReleaseTailBuffer,
    )

    private fun fixture(): Fixture {
        val ownership = DjScratchReleaseTailOwnership()
        val output = DjScratchReleaseTailOwnership.OutputContract(
            sampleRate = 48_000,
            channelCount = 2,
            pcmEncoding = AudioFormat.ENCODING_PCM_16BIT,
            audioSessionId = 31,
            routeDeviceId = 9,
            routeGeneration = 4,
            processingChainId = DjScratchPcmReleaseRenderer.POST_DSP_PCM16_CHAIN_ID,
        )
        val rendererContract = DjScratchPcmReleaseRenderer.Contract(
            sampleRate = output.sampleRate,
            channelCount = output.channelCount,
            audioSessionId = output.audioSessionId,
            routeDeviceId = output.routeDeviceId,
            routeGeneration = output.routeGeneration,
            deckVolume = 0.8f,
            processingChainId = output.processingChainId,
        )
        val tail = DjScratchReleaseTailBuffer(2, 64, 48_000)
        val pcm = ByteBuffer.allocateDirect(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        repeat(4) { pcm.putShort(it.toShort()) }
        pcm.flip()
        assertEquals(2, tail.append(pcm, 1_000_000L, 48_000))
        tail.seal()
        assertTrue(ownership.beginCapture(1L, "media-1", output))
        assertTrue(ownership.seal(1L, 2))
        val renderer = FakeRenderer()
        return Fixture(
            ownership, renderer,
            DjScratchReleaseTransferCoordinator(ownership, renderer),
            output, rendererContract, tail,
        )
    }

    @Test
    fun transfersOnceAndWaitsForHardwareDrain() {
        val f = fixture()
        assertEquals(
            DjScratchReleaseTransferCoordinator.Result.DRAINED,
            f.coordinator.transferAndDrain(
                1L, "media-1", "release-renderer", f.output, f.rendererContract,
                f.tail, ByteBuffer.allocateDirect(32), media3OutputSilenced = true,
            ),
        )
        assertEquals(DjScratchReleaseTailOwnership.Phase.DRAINED, f.ownership.snapshot().phase)
        assertEquals(2L, f.renderer.framesAccepted)
        assertTrue(f.renderer.closed)
        assertEquals(
            DjScratchReleaseTransferCoordinator.Result.REJECTED,
            f.coordinator.transferAndDrain(
                1L, "media-1", "release-renderer", f.output, f.rendererContract,
                f.tail, ByteBuffer.allocateDirect(32), media3OutputSilenced = true,
            ),
        )
    }

    @Test
    fun refusesBeforeOpeningWhenMedia3IsNotSilenced() {
        val f = fixture()
        assertEquals(
            DjScratchReleaseTransferCoordinator.Result.REJECTED,
            f.coordinator.transferAndDrain(
                1L, "media-1", "release-renderer", f.output, f.rendererContract,
                f.tail, ByteBuffer.allocateDirect(32), media3OutputSilenced = false,
            ),
        )
        assertFalse(f.renderer.opened)
        assertEquals(DjScratchReleaseTailOwnership.Phase.SEALED, f.ownership.snapshot().phase)
    }

    @Test
    fun abortsOwnershipWhenHardwareDrainFails() {
        val f = fixture()
        f.renderer.drainAllowed = false
        assertEquals(
            DjScratchReleaseTransferCoordinator.Result.ABORTED,
            f.coordinator.transferAndDrain(
                1L, "media-1", "release-renderer", f.output, f.rendererContract,
                f.tail, ByteBuffer.allocateDirect(32), media3OutputSilenced = true,
            ),
        )
        assertEquals(DjScratchReleaseTailOwnership.Phase.ABORTED, f.ownership.snapshot().phase)
        assertTrue(f.renderer.closed)
    }

    @Test
    fun rejectsRouteOrFormatMismatchWithoutTransferring() {
        val f = fixture()
        val wrongRoute = f.output.copy(routeDeviceId = 10)
        assertEquals(
            DjScratchReleaseTransferCoordinator.Result.REJECTED,
            f.coordinator.transferAndDrain(
                1L, "media-1", "release-renderer", wrongRoute, f.rendererContract,
                f.tail, ByteBuffer.allocateDirect(32), media3OutputSilenced = true,
            ),
        )
        assertEquals(DjScratchReleaseTailOwnership.Phase.SEALED, f.ownership.snapshot().phase)
        assertFalse(f.renderer.opened)
    }
}
