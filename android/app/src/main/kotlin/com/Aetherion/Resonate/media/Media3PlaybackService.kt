package com.Aetherion.Resonate.media

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.aetherion.resonate.dsp.DspEngineSinkHook
import com.aetherion.resonate.dsp.DspEngineRegistry
import com.Aetherion.Resonate.R
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Media3 playback service with active/standby decks. The provider owns the
 * production handoff while this service owns native transport, MediaSession,
 * DSP and equal-power crossfade execution.
 */
@OptIn(UnstableApi::class)
class Media3PlaybackService : MediaSessionService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaSession: MediaSession? = null
    private lateinit var activePlayer: ExoPlayer
    private var standbyPlayer: ExoPlayer? = null
    // Short DJ samples are mixed by a service-owned player. It has no MediaSession
    // and never requests focus, so the canonical queue remains the sole transport owner.
    private var auxiliaryPlayer: ExoPlayer? = null
    private var auxiliaryBaseVolume = 0f
    // Isolated music audition decks with independent native DSP processors.
    private var previewOutgoingPlayer: ExoPlayer? = null
    private var previewIncomingPlayer: ExoPlayer? = null
    private var previewOutgoingListener: Player.Listener? = null
    private var previewIncomingListener: Player.Listener? = null
    private var previewRampRunnable: Runnable? = null
    private var previewPrepareTimeout: Runnable? = null
    private var previewStartRequested = false
    private var previewGeneration = 0
    private var fadeRunnable: Runnable? = null
    private var fadeGeneration = 0
    private val crossfadeClock = Media3CrossfadeClock()
    private var crossfadeStatus = "idle"
    private var pendingCrossfadeDurationMs: Long? = null
    // The ramp is deliberately not started until the incoming deck reports
    // isPlaying. ExoPlayer's play() request can precede audible output startup.
    private var startingCrossfadeDurationMs: Long? = null
    private var activeDeckId = "A"
    private var djDualDeckMode = false
    private var djCrossfaderPosition = 0.5f
    private var suppressDjPeerPauseDeckId: String? = null
    private fun standbyDeckId(): String = if (activeDeckId == "A") "B" else "A"
    // ExoPlayer focus handling is opt-in at the migration boundary. The legacy
    // audio_session owner remains untouched until an explicit provider cutover.
    // Focus is acquired only after an explicit play request. Creating or
    // connecting the service must never interrupt another app.
    private var media3AudioFocusEnabled = false

    // All Media3 output gain changes pass through one policy. Future leveling,
    // preamp, sleep fade and focus-duck factors belong in this composition point.
    private val gainPolicy = Media3GainPolicy()

    // Native audio underrun telemetry is counter-only: no PCM/audio content is
    // captured. Counts are cumulative for the lifetime of this service.
    private val audioDiagnosticsLock = Any()
    private val audioUnderrunCounts = mutableMapOf("A" to 0, "B" to 0)
    @Volatile private var lastUnderrunDeck: String? = null
    @Volatile private var lastUnderrunBufferSizeFrames: Int = 0
    @Volatile private var lastUnderrunBufferSizeMs: Long = 0L
    @Volatile private var lastUnderrunElapsedSinceFeedMs: Long = 0L
    @Volatile private var lastUnderrunElapsedRealtimeMs: Long = 0L
    @Volatile private var lastMediaTransitionDeckId: String? = null
    @Volatile private var lastMediaTransitionMediaId: String? = null
    @Volatile private var lastMediaTransitionReason: Int = -1
    @Volatile private var lastMediaTransitionElapsedRealtimeMs: Long = 0L

    fun audioDiagnosticsState(): Map<String, Any?> = synchronized(audioDiagnosticsLock) {
        mapOf(
            "underrunCountA" to (audioUnderrunCounts["A"] ?: 0),
            "underrunCountB" to (audioUnderrunCounts["B"] ?: 0),
            "lastUnderrunDeck" to lastUnderrunDeck,
            "lastUnderrunBufferSizeFrames" to lastUnderrunBufferSizeFrames,
            "lastUnderrunBufferSizeMs" to lastUnderrunBufferSizeMs,
            "lastUnderrunElapsedSinceFeedMs" to lastUnderrunElapsedSinceFeedMs,
            "lastUnderrunElapsedRealtimeMs" to lastUnderrunElapsedRealtimeMs,
        )
    }

    private fun applyDeckVolumes() {
        if (!::activePlayer.isInitialized) return
        val standby = standbyPlayer
        val transitionOwnsGain = crossfadeStatus == "starting" || crossfadeStatus == "fading"
        if (djDualDeckMode && standby != null && !transitionOwnsGain) {
            val (deckAGain, deckBGain) = Media3DjCrossfaderPolicy.gains(djCrossfaderPosition)
            val activeGain = if (activeDeckId == "A") deckAGain else deckBGain
            val standbyGain = if (standbyDeckId() == "A") deckAGain else deckBGain
            activePlayer.volume = gainPolicy.djDeckVolume(activeGain)
            standby.volume = gainPolicy.djDeckVolume(standbyGain)
            return
        }
        activePlayer.volume = gainPolicy.activeVolume()
        standby?.let { it.volume = gainPolicy.standbyVolume() }
    }

    /** Enter the persistent two-deck policy without changing the canonical queue. */
    fun enableDjDualDeckMode(): Boolean {
        if (!::activePlayer.isInitialized || isDestroyed ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        // A Player preload is not a DJ deck queue. Retire it before promoting
        // the same physical standby player into the persistent DJ lifecycle.
        if (standbyPlayer != null || crossfadeStatus in setOf("preparing", "waiting_ready", "ready")) {
            clearPreload("enter_dj_dual_deck_mode")
        }
        if ((standbyPlayer?.mediaItemCount ?: 0) > 0) return false
        val standby = standbyPlayer ?: newPlayer(
            handleAudioFocus = false,
            deckId = standbyDeckId(),
        ).also { standbyPlayer = it }
        djDualDeckMode = true
        djCrossfaderPosition = 0.5f
        standby.setAudioAttributes(audioAttributes(), false)
        standby.setHandleAudioBecomingNoisy(false)
        standby.pause()
        DspEngineSinkHook.suspendDeck(standbyDeckId())
        applyDeckVolumes()
        return true
    }

    /** Exit persistent DJ mixing and retire only the non-canonical deck. */
    fun disableDjDualDeckMode(): Boolean {
        if (!djDualDeckMode) return true
        if (crossfadeStatus in setOf("starting", "fading")) return false
        djDualDeckMode = false
        val retiringDeckId = standbyDeckId()
        val standby = standbyPlayer
        standbyPlayer = null
        if (standby != null) {
            runCatching { standby.pause(); standby.stop(); standby.clearMediaItems() }
            DspEngineRegistry.setDeckTrack(retiringDeckId, null)
            DspEngineSinkHook.suspendDeck(retiringDeckId)
            DspEngineSinkHook.forgetDeck(retiringDeckId)
            standby.release()
        }
        gainPolicy.resetDecks()
        applyDeckVolumes()
        crossfadeStatus = "idle"
        return true
    }

    /** Operator-owned physical A/B crossfader; automation never calls this. */
    fun setDjCrossfader(position: Float): Boolean {
        if (!djDualDeckMode || !position.isFinite() || position !in 0f..1f ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        djCrossfaderPosition = position
        applyDeckVolumes()
        return true
    }

    private fun playerForPhysicalDeck(deckId: String): ExoPlayer? = when {
        deckId == activeDeckId -> activePlayer
        deckId == standbyDeckId() -> standbyPlayer
        else -> null
    }

    /** Rebind the single MediaSession/focus owner to the requested physical deck. */
    private fun promoteDjCanonicalDeck(deckId: String): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B")) return false
        if (deckId == activeDeckId) return true
        val target = standbyPlayer ?: return false
        val outgoing = activePlayer
        val outgoingDeckId = activeDeckId
        activePlayer = target
        standbyPlayer = outgoing
        activeDeckId = deckId
        target.setAudioAttributes(
            audioAttributes(),
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = true,
                focusHandlingEnabled = media3AudioFocusEnabled,
            ),
        )
        target.setHandleAudioBecomingNoisy(AudioOutputPolicy.handlesBecomingNoisy(true))
        outgoing.setAudioAttributes(audioAttributes(), false)
        outgoing.setHandleAudioBecomingNoisy(false)
        DspEngineRegistry.setActiveDeck(deckId)
        if (target.isPlaying) DspEngineSinkHook.activateDeck(deckId)
        if (outgoing.isPlaying) DspEngineSinkHook.activateDeck(outgoingDeckId)
        else DspEngineSinkHook.suspendDeck(outgoingDeckId)
        mediaSession?.setPlayer(target)
        applyDeckVolumes()
        return true
    }

    /** Replace only the selected physical deck's queue; the other deck is untouched. */
    fun loadDjDeck(deckId: String, items: List<MediaItem>, startIndex: Int): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") || items.isEmpty() ||
            startIndex !in items.indices || items.any { it.localConfiguration?.uri == null } ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        val peerDeckId = if (deckId == "A") "B" else "A"
        val peer = playerForPhysicalDeck(peerDeckId)
        return try {
            if (player === activePlayer && player.playWhenReady) {
                suppressDjPeerPauseDeckId = deckId
            }
            player.pause()
            player.stop()
            player.clearMediaItems()
            DspEngineRegistry.setDeckTrack(deckId, null)
            player.setMediaItems(items, startIndex, 0L)
            player.prepare()
            DspEngineSinkHook.suspendDeck(deckId)
            if (player === activePlayer && peer?.isPlaying == true) {
                suppressDjPeerPauseDeckId = null
                promoteDjCanonicalDeck(peerDeckId)
                setAudioFocusHandling(true)
            }
            true
        } catch (_: Exception) {
            suppressDjPeerPauseDeckId = null
            false
        }
    }

    /** Play one physical deck; the playing deck becomes the sole focus owner. */
    fun playDjDeck(deckId: String): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            isCommunicationActive() || crossfadeStatus in setOf("starting", "fading")
        ) return false
        val target = playerForPhysicalDeck(deckId) ?: return false
        if (target.mediaItemCount == 0 || target.playbackState != Player.STATE_READY) return false
        if (!promoteDjCanonicalDeck(deckId) || !setAudioFocusHandling(true)) return false
        val player = activePlayer
        DspEngineSinkHook.activateDeck(deckId)
        return try {
            player.play()
            true
        } catch (_: Exception) {
            DspEngineSinkHook.suspendDeck(deckId)
            false
        }
    }

    /** Pause one physical deck; the other deck continues unless system transport owns the pause. */
    fun pauseDjDeck(deckId: String): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        val wasCanonical = player === activePlayer
        val peerDeckId = if (deckId == "A") "B" else "A"
        val peer = playerForPhysicalDeck(peerDeckId)
        if (wasCanonical && player.playWhenReady) suppressDjPeerPauseDeckId = deckId
        return try {
            player.pause()
            DspEngineSinkHook.suspendDeck(deckId)
            if (wasCanonical && peer?.isPlaying == true) {
                suppressDjPeerPauseDeckId = null
                promoteDjCanonicalDeck(peerDeckId)
                setAudioFocusHandling(true)
            }
            true
        } catch (_: Exception) {
            suppressDjPeerPauseDeckId = null
            false
        }
    }

    /** Apply tempo/pitch to one physical deck without changing its partner. */
    fun setDjDeckPlaybackParameters(deckId: String, speed: Float, pitch: Float): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        val parameters = Media3DeckPlaybackParametersPolicy.create(speed, pitch) ?: return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        if (player.mediaItemCount == 0) return false
        return try {
            player.playbackParameters = parameters
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Clear only the named physical deck while preserving the partner. */
    fun clearDjDeck(deckId: String): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        val wasCanonical = player === activePlayer
        val peerDeckId = if (deckId == "A") "B" else "A"
        val peer = playerForPhysicalDeck(peerDeckId)
        if (wasCanonical && player.playWhenReady) suppressDjPeerPauseDeckId = deckId
        return try {
            player.pause()
            player.stop()
            player.clearMediaItems()
            DspEngineRegistry.setDeckTrack(deckId, null)
            DspEngineSinkHook.suspendDeck(deckId)
            if (wasCanonical && peer?.isPlaying == true) {
                suppressDjPeerPauseDeckId = null
                promoteDjCanonicalDeck(peerDeckId)
                setAudioFocusHandling(true)
            }
            true
        } catch (_: Exception) {
            suppressDjPeerPauseDeckId = null
            false
        }
    }

    /** Seek only the named physical deck, with duration and identity checked natively. */
    fun seekDjDeck(deckId: String, positionMs: Long, expectedMediaId: String): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") || positionMs < 0L ||
            expectedMediaId.isBlank() || crossfadeStatus in setOf("starting", "fading")
        ) return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        if (player.currentMediaItem?.mediaId != expectedMediaId ||
            player.mediaItemCount == 0
        ) return false
        val duration = player.duration
        if (duration != C.TIME_UNSET && positionMs > duration) return false
        return try {
            player.seekTo(positionMs)
            true
        } catch (_: Exception) {
            false
        }
    }


    /**
     * Plays a short auxiliary sound without changing the canonical MediaSession
     * player, queue, playback state, or focus owner.
     */
    fun playAuxiliarySound(
        uri: Uri,
        volume: Float,
        startPositionMs: Long = 0L,
        endPositionMs: Long? = null,
    ): Boolean {
        if (isDestroyed || !uri.isHierarchical ||
            uri.scheme !in setOf("asset", "file", "content", "http", "https") ||
            !volume.isFinite() || volume !in 0f..1f || startPositionMs < 0L ||
            (endPositionMs != null && endPositionMs <= startPositionMs)
        ) return false
        val player = auxiliaryPlayer ?: ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(this))
            .build()
            .also { created ->
                // DJ samples and echo taps are part of the music mix. Use
                // the media stream (not the notification/sonification stream)
                // so they follow the listener's media volume and output route.
                // Focus remains disabled: the canonical deck owns audio focus.
                created.setAudioAttributes(audioAttributes(), false)
                auxiliaryPlayer = created
            }
        return try {
            player.stop()
            player.clearMediaItems()
            auxiliaryBaseVolume = volume
            player.volume = auxiliaryBaseVolume
            val item = MediaItem.Builder()
                .setUri(uri)
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(startPositionMs)
                        .apply { endPositionMs?.let { setEndPositionMs(it) } }
                        .build(),
                )
                .build()
            player.setMediaItem(item)
            player.prepare()
            player.play()
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Updates the active sample envelope without touching the music decks. */
    fun setAuxiliarySoundVolume(volume: Float): Boolean {
        if (!volume.isFinite() || volume !in 0f..1f) return false
        val player = auxiliaryPlayer ?: return false
        auxiliaryBaseVolume = volume
        player.volume = volume
        return true
    }

    /** Stops the current sample but keeps the reusable auxiliary player alive. */
    fun stopAuxiliarySound(): Boolean {
        val player = auxiliaryPlayer ?: return true
        return try {
            player.stop()
            player.clearMediaItems()
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Play an isolated two-track audition; canonical decks and focus remain untouched. */
    fun playTransitionPreview(outgoingUri: Uri, incomingUri: Uri, outgoingStartMs: Long,
        incomingStartMs: Long, durationMs: Long): Boolean {
        fun supported(uri: Uri) = uri.isHierarchical &&
            uri.scheme in setOf("asset", "file", "content", "http", "https")
        if (isDestroyed || !supported(outgoingUri) || !supported(incomingUri) ||
            outgoingStartMs < 0L || incomingStartMs < 0L || durationMs !in 2000L..15000L ||
            outgoingStartMs > Long.MAX_VALUE - durationMs ||
            incomingStartMs > Long.MAX_VALUE - durationMs || isCommunicationActive() ||
            standbyPlayer != null || crossfadeStatus in setOf("preparing", "waiting_ready", "ready", "starting", "fading")
        ) return false

        stopTransitionPreview()
        val generation = previewGeneration
        return try {
            val outgoing = previewOutgoingPlayer ?: newPlayer(false, "preview_out")
                .also { previewOutgoingPlayer = it }
            val incoming = previewIncomingPlayer ?: newPlayer(false, "preview_in")
                .also { previewIncomingPlayer = it }
            DspEngineSinkHook.activateDeck("preview_out")
            DspEngineSinkHook.activateDeck("preview_in")
            outgoing.volume = 0.78f
            incoming.volume = 0f
            previewStartRequested = false

            fun maybeBeginRamp() {
                if (generation != previewGeneration || !previewStartRequested ||
                    !outgoing.isPlaying || !incoming.isPlaying || previewRampRunnable != null
                ) return
                previewPrepareTimeout?.let(mainHandler::removeCallbacks)
                previewPrepareTimeout = null
                val startedAt = android.os.SystemClock.elapsedRealtime()
                val ramp = object : Runnable {
                    override fun run() {
                        if (generation != previewGeneration) return
                        val progress = ((android.os.SystemClock.elapsedRealtime() - startedAt).toDouble() /
                            durationMs.toDouble()).coerceIn(0.0, 1.0)
                        val angle = progress * PI / 2.0
                        outgoing.volume = (0.78 * cos(angle)).toFloat()
                        incoming.volume = (0.78 * sin(angle)).toFloat()
                        if (progress >= 1.0) stopTransitionPreview()
                        else mainHandler.postDelayed(this, 20L)
                    }
                }
                previewRampRunnable = ramp
                mainHandler.post(ramp)
            }
            fun maybeStart() {
                if (generation != previewGeneration ||
                    outgoing.playbackState != Player.STATE_READY ||
                    incoming.playbackState != Player.STATE_READY || previewStartRequested
                ) return
                previewStartRequested = true
                gainPolicy.setPreviewDuckGain(0.22f)
                applyDeckVolumes()
                outgoing.playWhenReady = true
                incoming.playWhenReady = true
                maybeBeginRamp()
            }
            val outListener = object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) { maybeStart() }
                override fun onIsPlayingChanged(isPlaying: Boolean) { maybeBeginRamp() }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    if (generation == previewGeneration) stopTransitionPreview()
                }
            }
            val inListener = object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) { maybeStart() }
                override fun onIsPlayingChanged(isPlaying: Boolean) { maybeBeginRamp() }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    if (generation == previewGeneration) stopTransitionPreview()
                }
            }
            previewOutgoingListener = outListener
            previewIncomingListener = inListener
            outgoing.addListener(outListener)
            incoming.addListener(inListener)
            outgoing.setMediaItem(MediaItem.Builder().setUri(outgoingUri).setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setStartPositionMs(outgoingStartMs)
                    .setEndPositionMs(outgoingStartMs + durationMs).build(),
            ).build())
            incoming.setMediaItem(MediaItem.Builder().setUri(incomingUri).setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setStartPositionMs(incomingStartMs)
                    .setEndPositionMs(incomingStartMs + durationMs).build(),
            ).build())
            outgoing.prepare()
            incoming.prepare()
            val timeout = Runnable {
                if (generation == previewGeneration && previewRampRunnable == null) {
                    stopTransitionPreview()
                }
            }
            previewPrepareTimeout = timeout
            mainHandler.postDelayed(timeout, 12000L)
            maybeStart()
            true
        } catch (_: Exception) {
            stopTransitionPreview()
            false
        }
    }

    /** Stop the audition and release both preview DSP handles. */
    fun stopTransitionPreview(): Boolean {
        previewGeneration++
        previewRampRunnable?.let(mainHandler::removeCallbacks)
        previewRampRunnable = null
        previewPrepareTimeout?.let(mainHandler::removeCallbacks)
        previewPrepareTimeout = null
        previewStartRequested = false
        previewOutgoingPlayer?.let { p ->
            previewOutgoingListener?.let(p::removeListener)
            runCatching { p.pause(); p.stop(); p.clearMediaItems(); p.volume = 0f }
        }
        previewIncomingPlayer?.let { p ->
            previewIncomingListener?.let(p::removeListener)
            runCatching { p.pause(); p.stop(); p.clearMediaItems(); p.volume = 0f }
        }
        previewOutgoingListener = null
        previewIncomingListener = null
        DspEngineSinkHook.suspendDeck("preview_out")
        DspEngineSinkHook.suspendDeck("preview_in")
        gainPolicy.setPreviewDuckGain(1f)
        applyDeckVolumes()
        return true
    }

    /** Current deck session for session-bound DSP/effects attachment. */
    fun activeAudioSessionId(): Int =
        if (::activePlayer.isInitialized) activePlayer.audioSessionId else 0

    /** Session of the prepared standby deck, for session-bound Android effects. */
    fun standbyAudioSessionId(): Int =
        standbyPlayer?.takeIf { it.mediaItemCount > 0 }?.audioSessionId ?: 0

    /** Physical A/B deck currently promoted as the canonical MediaSession player. */
    fun activeDeckId(): String = activeDeckId

    /** True while Android is in a phone, VoIP, or ringing communication mode. */
    fun isCommunicationActive(): Boolean {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val mode = audioManager.mode
        return AudioCommunicationGuard.isActive(mode)
    }

    /** Enables/disables ExoPlayer focus requests for the active deck only. */
    fun setAudioFocusHandling(enabled: Boolean): Boolean {
        if (enabled && isCommunicationActive()) return false
        media3AudioFocusEnabled = enabled
        if (::activePlayer.isInitialized) {
            activePlayer.setAudioAttributes(
                audioAttributes(),
                AudioOutputPolicy.handlesAudioFocus(
                    isCanonicalActiveDeck = true,
                    focusHandlingEnabled = enabled,
                ),
            )
        }
        standbyPlayer?.setAudioAttributes(
            audioAttributes(),
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = false,
                focusHandlingEnabled = enabled,
            ),
        )
        return true
    }

    fun setMasterVolume(value: Float): Boolean {
        if (!gainPolicy.setMasterVolume(value)) return false
        applyDeckVolumes()
        return true
    }

    /**
     * Keep transport policy identical on both decks. A prepared standby deck
     * can become active after crossfade, so updates must not leave it stale.
     */
    fun setRepeatMode(mode: Int): Boolean {
        if (mode != Player.REPEAT_MODE_OFF &&
            mode != Player.REPEAT_MODE_ONE &&
            mode != Player.REPEAT_MODE_ALL
        ) return false
        activePlayer.repeatMode = mode
        standbyPlayer?.repeatMode = mode
        return true
    }

    fun setPlaybackSpeed(speed: Float): Boolean {
        if (!speed.isFinite() || speed !in 0.5f..2.0f) return false
        return setDeckPlaybackSpeeds(active = speed, standby = speed)
    }

    /**
     * DJ transitions may need different rates on outgoing and incoming decks.
     * Keep the two values explicit so a standby correction never changes the
     * active deck or gets silently overwritten by a shared speed update.
     */
    /** Apply user pitch to both decks while preserving DJ/user playback rates. */
    fun setPlaybackPitch(pitch: Float): Boolean {
        if (!pitch.isFinite() || pitch !in 0.5f..2.0f) return false
        activePlayer.playbackParameters = PlaybackParameters(
            activePlayer.playbackParameters.speed, pitch,
        )
        standbyPlayer?.let {
            it.playbackParameters = PlaybackParameters(it.playbackParameters.speed, pitch)
        }
        return true
    }

    fun setDeckPlaybackSpeeds(active: Float, standby: Float): Boolean {
        if (!active.isFinite() || active !in 0.5f..2.0f ||
            !standby.isFinite() || standby !in 0.5f..2.0f
        ) return false
        activePlayer.playbackParameters = PlaybackParameters(active, activePlayer.playbackParameters.pitch)
        standbyPlayer?.let { it.playbackParameters = PlaybackParameters(standby, it.playbackParameters.pitch) }
        return true
    }

    /** Apply complete speed/pitch parameters to logical decks in one command. */
    fun setDeckPlaybackParameters(
        activeSpeed: Float,
        activePitch: Float,
        standbySpeed: Float,
        standbyPitch: Float,
    ): Boolean {
        val activeParameters = Media3DeckPlaybackParametersPolicy.create(activeSpeed, activePitch)
            ?: return false
        val standbyParameters = Media3DeckPlaybackParametersPolicy.create(standbySpeed, standbyPitch)
            ?: return false
        activePlayer.playbackParameters = activeParameters
        standbyPlayer?.playbackParameters = standbyParameters
        return true
    }

    fun setShuffleMode(enabled: Boolean): Boolean {
        activePlayer.shuffleModeEnabled = enabled
        standbyPlayer?.shuffleModeEnabled = enabled
        return true
    }

    /** Apply track leveling, DSP preamp, sleep fade and focus ducking together. */
    fun setDeckEqOverlay(deckRole: String, centersHz: DoubleArray, gainsDb: DoubleArray): Boolean =
        DspEngineRegistry.setTemporaryEqOverlay(deckRole, centersHz, gainsDb)

    fun clearDeckEqOverlay(deckRole: String): Boolean =
        DspEngineRegistry.clearTemporaryEqOverlay(deckRole)

    fun setGainFactors(
        trackLevel: Float,
        preamp: Float,
        sleepFade: Float,
        focusDuck: Float,
    ): Boolean {
        if (!gainPolicy.setGainFactors(trackLevel, preamp, sleepFade, focusDuck)) return false
        applyDeckVolumes()
        return true
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        activePlayer = newPlayer(handleAudioFocus = media3AudioFocusEnabled, deckId = "A")
        activeDeckId = "A"
        DspEngineRegistry.setActiveDeck(activeDeckId)
        DspEngineSinkHook.activateDeck(activeDeckId)
        // Media3 is the sole system-media publisher. Use Resonate's monochrome
        // status-bar mark; track artwork remains the large media-card artwork.
        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this).build().apply {
                setSmallIcon(R.drawable.ic_stat_resonate)
            },
        )
        mediaSession = MediaSession.Builder(this, activePlayer).build()
        applyDeckVolumes()
    }

    private fun newPlayer(handleAudioFocus: Boolean, deckId: String) = ExoPlayer.Builder(
        this,
        object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioOutputPlaybackParams: Boolean,
            ): AudioSink = DefaultAudioSink.Builder(context)
                .setAudioProcessors(DspEngineSinkHook.createProcessors(deckId))
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioOutputPlaybackParams)
                .build()
        },
    ).build().apply {
        val deck = this
        addAnalyticsListener(object : AnalyticsListener {
            override fun onAudioUnderrun(
                eventTime: AnalyticsListener.EventTime,
                bufferSize: Int,
                bufferSizeMs: Long,
                elapsedSinceLastFeedMs: Long,
            ) {
                synchronized(audioDiagnosticsLock) {
                    audioUnderrunCounts[deckId] = (audioUnderrunCounts[deckId] ?: 0) + 1
                    lastUnderrunDeck = deckId
                    lastUnderrunBufferSizeFrames = bufferSize.coerceAtLeast(0)
                    lastUnderrunBufferSizeMs = bufferSizeMs
                    lastUnderrunElapsedSinceFeedMs = elapsedSinceLastFeedMs
                    lastUnderrunElapsedRealtimeMs = android.os.SystemClock.elapsedRealtime()
                }
            }
        })
        setAudioAttributes(
            audioAttributes(),
            AudioOutputPolicy.handlesAudioFocus(
                isCanonicalActiveDeck = deckId == activeDeckId,
                focusHandlingEnabled = handleAudioFocus,
            ),
        )
        // Only the canonical active deck owns the noisy-output policy. The
        // standby deck must never independently react to a route change.
        setHandleAudioBecomingNoisy(
            AudioOutputPolicy.handlesBecomingNoisy(deckId == activeDeckId),
        )
        repeatMode = Player.REPEAT_MODE_OFF
        addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                // The standby deck identity changes after promotion. Attach
                // readiness handling to both physical players so later preloads
                // receive the same deferred-start behavior.
                if (deck !== standbyPlayer ||
                    (crossfadeStatus != "preparing" && crossfadeStatus != "waiting_ready")
                ) return
                crossfadeStatus = when (playbackState) {
                    Player.STATE_READY -> "ready"
                    Player.STATE_IDLE, Player.STATE_BUFFERING -> "preparing"
                    Player.STATE_ENDED -> "incoming_ended"
                    else -> crossfadeStatus
                }
                if (playbackState == Player.STATE_READY) {
                    val pendingDuration = pendingCrossfadeDurationMs
                    if (pendingDuration != null && activePlayer.isPlaying) {
                        pendingCrossfadeDurationMs = null
                        beginCrossfade(pendingDuration)
                    } else {
                        // Keep the pending duration while the active deck is
                        // paused. Its isPlaying listener will resume the
                        // deferred start after focus/transport resumes.
                        crossfadeStatus = "ready"
                    }
                }
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                if (deck === standbyPlayer) {
                    pendingCrossfadeDurationMs = null
                    startingCrossfadeDurationMs = null
                    crossfadeStatus = "incoming_error"
                }
            }

            override fun onMediaItemTransition(
                mediaItem: MediaItem?,
                reason: Int,
            ) {
                // Analysis hints are keyed to the physical A/B deck and exact
                // MediaItem identity. Queue changes and standby reuse invalidate
                // old track hints before the next PCM block can consume them.
                val physicalDeckId = when {
                    deck === activePlayer -> activeDeckId
                    deck === standbyPlayer -> standbyDeckId()
                    else -> null
                }
                lastMediaTransitionDeckId = physicalDeckId ?: deckId
                lastMediaTransitionMediaId = mediaItem?.mediaId
                lastMediaTransitionReason = reason
                lastMediaTransitionElapsedRealtimeMs = android.os.SystemClock.elapsedRealtime()
                if (physicalDeckId != null) {
                    DspEngineRegistry.setDeckTrack(physicalDeckId, mediaItem?.mediaId)
                }
                // MediaSession controllers (headsets, Bluetooth, notification,
                // Android Auto) can navigate the active playlist without going
                // through the Flutter command lane. Invalidate any preloaded
                // incoming deck on those transitions so an old crossfade can
                // never promote stale queue content over the user's selection.
                if (deck === activePlayer) {
                    val preserveIncomingForFade = Media3PreloadInvalidationPolicy
                        .preserveIncomingOnAutomaticTransition(
                            crossfadeStatus = crossfadeStatus,
                            isAutomaticTransition = reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO,
                        )
                    if (!preserveIncomingForFade) {
                        clearPreload("active_deck_media_item_transition")
                        stopTransitionPreview()
                    }
                }
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                // MediaSession/headset commands can bypass the Flutter bridge.
                // A canonical pause must also silence the separate DJ sample
                // player; otherwise it can remain audible under a paused track.
                if (
                    AudioOutputPolicy.shouldStopAuxiliaryAudio(
                        isCanonicalActiveDeck = deck === activePlayer,
                        playWhenReady = playWhenReady,
                    )
                ) {
                    stopAuxiliarySound()
                }
                // MediaSession commands (notification, headset, Android Auto)
                // bypass the Flutter bridge. A canonical pause must silence the
                // standby deck even when it is only preparing and no fade clock
                // is active.
                if (deck === activePlayer && !playWhenReady) {
                    val deckId = activeDeckId
                    val isIndependentDeckPause =
                        djDualDeckMode && suppressDjPeerPauseDeckId == deckId
                    if (isIndependentDeckPause) {
                        suppressDjPeerPauseDeckId = null
                    } else {
                        standbyPlayer?.pause()
                    }
                    if (!djDualDeckMode) pauseCrossfade()
                    stopTransitionPreview()
                }
                // Never allow a deck to continue output in call/VoIP mode.
                if (playWhenReady && isCommunicationActive()) {
                    deck.pause()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!::activePlayer.isInitialized) return
                if (deck === standbyPlayer) {
                    // Do not attenuate the outgoing deck while ExoPlayer is
                    // still starting the incoming audio output. The fade clock
                    // begins only once the incoming deck is actually playing.
                    if (isPlaying && crossfadeStatus == "starting") {
                        val duration = startingCrossfadeDurationMs
                        if (duration != null && activePlayer.isPlaying) {
                            startCrossfadeRamp(duration, fadeGeneration)
                        }
                    }
                    return
                }
                if (deck !== activePlayer) return
                if (crossfadeStatus == "starting" && !isPlaying) {
                    // If playback is interrupted while the incoming output is
                    // starting, return to the deferred-ready state. Resume will
                    // retry without consuming any part of the fade duration.
                    pendingCrossfadeDurationMs = startingCrossfadeDurationMs
                    startingCrossfadeDurationMs = null
                    standbyPlayer?.pause()
                    DspEngineSinkHook.suspendDeck(standbyDeckId())
                    crossfadeStatus = "ready"
                    return
                }
                // A fade requested while the standby deck is preparing waits
                // for both decks to be runnable. Preserve that request across
                // transient focus/buffering pauses and start it on resume.
                if (crossfadeStatus == "waiting_ready" || crossfadeStatus == "ready") {
                    val pendingDuration = pendingCrossfadeDurationMs
                    if (isPlaying && pendingDuration != null &&
                        standbyPlayer?.playbackState == Player.STATE_READY
                    ) {
                        pendingCrossfadeDurationMs = null
                        beginCrossfade(pendingDuration)
                    }
                    return
                }
                if (crossfadeStatus != "fading") return
                // Freeze the native equal-power clock when the active deck
                // pauses, then resume the exact ramp position on playback.
                if (isPlaying) {
                    resumeCrossfade()
                } else {
                    pauseCrossfade()
                }
            }
        })
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    private fun audioAttributes() = AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
        .build()

    /** Prepares the inactive deck without disturbing current playback. */
    fun preloadNext(
        items: List<MediaItem>,
        startIndex: Int,
        startPositionMs: Long = 0L,
    ): Boolean {
        if (items.isEmpty() || startIndex !in items.indices || startPositionMs < 0L ||
            items.any { it.localConfiguration?.uri == null } || !::activePlayer.isInitialized
        ) return false
        stopTransitionPreview()
        cancelCrossfade()
        val standby = standbyPlayer ?: newPlayer(handleAudioFocus = false, deckId = standbyDeckId())
            .also { standbyPlayer = it }
        standby.volume = 0f
        gainPolicy.setCrossfadeGains(active = 1f, standby = 0f)
        applyDeckVolumes()
        // Construct the second physical deck only when a preload is requested.
        // The full incoming queue and active transport parameters are copied
        // before preparation so promotion does not need to rebuild its playlist.
        standby.repeatMode = activePlayer.repeatMode
        standby.shuffleModeEnabled = activePlayer.shuffleModeEnabled
        standby.playbackParameters = activePlayer.playbackParameters
        standby.setMediaItems(items, startIndex, startPositionMs)
        standby.prepare()
        crossfadeStatus = "preparing"
        return true
    }

    /**
     * Reconcile a live queue edit on the standby deck without discarding a
     * prepared incoming decoder. The current standby occurrence must remain at
     * the same index with the same media ID and URI; otherwise it is stale and
     * must be retired before it can be promoted.
     */
    fun synchronizePreload(items: List<MediaItem>): Boolean {
        val standby = standbyPlayer ?: return false
        val preparedIndex = standby.currentMediaItemIndex
        val preparedItem = standby.currentMediaItem ?: run {
            clearPreload("queue_sync_missing_prepared_item")
            return false
        }
        val preparedIdentity = Media3QueueEntryIdentity(
            mediaId = preparedItem.mediaId,
            uri = preparedItem.localConfiguration?.uri?.toString().orEmpty(),
        )
        val nextIdentity = items.map { item ->
            Media3QueueEntryIdentity(
                mediaId = item.mediaId,
                uri = item.localConfiguration?.uri?.toString().orEmpty(),
            )
        }
        if (!Media3QueueReconciliationPolicy.preservesPreparedOccurrence(
                newQueue = nextIdentity,
                preparedIndex = preparedIndex,
                preparedItem = preparedIdentity,
            )
        ) {
            clearPreload("queue_sync_prepared_occurrence_changed")
            return false
        }

        // Keep the prepared current MediaItem attached to the standby player.
        // Updating only the entries around it preserves its decoder, position,
        // and readiness while making the promoted deck's future queue canonical.
        standby.removeMediaItems(preparedIndex + 1, standby.mediaItemCount)
        standby.removeMediaItems(0, preparedIndex)
        if (preparedIndex > 0) {
            standby.addMediaItems(0, items.subList(0, preparedIndex))
        }
        if (preparedIndex < items.lastIndex) {
            standby.addMediaItems(preparedIndex + 1, items.subList(preparedIndex + 1, items.size))
        }
        return true
    }

    /**
     * Starts a cancellable gain ramp. Equal-power curves avoid the large perceived
     * dip of a linear crossfade. Calls are main-thread serialized by the bridge.
     */
    fun startCrossfade(durationMs: Long): Boolean {
        if (durationMs !in 250L..15000L) return false
        val standby = standbyPlayer ?: run {
            crossfadeStatus = "incoming_not_ready"
            return false
        }
        if (standby.mediaItemCount == 0) {
            crossfadeStatus = "incoming_not_ready"
            return false
        }
        if (!activePlayer.isPlaying ||
            standby.playbackState != Player.STATE_READY
        ) {
            if (standby.playbackState != Player.STATE_READY &&
                standby.playbackState != Player.STATE_BUFFERING &&
                standby.playbackState != Player.STATE_IDLE
            ) {
                crossfadeStatus = "incoming_not_ready"
                return false
            }
            pendingCrossfadeDurationMs = durationMs
            crossfadeStatus = if (standby.playbackState == Player.STATE_READY) {
                "ready"
            } else {
                "waiting_ready"
            }
            return true
        }
        return beginCrossfade(durationMs)
    }

    /** Start the native equal-power ramp only after standby is actually ready. */
    private fun beginCrossfade(durationMs: Long): Boolean {
        val standby = standbyPlayer ?: return false
        if (durationMs !in 250L..15000L || !activePlayer.isPlaying ||
            standby.mediaItemCount == 0 ||
            standby.playbackState != Player.STATE_READY
        ) return false
        pendingCrossfadeDurationMs = null
        cancelCrossfade(clearOverlays = false, resetStandbySpeed = false)
        val generation = ++fadeGeneration
        startingCrossfadeDurationMs = durationMs
        crossfadeStatus = "starting"
        gainPolicy.resetDecks()
        applyDeckVolumes()
        // The standby processor remains pass-through while merely preloaded.
        // Create/inherit its native DSP state only when it is about to join the fade.
        DspEngineSinkHook.activateDeck(standbyDeckId())
        standby.play()
        // isPlaying may already be true for an immediately-starting local
        // source. Handle that synchronously as well as through the listener.
        if (standby.isPlaying) {
            startCrossfadeRamp(durationMs, generation)
        }
        return true
    }

    /** Begin the gain ramp only after both decks are producing playback. */
    private fun startCrossfadeRamp(durationMs: Long, generation: Int) {
        if (generation != fadeGeneration || isDestroyed ||
            crossfadeStatus != "starting" || !activePlayer.isPlaying ||
            standbyPlayer?.isPlaying != true
        ) return
        startingCrossfadeDurationMs = null
        crossfadeClock.start(durationMs, android.os.SystemClock.elapsedRealtime())
        crossfadeStatus = "fading"
        val task = object : Runnable {
            override fun run() {
                if (generation != fadeGeneration || isDestroyed) return
                val progress = crossfadeClock.progress(android.os.SystemClock.elapsedRealtime())
                val (activeGain, standbyGain) = Media3CrossfadeEnvelope.gains(progress)
                gainPolicy.setCrossfadeGains(
                    active = activeGain,
                    standby = standbyGain,
                )
                applyDeckVolumes()
                if (progress >= 1f) {
                    val incomingPlayer = standbyPlayer ?: return
                    val oldPlayer = activePlayer
                    // Close the outgoing output before changing the gain policy.
                    // At the end of the ramp it is still playing; resetting the
                    // equal-power gains first would briefly restore both decks
                    // to full level. Muting is safe before the reference swap
                    // because volume changes do not emit transport callbacks.
                    oldPlayer.volume = 0f
                    val outgoingDeckId = activeDeckId
                    activePlayer = incomingPlayer
                    standbyPlayer = null
                    activeDeckId = if (activeDeckId == "A") "B" else "A"
                    DspEngineRegistry.setActiveDeck(activeDeckId)
                    DspEngineSinkHook.activateDeck(activeDeckId)
                    DspEngineSinkHook.suspendDeck(outgoingDeckId)
                    DspEngineRegistry.clearAllTemporaryEqOverlays()
                    activePlayer.setAudioAttributes(
                        audioAttributes(),
                        AudioOutputPolicy.handlesAudioFocus(
                            isCanonicalActiveDeck = true,
                            focusHandlingEnabled = media3AudioFocusEnabled,
                        ),
                    )
                    activePlayer.setHandleAudioBecomingNoisy(
                        AudioOutputPolicy.handlesBecomingNoisy(true),
                    )
                    // Rebind the canonical MediaSession before stopping the
                    // outgoing physical player. Its listener now observes it as
                    // standby, so the pause cannot be mistaken for a user pause
                    // of the newly promoted active deck.
                    mediaSession?.setPlayer(activePlayer)
                    // The old physical deck is no longer needed after promotion.
                    // Release it instead of keeping a second ExoPlayer alive.
                    oldPlayer.pause()
                    if (djDualDeckMode) {
                        // DJ mode keeps both physical ExoPlayers alive. The
                        // outgoing deck becomes the new standby instead of
                        // being destroyed after every handoff.
                        oldPlayer.setAudioAttributes(audioAttributes(), false)
                        oldPlayer.setHandleAudioBecomingNoisy(false)
                        standbyPlayer = oldPlayer
                        DspEngineSinkHook.suspendDeck(outgoingDeckId)
                    } else {
                        standbyPlayer = null
                        oldPlayer.release()
                        DspEngineSinkHook.forgetDeck(outgoingDeckId)
                    }
                    gainPolicy.resetDecks()
                    crossfadeStatus = "completed"
                    applyDeckVolumes()
                    fadeRunnable = null
                    crossfadeClock.reset()
                } else {
                    mainHandler.postDelayed(this, 32L)
                }
            }
        }
        fadeRunnable = task
        mainHandler.post(task)
    }

    /**
     * Freeze an in-flight transition when transport pauses. The active deck is
     * paused by the MediaSession command; this method freezes the ramp clock and
     * pauses the standby deck so neither audio nor fade progress advances silently.
     */
    fun pauseCrossfade(): Boolean {
        if (crossfadeStatus == "starting") {
            pendingCrossfadeDurationMs = startingCrossfadeDurationMs
            startingCrossfadeDurationMs = null
            standbyPlayer?.pause()
            DspEngineSinkHook.suspendDeck(standbyDeckId())
            crossfadeStatus = "ready"
            return true
        }
        if (crossfadeStatus == "waiting_ready" || crossfadeStatus == "ready") {
            standbyPlayer?.pause()
            DspEngineSinkHook.suspendDeck(standbyDeckId())
            // Keep waiting_ready while preparation is incomplete. The standby
            // readiness listener must remain armed so it can finish the
            // deferred transition after a pause/resume cycle.
            return true
        }
        if (crossfadeStatus != "fading") return false
        if (!crossfadeClock.pause(android.os.SystemClock.elapsedRealtime())) return false
        fadeRunnable?.let(mainHandler::removeCallbacks)
        standbyPlayer?.pause()
        DspEngineSinkHook.suspendDeck(standbyDeckId())
        return true
    }

    /**
     * Hard silence barrier for a transport pause. Always pause both physical
     * decks, not just the deck participating in a currently-running fade.
     * This covers standby preparation and any stale standby playback state.
     */
    fun pauseAllDecks(): Boolean {
        if (!::activePlayer.isInitialized) return false
        pauseCrossfade()
        activePlayer.pause()
        standbyPlayer?.pause()
        stopAuxiliarySound()
        stopTransitionPreview()
        return true
    }

    /** Resume both decks from the exact gain-ramp position at which they paused. */
    fun resumeCrossfade(): Boolean {
        val standby = standbyPlayer ?: return false
        if (crossfadeStatus != "fading" || fadeRunnable == null) return false
        if (!crossfadeClock.resume(android.os.SystemClock.elapsedRealtime())) return false
        DspEngineSinkHook.activateDeck(standbyDeckId())
        standby.play()
        mainHandler.post(fadeRunnable!!)
        return true
    }

    /**
     * Navigate the currently promoted physical deck as one main-thread operation.
     * Clearing standby before dispatch prevents a prepared/fading deck from
     * continuing to output while the active queue advances. Using activePlayer
     * (rather than a previously captured deck reference) also makes the command
     * promotion-safe after MediaSession.setPlayer() swaps the canonical deck.
     */
    fun skipToNext(): Boolean {
        if (!::activePlayer.isInitialized) return false
        clearPreload("skip_to_next")
        activePlayer.seekToNextMediaItem()
        return true
    }

    /** Same promotion-safe transport barrier as [skipToNext]. */
    fun skipToPrevious(): Boolean {
        if (!::activePlayer.isInitialized) return false
        clearPreload("skip_to_previous")
        activePlayer.seekToPreviousMediaItem()
        return true
    }

    /**
     * Invalidates the standby deck when the active source or queue is replaced.
     * Without this, a later crossfade could promote a track from an obsolete queue.
     */
    private var lastPreloadInvalidationReason: String? = null
    private var lastPreloadInvalidationElapsedRealtimeMs: Long? = null
    private var preloadInvalidationCount: Long = 0

    fun clearPreload(reason: String = "unspecified"): Boolean {
        if (!::activePlayer.isInitialized) return false
        lastPreloadInvalidationReason = reason
        lastPreloadInvalidationElapsedRealtimeMs = android.os.SystemClock.elapsedRealtime()
        preloadInvalidationCount++
        pendingCrossfadeDurationMs = null
        cancelCrossfade()
        val standby = standbyPlayer
        if (standby != null) {
            val retiringDeckId = standbyDeckId()
            DspEngineRegistry.setDeckTrack(retiringDeckId, null)
            standby.pause()
            standby.clearMediaItems()
            if (djDualDeckMode) {
                // Preserve the physical player and DSP attachment for the
                // next independently prepared DJ deck occurrence.
                DspEngineSinkHook.suspendDeck(retiringDeckId)
            } else {
                standbyPlayer = null
                DspEngineSinkHook.suspendDeck(retiringDeckId)
                DspEngineSinkHook.forgetDeck(retiringDeckId)
                standby.release()
            }
        }
        crossfadeStatus = "idle"
        if (djDualDeckMode) applyDeckVolumes()
        return true
    }

    /**
     * A crossfade may promote physical deck B. A fresh user-selected queue is
     * ordinary playback, so return ownership to a newly-created primary A deck
     * rather than letting B become the long-lived default player.
     */
    fun restorePrimaryDeckForNewSelection(): Boolean {
        if (!::activePlayer.isInitialized) return false
        // A new Player selection exits DJ's persistent pair and restores the
        // ordinary single-user-deck lifecycle before loading its queue.
        djDualDeckMode = false
        clearPreload("restore_primary_deck_for_new_selection")
        stopTransitionPreview()
        if (activeDeckId == "A") return true

        val outgoing = activePlayer
        DspEngineRegistry.setDeckTrack("A", null)
        DspEngineRegistry.setDeckTrack("B", null)
        val primary = newPlayer(
            handleAudioFocus = media3AudioFocusEnabled,
            deckId = "A",
        )
        primary.repeatMode = outgoing.repeatMode
        primary.shuffleModeEnabled = outgoing.shuffleModeEnabled
        primary.playbackParameters = outgoing.playbackParameters

        // Rebind the canonical session before retiring B. The caller will load
        // the newly selected queue into this clean A deck immediately afterward.
        activePlayer = primary
        activeDeckId = "A"
        DspEngineRegistry.setActiveDeck("A")
        DspEngineSinkHook.activateDeck("A")
        mediaSession?.setPlayer(primary)

        outgoing.pause()
        outgoing.release()
        DspEngineSinkHook.suspendDeck("B")
        DspEngineSinkHook.forgetDeck("B")
        gainPolicy.resetDecks()
        applyDeckVolumes()
        crossfadeStatus = "idle"
        return true
    }

    /** Atomically restore primary A and load a fresh user-selected queue. */
    fun seekTo(positionMs: Long): Boolean? {
        if (!::activePlayer.isInitialized) return null
        if (positionMs < 0L) return false
        return try {
            activePlayer.seekTo(positionMs)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Cue the prepared incoming deck without touching canonical transport.
     * Only an idle, ready standby occurrence may be repositioned; the media ID
     * is supplied by the caller to fail closed if the preload was replaced.
     */
    fun seekStandby(
        positionMs: Long,
        expectedMediaId: String,
        expectedQueueIndex: Int,
    ): Boolean {
        if (!::activePlayer.isInitialized || positionMs < 0L || expectedQueueIndex < 0 ||
            expectedMediaId.isBlank() || crossfadeStatus != "ready" ||
            pendingCrossfadeDurationMs != null || startingCrossfadeDurationMs != null
        ) return false
        val standby = standbyPlayer ?: return false
        if (standby.isPlaying || standby.playbackState != Player.STATE_READY ||
            standby.currentMediaItemIndex != expectedQueueIndex ||
            standby.currentMediaItem?.mediaId != expectedMediaId
        ) return false
        val duration = standby.duration
        if (duration != C.TIME_UNSET && positionMs > duration) return false
        return try {
            standby.seekTo(positionMs)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun loadNewQueue(items: List<MediaItem>, startIndex: Int): Boolean {
        if (items.isEmpty() || startIndex !in items.indices ||
            items.any { it.localConfiguration?.uri == null } ||
            !restorePrimaryDeckForNewSelection()
        ) return false
        activePlayer.setMediaItems(items, startIndex, 0L)
        activePlayer.prepare()
        return true
    }

    fun cancelCrossfade(
        clearOverlays: Boolean = true,
        resetStandbySpeed: Boolean = true,
    ): Boolean {
        stopTransitionPreview()
        pendingCrossfadeDurationMs = null
        startingCrossfadeDurationMs = null
        fadeGeneration++
        if (clearOverlays) DspEngineRegistry.clearAllTemporaryEqOverlays()
        fadeRunnable?.let(mainHandler::removeCallbacks)
        fadeRunnable = null
        crossfadeClock.reset()
        if (::activePlayer.isInitialized) {
            // Cancellation preserves the current deck and silences any temporary incoming deck.
            gainPolicy.resetDecks()
            applyDeckVolumes()
            standbyPlayer?.let {
                it.pause()
                DspEngineSinkHook.suspendDeck(standbyDeckId())
                if (resetStandbySpeed) it.playbackParameters = activePlayer.playbackParameters
            }
        }
        if (crossfadeStatus == "fading" || crossfadeStatus == "starting" ||
            crossfadeStatus == "preparing" || crossfadeStatus == "waiting_ready" ||
            crossfadeStatus == "ready"
        ) {
            crossfadeStatus = "cancelled"
        }
        if (::activePlayer.isInitialized) {
            gainPolicy.resetDecks()
            applyDeckVolumes()
        }
        return true
    }

    fun crossfadeState(): Map<String, Any?> = mapOf(
        "status" to crossfadeStatus,
        "progress" to when (crossfadeStatus) {
            "fading" -> crossfadeClock.progress(android.os.SystemClock.elapsedRealtime())
            "completed" -> 1f
            else -> 0f
        },
        "activeDeckId" to activeDeckId,
        "djDualDeckMode" to djDualDeckMode,
        "djCrossfaderPosition" to djCrossfaderPosition,
        "deckA" to physicalDeckState("A"),
        "deckB" to physicalDeckState("B"),
        "activeMediaId" to activePlayer.currentMediaItem?.mediaId,
        "incomingReady" to (standbyPlayer?.playbackState == Player.STATE_READY),
        "incomingMediaId" to standbyPlayer?.currentMediaItem?.mediaId,
        "activePositionMs" to activePlayer.currentPosition.coerceAtLeast(0L),
        "incomingPositionMs" to (standbyPlayer?.currentPosition?.coerceAtLeast(0L) ?: 0L),
        "activeVolume" to activePlayer.volume,
        "incomingVolume" to (standbyPlayer?.volume ?: 0f),
        "activeSpeed" to activePlayer.playbackParameters.speed,
        "activePitch" to activePlayer.playbackParameters.pitch,
        "standbySpeed" to standbyPlayer?.playbackParameters?.speed,
        "standbyPitch" to standbyPlayer?.playbackParameters?.pitch,
        "lastMediaTransitionDeckId" to lastMediaTransitionDeckId,
        "lastMediaTransitionMediaId" to lastMediaTransitionMediaId,
        "lastMediaTransitionReason" to lastMediaTransitionReason,
        "lastMediaTransitionReasonName" to when (lastMediaTransitionReason) {
            Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT -> "repeat"
            Player.MEDIA_ITEM_TRANSITION_REASON_AUTO -> "auto"
            Player.MEDIA_ITEM_TRANSITION_REASON_SEEK -> "seek"
            Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED -> "playlist_changed"
            else -> "unknown"
        },
        "lastMediaTransitionElapsedRealtimeMs" to lastMediaTransitionElapsedRealtimeMs,
        "lastPreloadInvalidationReason" to lastPreloadInvalidationReason,
        "lastPreloadInvalidationElapsedRealtimeMs" to lastPreloadInvalidationElapsedRealtimeMs,
        "preloadInvalidationCount" to preloadInvalidationCount,
    )

    private fun physicalDeckState(deckId: String): Map<String, Any?>? {
        val player = when {
            activeDeckId == deckId -> activePlayer
            standbyDeckId() == deckId -> standbyPlayer
            else -> null
        } ?: return null
        return mapOf(
            "deckId" to deckId,
            "mediaId" to player.currentMediaItem?.mediaId,
            "title" to player.mediaMetadata.title?.toString(),
            "artist" to player.mediaMetadata.artist?.toString(),
            "album" to player.mediaMetadata.albumTitle?.toString(),
            "positionMs" to player.currentPosition.coerceAtLeast(0L),
            "bufferedPositionMs" to player.bufferedPosition.coerceAtLeast(0L),
            "durationMs" to player.duration.takeIf { it != C.TIME_UNSET }?.coerceAtLeast(0L),
            "isPlaying" to player.isPlaying,
            "playWhenReady" to player.playWhenReady,
            "playbackState" to player.playbackState,
            "mediaItemIndex" to player.currentMediaItemIndex,
            "mediaItemCount" to player.mediaItemCount,
            "volume" to player.volume,
            "speed" to player.playbackParameters.speed,
            "pitch" to player.playbackParameters.pitch,
            "audioSessionId" to player.audioSessionId,
        )
    }

    private var isDestroyed = false

    override fun onDestroy() {
        isDestroyed = true
        cancelCrossfade()
        mainHandler.removeCallbacksAndMessages(null)
        mediaSession?.release()
        mediaSession = null
        DspEngineSinkHook.suspendDeck("A")
        DspEngineSinkHook.suspendDeck("B")
        if (::activePlayer.isInitialized) activePlayer.release()
        standbyPlayer?.release()
        standbyPlayer = null
        DspEngineSinkHook.forgetDeck("A")
        DspEngineSinkHook.forgetDeck("B")
        auxiliaryPlayer?.release()
        auxiliaryPlayer = null
        stopTransitionPreview()
        previewOutgoingPlayer?.release()
        previewIncomingPlayer?.release()
        previewOutgoingPlayer = null
        previewIncomingPlayer = null
        DspEngineSinkHook.forgetDeck("preview_out")
        DspEngineSinkHook.forgetDeck("preview_in")
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var instance: Media3PlaybackService? = null
            private set
    }
}