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
        val volumeHistory = mutableListOf<Float>()
        var released = false
        var played = false
        var onPlay: () -> Unit = {}
        var framesWritten = 0L
        override fun preferDevice(deviceId: Int) = deviceId == 7
        override fun play() { played = true; onPlay() }
        override fun routedDeviceId() = actualRouteId
        override fun setVolume(volume: Float) { this.currentVolume = volume; volumeHistory.add(volume) }
        override fun write(buffer: ByteBuffer, sizeInBytes: Int): Int {
            val count = minOf(sizeInBytes, 4)
            val bytes = ByteArray(count)
            buffer.get(bytes)
            writes.add(bytes)
            framesWritten += count / 4
            return count
        }
        override fun playbackHeadPositionFrames() = framesWritten
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

    @Test fun rendererCannotOpenWhileMedia3OutputMayStillBeAudible() {
        val writes = mutableListOf<ByteArray>()
        var factoryCalls = 0
        val fake = FakeTrack(actualRouteId = 7, writes = writes)
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { factoryCalls++; fake },
            routeGeneration = { 4L },
        )
        assertFalse(renderer.open(contract(), media3OutputSilenced = false))
        assertEquals(0, factoryCalls)
        assertEquals(-1f, fake.currentVolume)
        assertFalse(fake.played)
        assertTrue(writes.isEmpty())
    }

    @Test fun routeMismatchNeverUnmutesOrRetainsTrack() {
        val writes = mutableListOf<ByteArray>()
        val fake = FakeTrack(actualRouteId = 8, writes = writes)
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { fake },
            routeGeneration = { 4L },
        )
        assertFalse(renderer.open(contract(), media3OutputSilenced = true))
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
        assertFalse(renderer.open(contract(), media3OutputSilenced = true))
        assertEquals(0f, fake.currentVolume)
        assertTrue(fake.released)
    }

    @Test fun rendererWaitsForAllAcceptedFramesToPassPlaybackHead() {
        val writes = mutableListOf<ByteArray>()
        val fake = FakeTrack(actualRouteId = 7, writes = writes)
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { fake },
            routeGeneration = { 4L },
        )
        assertTrue(renderer.open(contract(), media3OutputSilenced = true))
        val tail = DjScratchReleaseTailBuffer(2, 8, 48_000)
        val pcm = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        repeat(4) { pcm.putShort((it + 1).toShort()); pcm.putShort((it + 11).toShort()) }
        pcm.flip()
        tail.append(pcm, presentationTimeUs = 1_000_000L, sampleRate = 48_000)
        tail.seal()
        assertTrue(renderer.renderSealedTail(tail, ByteBuffer.allocateDirect(16)))
        assertEquals(4L, renderer.framesAcceptedByOutput)
        assertTrue(renderer.awaitPlaybackDrain(timeoutMs = 100L))
        renderer.close()
        assertTrue(fake.released)
        assertEquals(0L, renderer.framesAcceptedByOutput)
    }

    @Test fun matchingRouteUnmutesOnlyAfterRouteCheckAndWritesPartialChunks() {
        val writes = mutableListOf<ByteArray>()
        val fake = FakeTrack(actualRouteId = 7, writes = writes)
        val renderer = DjScratchPcmReleaseRenderer(
            trackFactory = { config ->
                assertEquals(31, config.audioSessionId)
                assertEquals(48_000, config.sampleRate)
                assertEquals(7, config.routeDeviceId)
                fake
            },
            routeGeneration = { 4L },
        )
        assertTrue(renderer.open(contract(), media3OutputSilenced = true))
        assertTrue(fake.played)
        assertEquals(0.65f, fake.currentVolume)
        assertEquals(listOf(0f, 0.65f), fake.volumeHistory)

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
