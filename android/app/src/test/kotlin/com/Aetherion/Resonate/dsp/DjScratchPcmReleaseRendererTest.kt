package com.aetherion.resonate.dsp

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class DjScratchPcmReleaseRendererTest {
    private class FakeTrack(
        private val actualRouteId: Int,
        private val writes: MutableList<ByteArray>,
    ) : DjScratchPcmReleaseRenderer.Track {
        var currentVolume = -1f
        var released = false
        var played = false
        var onPlay: () -> Unit = {}
        override fun preferDevice(deviceId: Int) = deviceId == 7
        override fun play() { played = true; onPlay() }
        override fun routedDeviceId() = actualRouteId
        override fun setVolume(volume: Float) { this.currentVolume = volume }
        override fun write(buffer: ByteBuffer, sizeInBytes: Int): Int {
            val count = minOf(sizeInBytes, 4)
            val bytes = ByteArray(count)
            buffer.get(bytes)
            writes.add(bytes)
            return count
        }
        override fun stop() = Unit
        override fun release() { released = true }
    }

    private fun contract(routeGeneration: Long = 4L) =
        DjScratchPcmReleaseRenderer.Contract(
            sampleRate = 48_000,
            channelCount = 2,
            audioSessionId = 31,
            routeDeviceId = 7,
            routeGeneration = routeGeneration,
            deckVolume = 0.65f,
            processingChainId = DjScratchPcmReleaseRenderer.POST_DSP_PCM16_CHAIN_ID,
        )

    @Test fun routeMismatchNeverUnmutesOrRetainsTrack() {
        val writes = mutableListOf<ByteArray>()
        val fake = FakeTrack(actualRouteId = 8, writes = writes)
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { fake },
            routeGeneration = { 4L },
        )
        assertFalse(renderer.open(contract()))
        assertEquals(0f, fake.currentVolume)
        assertTrue(fake.released)
        assertTrue(writes.isEmpty())
        assertFalse(renderer.renderSealedTail(
            DjScratchReleaseTailBuffer(2, 32).apply { seal() },
            ByteBuffer.allocateDirect(16),
        ))
    }

    @Test fun routeGenerationChangeAfterPlayKeepsRendererMuted() {
        val writes = mutableListOf<ByteArray>()
        val fake = FakeTrack(actualRouteId = 7, writes = writes)
        var generation = 4L
        fake.onPlay = { generation = 5L }
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { fake },
            routeGeneration = { generation },
        )
        assertFalse(renderer.open(contract()))
        assertEquals(0f, fake.currentVolume)
        assertTrue(fake.released)
    }

    @Test fun matchingRouteUnmutesOnlyAfterRouteCheckAndWritesPartialChunks() {
        val writes = mutableListOf<ByteArray>()
        val fake = FakeTrack(actualRouteId = 7, writes = writes)
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { config ->
                assertEquals(31, config.audioSessionId)
                assertEquals(48_000, config.sampleRate)
                assertEquals(7, config.routeDeviceId)
                assertEquals(0f, fake.currentVolume)
                fake
            },
            routeGeneration = { 4L },
        )
        assertTrue(renderer.open(contract()))
        assertTrue(fake.played)
        assertEquals(0.65f, fake.currentVolume)

        val tail = DjScratchReleaseTailBuffer(2, 16, 48_000)
        val pcm = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        repeat(4) { pcm.putShort((it + 1).toShort()); pcm.putShort((it + 11).toShort()) }
        pcm.flip()
        tail.append(pcm, presentationTimeUs = 1_000_000L, sampleRate = 48_000)
        tail.seal()
        assertTrue(renderer.renderSealedTail(tail, ByteBuffer.allocateDirect(8)))
        assertEquals(4L, renderer.framesAcceptedByOutput)
        assertEquals(0, tail.remainingFrames)
        assertTrue(writes.isNotEmpty())
        renderer.close()
        assertTrue(fake.released)
    }
}
