package com.aetherion.resonate.dsp

import android.media.AudioAttributes as PlatformAudioAttributes
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import androidx.media3.common.C
import java.nio.ByteBuffer

/**
 * Independent, one-shot PCM release renderer.
 *
 * It is intentionally not connected to the production scratch path until
 * Media3 can provide the actual selected routed-device ID. The renderer is
 * fail-closed: it starts muted, verifies the actual route and route generation,
 * and only then permits PCM writes and restores the deck's effective volume.
 */
internal class DjScratchPcmReleaseRenderer(
    private val trackFactory: TrackFactory,
    private val routeGeneration: () -> Long,
) {
    internal interface Track {
        fun preferDevice(deviceId: Int): Boolean
        fun play()
        fun routedDeviceId(): Int?
        fun setVolume(volume: Float)
        fun write(buffer: ByteBuffer, sizeInBytes: Int): Int
        fun stop()
        fun release()
    }

    internal fun interface TrackFactory {
        fun create(config: TrackConfig): Track?
    }

    internal data class TrackConfig(
        val sampleRate: Int,
        val channelCount: Int,
        val audioSessionId: Int,
        val routeDeviceId: Int,
        val usage: Int,
        val contentType: Int,
        val bufferSizeBytes: Int,
    )

    data class Contract(
        val sampleRate: Int,
        val channelCount: Int,
        val audioSessionId: Int,
        val routeDeviceId: Int,
        val routeGeneration: Long,
        val deckVolume: Float,
        val processingChainId: String,
    ) {
        fun isValid(): Boolean =
            sampleRate > 0 &&
                channelCount in 1..2 &&
                audioSessionId > 0 &&
                routeDeviceId > 0 &&
                routeGeneration >= 0L &&
                deckVolume.isFinite() && deckVolume in 0f..1f &&
                processingChainId == POST_DSP_PCM16_CHAIN_ID
    }

    private var track: Track? = null
    private var acceptedFrames = 0L
    private var openedContract: Contract? = null

    val framesAcceptedByOutput: Long
        get() = acceptedFrames

    /**
     * Opens the renderer silently and only unmutes after actual route identity
     * and generation match. No PCM can be written before this succeeds.
     */
    fun open(contract: Contract): Boolean {
        if (track != null || !contract.isValid() ||
            routeGeneration() != contract.routeGeneration
        ) return false

        val bytesPerFrame = contract.channelCount * Short.SIZE_BYTES
        val candidate = trackFactory.create(
            TrackConfig(
                sampleRate = contract.sampleRate,
                channelCount = contract.channelCount,
                audioSessionId = contract.audioSessionId,
                routeDeviceId = contract.routeDeviceId,
                usage = PlatformAudioAttributes.USAGE_MEDIA,
                contentType = PlatformAudioAttributes.CONTENT_TYPE_MUSIC,
                bufferSizeBytes = maxOf(contract.sampleRate / 10 * bytesPerFrame, bytesPerFrame * 256),
            ),
        ) ?: return false

        return try {
            candidate.setVolume(0f)
            if (!candidate.preferDevice(contract.routeDeviceId)) {
                candidate.release()
                false
            } else {
                candidate.play()
                val routeMatches = candidate.routedDeviceId() == contract.routeDeviceId
                val generationMatches = routeGeneration() == contract.routeGeneration
                if (!routeMatches || !generationMatches) {
                    runCatching { candidate.stop() }
                    candidate.release()
                    false
                } else {
                    candidate.setVolume(contract.deckVolume)
                    track = candidate
                    openedContract = contract
                    true
                }
            }
        } catch (_: Throwable) {
            runCatching { candidate.stop() }
            runCatching { candidate.release() }
            false
        }
    }

    /**
     * Drains a sealed tail through a caller-owned direct buffer. Partial writes
     * are completed before another tail chunk is consumed. A write failure
     * aborts the renderer; callers must abort the ownership generation too.
     */
    fun renderSealedTail(
        tail: DjScratchReleaseTailBuffer,
        scratchBuffer: ByteBuffer,
    ): Boolean {
        val output = track ?: return false
        val contract = openedContract ?: return false
        if (!tail.isSealed || !tail.hasValidTimestamps ||
            tail.channelCount != contract.channelCount ||
            tail.sampleRate != contract.sampleRate ||
            !scratchBuffer.isDirect || !scratchBuffer.hasRemaining()
        ) return false
        val bytesPerFrame = tail.channelCount * Short.SIZE_BYTES
        if (scratchBuffer.remaining() < bytesPerFrame ||
            scratchBuffer.remaining() % bytesPerFrame != 0
        ) return false

        while (tail.remainingFrames > 0) {
            if (!routeStillMatches(output, contract)) {
                close()
                return false
            }
            scratchBuffer.clear()
            val copiedFrames = tail.drainTo(scratchBuffer)
            if (copiedFrames <= 0) break
            scratchBuffer.flip()
            val chunkBytes = scratchBuffer.remaining()
            var writtenBytes = 0
            while (scratchBuffer.hasRemaining()) {
                if (!routeStillMatches(output, contract)) {
                    close()
                    return false
                }
                val written = try {
                    output.write(scratchBuffer, scratchBuffer.remaining())
                } catch (_: Throwable) {
                    -1
                }
                if (written <= 0 || written % bytesPerFrame != 0) {
                    close()
                    return false
                }
                writtenBytes += written
            }
            if (writtenBytes != chunkBytes || !routeStillMatches(output, contract)) {
                close()
                return false
            }
            acceptedFrames += copiedFrames
        }
        return true
    }

    fun close() {
        val current = track ?: return
        track = null
        openedContract = null
        runCatching { current.setVolume(0f) }
        runCatching { current.stop() }
        runCatching { current.release() }
    }

    internal class AndroidTrackFactory(context: Context) : TrackFactory {
        private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        override fun create(config: TrackConfig): Track? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
            val attributes = PlatformAudioAttributes.Builder()
                .setUsage(config.usage)
                .setContentType(config.contentType)
                .build()
            val format = AudioFormat.Builder()
                .setSampleRate(config.sampleRate)
                .setChannelMask(
                    if (config.channelCount == 1) AudioFormat.CHANNEL_OUT_MONO
                    else AudioFormat.CHANNEL_OUT_STEREO,
                )
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build()
            val audioTrack = AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setBufferSizeInBytes(config.bufferSizeBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setSessionId(config.audioSessionId)
                .build()
            if (audioTrack.state != AudioTrack.STATE_INITIALIZED) {
                audioTrack.release()
                return null
            }
            return AndroidTrack(audioTrack, audioManager)
        }
    }

    private class AndroidTrack(
        private val delegate: AudioTrack,
        private val audioManager: AudioManager,
    ) : Track {
        override fun preferDevice(deviceId: Int): Boolean {
            val device: AudioDeviceInfo = audioManager
                .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.id == deviceId } ?: return false
            return delegate.setPreferredDevice(device)
        }

        override fun play() = delegate.play()

        override fun routedDeviceId(): Int? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) delegate.routedDevice?.id else null

        override fun setVolume(volume: Float) {
            delegate.setVolume(volume)
        }

        override fun write(buffer: ByteBuffer, sizeInBytes: Int): Int =
            delegate.write(buffer, sizeInBytes, AudioTrack.WRITE_BLOCKING)

        override fun stop() = delegate.stop()

        override fun release() = delegate.release()
    }

    companion object {
        const val POST_DSP_PCM16_CHAIN_ID = "resonate-post-dsp-pcm16-v1"
    }
}
