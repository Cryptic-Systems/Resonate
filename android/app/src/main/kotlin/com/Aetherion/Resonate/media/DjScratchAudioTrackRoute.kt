package com.Aetherion.Resonate.media

import android.media.AudioTrack
import android.os.Build
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import java.util.concurrent.atomic.AtomicReference

/**
 * Observes the exact platform AudioTrack created by this deck's Media3 sink.
 *
 * The provider delegates construction to Media3's own default provider; it
 * does not replace Media3's output path. Route identity is reported only after
 * the platform track is initialized and Android exposes its selected route.
 */
@androidx.media3.common.util.UnstableApi
internal class DjScratchAudioTrackRoute {
    data class Snapshot(
        val audioSessionId: Int,
        val routeDeviceId: Int,
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val tunneling: Boolean,
        val offload: Boolean,
    ) {
        fun isUsableForScratch(): Boolean =
            audioSessionId > 0 &&
                routeDeviceId > 0 &&
                sampleRate > 0 &&
                channelCount in 1..2 &&
                pcmEncoding == C.ENCODING_PCM_16BIT &&
                !tunneling &&
                !offload
    }

    private data class Entry(
        val track: AudioTrack,
        val config: AudioSink.AudioTrackConfig,
        val requestedSessionId: Int,
    )

    private val current = AtomicReference<Entry?>(null)

    val audioTrackProvider: DefaultAudioSink.AudioTrackProvider =
        object : DefaultAudioSink.AudioTrackProvider {
            private val delegate = DefaultAudioSink.AudioTrackProvider.DEFAULT

            override fun getAudioTrack(
                audioTrackConfig: AudioSink.AudioTrackConfig,
                audioAttributes: AudioAttributes,
                audioSessionId: Int,
            ): AudioTrack {
                val track = delegate.getAudioTrack(audioTrackConfig, audioAttributes, audioSessionId)
                current.set(Entry(track, audioTrackConfig, audioSessionId))
                return track
            }
        }

    /** Null means no initialized track or Android has not resolved its route yet. */
    fun snapshot(): Snapshot? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val entry = current.get() ?: return null
        val track = entry.track
        if (track.state != AudioTrack.STATE_INITIALIZED) return null
        val routeId = track.routedDevice?.id ?: return null
        val snapshot = Snapshot(
            audioSessionId = track.audioSessionId,
            routeDeviceId = routeId,
            sampleRate = track.sampleRate,
            channelCount = track.channelCount,
            pcmEncoding = entry.config.encoding,
            tunneling = entry.config.tunneling,
            offload = entry.config.offload,
        )
        return snapshot.takeIf {
            it.audioSessionId == entry.requestedSessionId && it.isUsableForScratch()
        }
    }

    /** Invalidates route identity before a sink flush/reset/reconfiguration. */
    fun clear() {
        current.set(null)
    }
}
