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
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.aetherion.resonate.dsp.DspEngineSinkHook
import com.aetherion.resonate.dsp.DspEngineRegistry
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Media3 playback service with active/standby decks. The provider owns the
 * production handoff while this service owns native transport, MediaSession,
 * DSP and equal-power crossfade execution.
 */
class Media3PlaybackService : MediaSessionService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaSession: MediaSession? = null
    private lateinit var activePlayer: ExoPlayer
    private lateinit var standbyPlayer: ExoPlayer
    // Short DJ samples are mixed by a service-owned player. It has no MediaSession
    // and never requests focus, so the canonical queue remains the sole transport owner.
    private var auxiliaryPlayer: ExoPlayer? = null
    private var auxiliaryBaseVolume = 0f
    private var fadeRunnable: Runnable? = null
    private var fadeGeneration = 0
    private val crossfadeClock = Media3CrossfadeClock()
    private var crossfadeStatus = "idle"
    private var pendingCrossfadeDurationMs: Long? = null
    // The ramp is deliberately not started until the incoming deck reports
    // isPlaying. ExoPlayer's play() request can precede audible output startup.
    private var startingCrossfadeDurationMs: Long? = null
    private var activeDeckId = "A"
    // ExoPlayer focus handling is opt-in at the migration boundary. The legacy
    // audio_session owner remains untouched until an explicit provider cutover.
    // Focus is acquired only after an explicit play request. Creating or
    // connecting the service must never interrupt another app.
    private var media3AudioFocusEnabled = false

    // All Media3 output gain changes pass through one policy. Future leveling,
    // preamp, sleep fade and focus-duck factors belong in this composition point.
    private val gainPolicy = Media3GainPolicy()

    private fun applyDeckVolumes() {
        if (::activePlayer.isInitialized) activePlayer.volume = gainPolicy.activeVolume()
        if (::standbyPlayer.isInitialized) standbyPlayer.volume = gainPolicy.standbyVolume()
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

    /** Current deck session for session-bound DSP/effects attachment. */
    fun activeAudioSessionId(): Int =
        if (::activePlayer.isInitialized) activePlayer.audioSessionId else 0

    /** Session of the prepared standby deck, for session-bound Android effects. */
    fun standbyAudioSessionId(): Int =
        if (::standbyPlayer.isInitialized && standbyPlayer.mediaItemCount > 0) {
            standbyPlayer.audioSessionId
        } else {
            0
        }

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
        if (::standbyPlayer.isInitialized) {
            standbyPlayer.setAudioAttributes(
                audioAttributes(),
                AudioOutputPolicy.handlesAudioFocus(
                    isCanonicalActiveDeck = false,
                    focusHandlingEnabled = enabled,
                ),
            )
        }
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
        standbyPlayer.repeatMode = mode
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
    fun setDeckPlaybackSpeeds(active: Float, standby: Float): Boolean {
        if (!active.isFinite() || active !in 0.5f..2.0f ||
            !standby.isFinite() || standby !in 0.5f..2.0f
        ) return false
        activePlayer.playbackParameters = PlaybackParameters(active)
        standbyPlayer.playbackParameters = PlaybackParameters(standby)
        return true
    }

    fun setShuffleMode(enabled: Boolean): Boolean {
        activePlayer.shuffleModeEnabled = enabled
        standbyPlayer.shuffleModeEnabled = enabled
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
        standbyPlayer = newPlayer(handleAudioFocus = false, deckId = "B")
        activeDeckId = "A"
        DspEngineRegistry.setActiveDeck(activeDeckId)
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
                if (!::standbyPlayer.isInitialized || deck !== standbyPlayer ||
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
                if (::standbyPlayer.isInitialized && deck === standbyPlayer) {
                    pendingCrossfadeDurationMs = null
                    startingCrossfadeDurationMs = null
                    crossfadeStatus = "incoming_error"
                }
            }

            override fun onMediaItemTransition(
                mediaItem: MediaItem?,
                reason: Int,
            ) {
                // MediaSession controllers (headsets, Bluetooth, notification,
                // Android Auto) can navigate the active playlist without going
                // through the Flutter command lane. Invalidate any preloaded
                // incoming deck on those transitions so an old crossfade can
                // never promote stale queue content over the user's selection.
                if (deck === activePlayer) {
                    clearPreload()
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
                // Never allow a deck to continue output in call/VoIP mode.
                if (playWhenReady && isCommunicationActive()) {
                    deck.pause()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!::activePlayer.isInitialized || !::standbyPlayer.isInitialized) return
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
                    standbyPlayer.pause()
                    crossfadeStatus = "ready"
                    return
                }
                // A fade requested while the standby deck is preparing waits
                // for both decks to be runnable. Preserve that request across
                // transient focus/buffering pauses and start it on resume.
                if (crossfadeStatus == "waiting_ready" || crossfadeStatus == "ready") {
                    val pendingDuration = pendingCrossfadeDurationMs
                    if (isPlaying && pendingDuration != null &&
                        ::standbyPlayer.isInitialized &&
                        standbyPlayer.playbackState == Player.STATE_READY
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
        if (!::standbyPlayer.isInitialized || items.isEmpty() ||
            startIndex !in items.indices || startPositionMs < 0L ||
            items.any { it.localConfiguration?.uri == null }
        ) return false
        cancelCrossfade()
        gainPolicy.setCrossfadeGains(active = 1f, standby = 0f)
        applyDeckVolumes()
        // Keep the complete queue and transport policy on the standby deck.
        // After the deck swap, next/previous/repeat continue to work without
        // reconstructing the playlist mid-playback or reloading the incoming track.
        standbyPlayer.repeatMode = activePlayer.repeatMode
        standbyPlayer.shuffleModeEnabled = activePlayer.shuffleModeEnabled
        // Start from the active deck's baseline; DJ analysis may then apply an
        // independent standby correction through setDeckPlaybackSpeeds().
        standbyPlayer.playbackParameters = activePlayer.playbackParameters
        standbyPlayer.setMediaItems(items, startIndex, startPositionMs)
        standbyPlayer.prepare()
        crossfadeStatus = "preparing"
        return true
    }

    /**
     * Starts a cancellable gain ramp. Equal-power curves avoid the large perceived
     * dip of a linear crossfade. Calls are main-thread serialized by the bridge.
     */
    fun startCrossfade(durationMs: Long): Boolean {
        if (durationMs !in 250L..15000L) return false
        if (standbyPlayer.mediaItemCount == 0) {
            crossfadeStatus = "incoming_not_ready"
            return false
        }
        if (!activePlayer.isPlaying ||
            standbyPlayer.playbackState != Player.STATE_READY
        ) {
            if (standbyPlayer.playbackState != Player.STATE_READY &&
                standbyPlayer.playbackState != Player.STATE_BUFFERING &&
                standbyPlayer.playbackState != Player.STATE_IDLE
            ) {
                crossfadeStatus = "incoming_not_ready"
                return false
            }
            pendingCrossfadeDurationMs = durationMs
            crossfadeStatus = if (standbyPlayer.playbackState == Player.STATE_READY) {
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
        if (durationMs !in 250L..15000L || !activePlayer.isPlaying ||
            standbyPlayer.mediaItemCount == 0 ||
            standbyPlayer.playbackState != Player.STATE_READY
        ) return false
        pendingCrossfadeDurationMs = null
        cancelCrossfade(clearOverlays = false, resetStandbySpeed = false)
        val generation = ++fadeGeneration
        startingCrossfadeDurationMs = durationMs
        crossfadeStatus = "starting"
        gainPolicy.resetDecks()
        applyDeckVolumes()
        standbyPlayer.play()
        // isPlaying may already be true for an immediately-starting local
        // source. Handle that synchronously as well as through the listener.
        if (standbyPlayer.isPlaying) {
            startCrossfadeRamp(durationMs, generation)
        }
        return true
    }

    /** Begin the gain ramp only after both decks are producing playback. */
    private fun startCrossfadeRamp(durationMs: Long, generation: Int) {
        if (generation != fadeGeneration || isDestroyed ||
            crossfadeStatus != "starting" || !activePlayer.isPlaying ||
            !standbyPlayer.isPlaying
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
                    val oldPlayer = activePlayer
                    activePlayer = standbyPlayer
                    standbyPlayer = oldPlayer
                    activeDeckId = if (activeDeckId == "A") "B" else "A"
                    DspEngineRegistry.setActiveDeck(activeDeckId)
                    DspEngineRegistry.clearAllTemporaryEqOverlays()
                    // The promoted deck keeps its transition rate. Reset the
                    // now-standby deck so the next preload starts from the new
                    // active rate rather than a stale outgoing correction.
                    standbyPlayer.playbackParameters = activePlayer.playbackParameters
                    oldPlayer.setAudioAttributes(
                        audioAttributes(),
                        AudioOutputPolicy.handlesAudioFocus(
                            isCanonicalActiveDeck = false,
                            focusHandlingEnabled = media3AudioFocusEnabled,
                        ),
                    )
                    oldPlayer.setHandleAudioBecomingNoisy(false)
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
                    mediaSession?.setPlayer(activePlayer)
                    gainPolicy.resetDecks()
                    applyDeckVolumes()
                    standbyPlayer.pause()
                    standbyPlayer.clearMediaItems()
                    crossfadeStatus = "completed"
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
            standbyPlayer.pause()
            crossfadeStatus = "ready"
            return true
        }
        if (crossfadeStatus == "waiting_ready" || crossfadeStatus == "ready") {
            standbyPlayer.pause()
            // Keep waiting_ready while preparation is incomplete. The standby
            // readiness listener must remain armed so it can finish the
            // deferred transition after a pause/resume cycle.
            return true
        }
        if (crossfadeStatus != "fading") return false
        if (!crossfadeClock.pause(android.os.SystemClock.elapsedRealtime())) return false
        fadeRunnable?.let(mainHandler::removeCallbacks)
        standbyPlayer.pause()
        return true
    }

    /** Resume both decks from the exact gain-ramp position at which they paused. */
    fun resumeCrossfade(): Boolean {
        if (crossfadeStatus != "fading" || fadeRunnable == null) return false
        if (!crossfadeClock.resume(android.os.SystemClock.elapsedRealtime())) return false
        standbyPlayer.play()
        mainHandler.post(fadeRunnable!!)
        return true
    }

    /**
     * Invalidates the standby deck when the active source or queue is replaced.
     * Without this, a later crossfade could promote a track from an obsolete queue.
     */
    fun clearPreload(): Boolean {
        if (!::activePlayer.isInitialized || !::standbyPlayer.isInitialized) return false
        pendingCrossfadeDurationMs = null
        cancelCrossfade()
        standbyPlayer.pause()
        standbyPlayer.clearMediaItems()
        crossfadeStatus = "idle"
        return true
    }

    fun cancelCrossfade(
        clearOverlays: Boolean = true,
        resetStandbySpeed: Boolean = true,
    ): Boolean {
        pendingCrossfadeDurationMs = null
        startingCrossfadeDurationMs = null
        fadeGeneration++
        if (clearOverlays) DspEngineRegistry.clearAllTemporaryEqOverlays()
        fadeRunnable?.let(mainHandler::removeCallbacks)
        fadeRunnable = null
        crossfadeClock.reset()
        if (::activePlayer.isInitialized && ::standbyPlayer.isInitialized) {
            // Cancellation preserves the current deck; the incoming deck is silenced
            // and paused so a second request cannot leave two audible players.
            gainPolicy.resetDecks()
            applyDeckVolumes()
            standbyPlayer.pause()
            if (resetStandbySpeed) {
                standbyPlayer.playbackParameters = activePlayer.playbackParameters
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
        "activeMediaId" to activePlayer.currentMediaItem?.mediaId,
        "incomingReady" to (standbyPlayer.playbackState == Player.STATE_READY),
        "activePositionMs" to activePlayer.currentPosition.coerceAtLeast(0L),
        "incomingPositionMs" to standbyPlayer.currentPosition.coerceAtLeast(0L),
        "activeVolume" to activePlayer.volume,
        "incomingVolume" to standbyPlayer.volume,
    )

    private var isDestroyed = false

    override fun onDestroy() {
        isDestroyed = true
        cancelCrossfade()
        mainHandler.removeCallbacksAndMessages(null)
        mediaSession?.release()
        mediaSession = null
        if (::activePlayer.isInitialized) activePlayer.release()
        if (::standbyPlayer.isInitialized) standbyPlayer.release()
        auxiliaryPlayer?.release()
        auxiliaryPlayer = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var instance: Media3PlaybackService? = null
            private set
    }
}