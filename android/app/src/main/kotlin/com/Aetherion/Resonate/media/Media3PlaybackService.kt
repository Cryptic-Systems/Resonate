package com.Aetherion.Resonate.media

import android.content.Context
import android.net.Uri
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.PlayerMessage
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.aetherion.resonate.dsp.DspEngineSinkHook
import com.aetherion.resonate.dsp.DjScratchTimestampLedger
import com.aetherion.resonate.dsp.DjScratchControlMailbox
import com.aetherion.resonate.dsp.DjScratchSpeedMapping
import com.aetherion.resonate.dsp.DjScratchOutputRouteGeneration
import com.aetherion.resonate.dsp.DjScratchReleaseTailOwnership
import com.aetherion.resonate.dsp.DspEngineRegistry
import com.Aetherion.Resonate.R
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import java.util.concurrent.ConcurrentHashMap

// Manual scratch must remain unavailable until the PCM/media-clock handoff is complete.
private const val ENABLE_DJ_SCRATCH_AUDIO = false

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
    private var crossfadeResumePending = false
    // A cancelled audible fade restores outgoing gain through a guarded envelope.
    private var cancelRestoreRunnable: Runnable? = null
    private var cancelRestoreGeneration = 0
    private var lastCrossfadeInterruptionReason: String? = null
    private var lastCrossfadeInterruptionProgress: Float? = null
    private var lastCrossfadeInterruptionElapsedRealtimeMs: Long = 0L
    private var lastCrossfadeInterruptionActivePositionMs: Long = 0L
    private var lastCrossfadeInterruptionIncomingPositionMs: Long = 0L
    private val crossfadeClock = Media3CrossfadeClock()
    private var crossfadeStatus = "idle"
    private var pendingCrossfadeDurationMs: Long? = null
    // The ramp is deliberately not started until the incoming deck reports
    // isPlaying. ExoPlayer's play() request can precede audible output startup.
    private var startingCrossfadeDurationMs: Long? = null
    private var activeDeckId = "A"
    private var djDualDeckMode = false
    private var djCrossfaderPosition = 0.5f
    private var djDeckGainA = 1f
    private var djDeckGainB = 1f
    private var suppressDjPeerPauseDeckId: String? = null

    private data class DjLoopState(
        val expectedMediaId: String,
        val range: Media3DjLoopRange,
        var boundaryMessage: PlayerMessage? = null,
    )

    // Loop state follows physical A/B identity across canonical deck promotion.
    private val djLoops = mutableMapOf<String, DjLoopState>()
    // Mailboxes follow physical A/B identity across canonical-player promotion.
    private val djScratchMailboxes = mapOf(
        "A" to DjScratchControlMailbox(),
        "B" to DjScratchControlMailbox(),
    )
    // The sink playback-head clock is the only permitted source for a future
    // release-tail splice boundary; ExoPlayer currentPosition may be decoder-ahead.
    private val timestampedSinksByDeck = ConcurrentHashMap<String, TimestampedDjAudioSink>()
    private val scratchOutputRouteGeneration = DjScratchOutputRouteGeneration()
    private val scratchAudioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            scratchOutputRouteGeneration.onOutputDevicesChanged()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            scratchOutputRouteGeneration.onOutputDevicesChanged()
        }
    }
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
            "scratchOutputRouteGeneration" to scratchOutputRouteGeneration.snapshot(),
            "scratchOutputContractA" to scratchOutputContract("A")?.let { contract ->
                mapOf("sampleRate" to contract.sampleRate, "channelCount" to contract.channelCount,
                    "pcmEncoding" to contract.pcmEncoding, "audioSessionId" to contract.audioSessionId,
                    "routeGeneration" to contract.routeGeneration, "processingChainId" to contract.processingChainId)
            },
            "scratchOutputContractB" to scratchOutputContract("B")?.let { contract ->
                mapOf("sampleRate" to contract.sampleRate, "channelCount" to contract.channelCount,
                    "pcmEncoding" to contract.pcmEncoding, "audioSessionId" to contract.audioSessionId,
                    "routeGeneration" to contract.routeGeneration, "processingChainId" to contract.processingChainId)
            },
            "scratchActualRouteA" to scratchActualOutputRoute("A")?.let { route ->
                mapOf("routeDeviceId" to route.routeDeviceId, "audioSessionId" to route.audioSessionId,
                    "sampleRate" to route.sampleRate, "channelCount" to route.channelCount,
                    "pcmEncoding" to route.pcmEncoding, "tunneling" to route.tunneling, "offload" to route.offload)
            },
            "scratchActualRouteB" to scratchActualOutputRoute("B")?.let { route ->
                mapOf("routeDeviceId" to route.routeDeviceId, "audioSessionId" to route.audioSessionId,
                    "sampleRate" to route.sampleRate, "channelCount" to route.channelCount,
                    "pcmEncoding" to route.pcmEncoding, "tunneling" to route.tunneling, "offload" to route.offload)
            },
            "scratchAudibleMediaTimeUsA" to scratchAudibleMediaPositionUs("A"),
            "scratchAudibleMediaTimeUsB" to scratchAudibleMediaPositionUs("B"),
            "scratchDeckA" to DspEngineSinkHook.scratchDiagnostics("A"),
            "scratchDeckB" to DspEngineSinkHook.scratchDiagnostics("B"),
        )
    }

    /** Actual AudioTrack route for a physical deck; null until Android resolves it. */
    internal fun scratchActualOutputRoute(deckId: String): DjScratchAudioTrackRoute.Snapshot? =
        if (deckId == "A" || deckId == "B") timestampedSinksByDeck[deckId]?.actualOutputRoute() else null

    /** Media3 playback-head media time for a physical deck; null until the sink clock is valid. */
    internal fun scratchAudibleMediaPositionUs(deckId: String): Long? =
        if (deckId == "A" || deckId == "B") {
            timestampedSinksByDeck[deckId]?.audibleMediaPositionUs()
        } else {
            null
        }

    /**
     * Candidate contract for the post-DSP PCM handoff. Its PCM format describes
     * the processor boundary; a renderer must still verify the actual AudioTrack
     * output route/format before accepting the transferred tail.
     */
    internal fun scratchOutputContract(deckId: String): DjScratchReleaseTailOwnership.OutputContract? {
        if (deckId != "A" && deckId != "B") return null
        val player = when {
            !::activePlayer.isInitialized -> null
            deckId == activeDeckId -> activePlayer
            deckId == standbyDeckId() -> standbyPlayer
            else -> null
        } ?: return null
        val format = DspEngineSinkHook.releaseTailPcmFormat(deckId) ?: return null
        val sessionId = player.audioSessionId
        if (sessionId <= 0) return null
        return DjScratchReleaseTailOwnership.OutputContract(
            sampleRate = format.first,
            channelCount = format.second,
            pcmEncoding = C.ENCODING_PCM_16BIT,
            audioSessionId = sessionId,
            routeGeneration = scratchOutputRouteGeneration.snapshot(),
            processingChainId = "resonate-post-dsp-pcm16-v1",
        )
    }

    private fun applyDeckVolumes() {
        if (!::activePlayer.isInitialized) return
        val standby = standbyPlayer
        val transitionOwnsGain = crossfadeStatus == "starting" ||
            crossfadeStatus == "fading" || cancelRestoreRunnable != null
        if (djDualDeckMode && standby != null && !transitionOwnsGain) {
            val (deckAGain, deckBGain) = Media3DjCrossfaderPolicy.gainsForPosition(djCrossfaderPosition)
            val activeId = activeDeckId
            val standbyId = standbyDeckId()
            val activeGain = if (activeId == "A") deckAGain else deckBGain
            val standbyGain = if (standbyId == "A") deckAGain else deckBGain
            val activeChannelGain = if (activeId == "A") djDeckGainA else djDeckGainB
            val standbyChannelGain = if (standbyId == "A") djDeckGainA else djDeckGainB
            activePlayer.volume = gainPolicy.djDeckVolume(activeGain, activeChannelGain)
            standby.volume = gainPolicy.djDeckVolume(standbyGain, standbyChannelGain)
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
        djDeckGainA = 1f
        djDeckGainB = 1f
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
        // DJ channel EQ must never leak into the canonical Player after exit.
        if (!DspEngineRegistry.clearDjEqOverlay("A") ||
            !DspEngineRegistry.clearDjEqOverlay("B") ||
            !DspEngineRegistry.clearDjDeckFilter("A") ||
            !DspEngineRegistry.clearDjDeckFilter("B")) return false
        clearDjDeckLoopInternal("A")
        clearDjDeckLoopInternal("B")
        djScratchMailboxes.values.forEach { it.clear() }
        djDualDeckMode = false
        djDeckGainA = 1f
        djDeckGainB = 1f
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
        // Clearing the DJ queues suspends both physical DSP processors.
        // The canonical player survives mode exit, so explicitly reactivate its
        // processor even when it is already physical deck A. Without this,
        // returning to Player on A leaves playback in PCM pass-through and the
        // live DSP meter registry empty until the service is rebuilt.
        DspEngineRegistry.setActiveDeck(activeDeckId)
        DspEngineSinkHook.activateDeck(activeDeckId)
        cancelCrossfadeGainRestore()
        gainPolicy.resetDecks()
        applyDeckVolumes()
        crossfadeStatus = "idle"
        return true
    }

    /** Operator-owned physical A/B crossfader; automation never calls this. */
    fun setDjCrossfader(position: Float): Boolean {
        if (!::activePlayer.isInitialized || !djDualDeckMode) return false
        val standby = standbyPlayer
        if (!Media3DjCrossfaderPolicy.canApply(
                position = position,
                djDualDeckMode = djDualDeckMode,
                activeHasMedia = activePlayer.mediaItemCount > 0,
                standbyHasMedia = standby?.mediaItemCount?.let { it > 0 } == true,
                transitionOwnsGain = crossfadeStatus in setOf("starting", "fading"),
            )
        ) return false
        djCrossfaderPosition = position
        applyDeckVolumes()
        return true
    }

    /** Operator-owned channel gain (0 = mute, 1 = unity); independent of crossfader. */
    fun setDjDeckChannelGain(deckId: String, gain: Float): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            !gain.isFinite() || gain !in 0f..1f ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        if (deckId == "A") djDeckGainA = gain else djDeckGainB = gain
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
        // Manual deck promotion changes which physical deck owns the live
        // transport. Retire both platter commands before swapping player roles;
        // a drag cancelled by the UI must never keep scratching the old deck.
        djScratchMailboxes.values.forEach { it.clear() }
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
        clearDjDeckLoopInternal(deckId)
        djScratchMailboxes[deckId]?.clear()
        val peerDeckId = if (deckId == "A") "B" else "A"
        val peer = playerForPhysicalDeck(peerDeckId)
        return try {
            if (player === activePlayer && player.playWhenReady) {
                suppressDjPeerPauseDeckId = deckId
            }
            player.pause()
            player.stop()
            player.clearMediaItems()
            // Tempo/pitch belongs to the loaded track, not the physical deck.
            // A replacement track starts neutral without changing its partner.
            player.playbackParameters = Media3DeckPlaybackParametersPolicy.forNewTrack()
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
        if (target.mediaItemCount == 0 ||
            !Media3DeckTransportPolicy.canStart(target.playbackState)
        ) return false
        if (!promoteDjCanonicalDeck(deckId) || !setAudioFocusHandling(true)) return false
        val player = activePlayer
        DspEngineSinkHook.activateDeck(deckId)
        return try {
            if (Media3DeckTransportPolicy.shouldRestartFromBeginning(player.playbackState)) {
                player.seekTo(djLoops[deckId]?.range?.startMs ?: 0L)
            }
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
            djScratchMailboxes[deckId]?.snapshot()?.let { snapshot ->
                djScratchMailboxes[deckId]?.clear(snapshot.mediaId)
            }
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
        clearDjDeckLoopInternal(deckId)
        djScratchMailboxes[deckId]?.clear()
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
            djScratchMailboxes[deckId]?.snapshot()?.let { snapshot ->
                djScratchMailboxes[deckId]?.clear(snapshot.mediaId)
            }
            val loop = djLoops[deckId]
            if (loop != null && (positionMs < loop.range.startMs || positionMs >= loop.range.endMs)) {
                clearDjDeckLoopInternal(deckId)
            } else if (loop != null) {
                loop.boundaryMessage?.cancel()
                loop.boundaryMessage = null
            }
            player.seekTo(positionMs)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Publish validated platter control to the scratch renderer for one physical deck. */
    fun setDjScratchControl(
        deckId: String,
        expectedMediaId: String,
        active: Boolean,
        velocity: Double,
        anchorMediaTimeUs: Long,
    ): Boolean {
        if (!ENABLE_DJ_SCRATCH_AUDIO) return false
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            expectedMediaId.isBlank() || crossfadeStatus in setOf("starting", "fading")
        ) return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        if (player.mediaItemCount == 0 ||
            player.currentMediaItem?.mediaId != expectedMediaId ||
            !player.isPlaying || anchorMediaTimeUs < 0L
        ) return false
        val mailbox = djScratchMailboxes[deckId] ?: return false
        // This processor runs before Media3's Sonic/AudioTrack speed stage.
        // Compensate the cursor rate so downstream playback speed does not
        // multiply the operator's requested audible platter rate a second time.
        val cursorVelocity = if (active) {
            DjScratchSpeedMapping.cursorVelocity(
                platterVelocity = velocity,
                downstreamPlaybackSpeed = player.playbackParameters.speed,
            ) ?: return false
        } else {
            1.0
        }
        return mailbox.publish(
            mediaId = expectedMediaId,
            active = active,
            velocity = cursorVelocity,
            anchorMediaTimeUs = anchorMediaTimeUs,
        )
    }

    /** Activate a native A/B loop on the selected physical deck. */
    fun setDjDeckLoopRange(
        deckId: String,
        startMs: Long,
        endMs: Long,
        expectedMediaId: String,
    ): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            expectedMediaId.isBlank() || crossfadeStatus in setOf("starting", "fading")
        ) return false
        val player = playerForPhysicalDeck(deckId) ?: return false
        if (player.mediaItemCount == 0 ||
            player.currentMediaItem?.mediaId != expectedMediaId ||
            !player.isCurrentMediaItemSeekable
        ) return false
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0L }
        val range = Media3DjLoopPolicy.create(startMs, endMs, duration) ?: return false
        clearDjDeckLoopInternal(deckId)
        val loop = DjLoopState(expectedMediaId, range)
        djLoops[deckId] = loop
        if (player.currentPosition < range.startMs || player.currentPosition >= range.endMs) {
            player.seekTo(range.startMs)
        }
        armDjLoopBoundary(deckId, player, loop, allowPastEnd = false)
        return true
    }

    /** Disable and forget the selected physical deck's loop points. */
    fun clearDjDeckLoop(deckId: String): Boolean {
        if (!djDualDeckMode || deckId !in setOf("A", "B") ||
            crossfadeStatus in setOf("starting", "fading")
        ) return false
        clearDjDeckLoopInternal(deckId)
        return true
    }

    private fun clearDjDeckLoopInternal(deckId: String) {
        djLoops.remove(deckId)?.boundaryMessage?.cancel()
    }

    private fun armDjLoopBoundary(
        deckId: String,
        player: ExoPlayer,
        loop: DjLoopState,
        allowPastEnd: Boolean,
    ) {
        if (djLoops[deckId] !== loop || playerForPhysicalDeck(deckId) !== player ||
            player.currentMediaItem?.mediaId != loop.expectedMediaId ||
            player.currentMediaItemIndex < 0
        ) return
        if (player.currentPosition >= loop.range.endMs) {
            if (allowPastEnd && player.isPlaying) {
                player.seekTo(loop.range.startMs)
            }
            return
        }
        loop.boundaryMessage?.cancel()
        val target = object : PlayerMessage.Target {
            override fun handleMessage(messageType: Int, payload: Any?) {
                loop.boundaryMessage = null
                if (djLoops[deckId] !== loop ||
                    playerForPhysicalDeck(deckId) !== player ||
                    player.currentMediaItem?.mediaId != loop.expectedMediaId
                ) return
                if (!player.isPlaying) return
                if (Media3DjLoopPolicy.shouldWrap(
                        loopActive = true,
                        expectedMediaId = loop.expectedMediaId,
                        currentMediaId = player.currentMediaItem?.mediaId,
                        positionMs = player.currentPosition,
                        endMs = loop.range.endMs,
                    )
                ) {
                    // The player's seek-discontinuity callback re-arms the
                    // next native boundary after the playback thread accepts it.
                    player.seekTo(loop.range.startMs)
                } else {
                    armDjLoopBoundary(deckId, player, loop, allowPastEnd = true)
                }
            }
        }
        loop.boundaryMessage = player.createMessage(target)
            .setLooper(player.applicationLooper)
            .setPosition(player.currentMediaItemIndex, loop.range.endMs)
            .setDeleteAfterDelivery(true)
            .send()
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
    /**
     * Applies the operator-selected queue repeat policy to both physical A/B
     * players. Repeat One is a manual deck playback mode; it must not schedule
     * an automatic same-track DJ crossfade or promote the standby deck.
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

    /** Physical-deck DJ EQ; independent of active/standby transition overlays. */
    fun setDjDeckEq(deckId: String, centersHz: DoubleArray, gainsDb: DoubleArray): Boolean =
        djDualDeckMode && DspEngineRegistry.setDjEqOverlay(deckId, centersHz, gainsDb)

    fun clearDjDeckEq(deckId: String): Boolean =
        DspEngineRegistry.clearDjEqOverlay(deckId)

    /** Independent per-deck low-pass/high-pass filter; type 0 bypasses. */
    fun setDjDeckFilter(deckId: String, type: Int, cutoffHz: Double): Boolean =
        djDualDeckMode && DspEngineRegistry.setDjDeckFilter(deckId, type, cutoffHz)

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.registerAudioDeviceCallback(scratchAudioDeviceCallback, mainHandler)
        }
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
            ): AudioSink {
                val timestampLedger = DjScratchTimestampLedger()
                val outputRoute = DjScratchAudioTrackRoute()
                val delegate = DefaultAudioSink.Builder(context)
                    .setAudioTrackProvider(outputRoute.audioTrackProvider)
                    .setAudioProcessors(
                        DspEngineSinkHook.createProcessors(
                            deckId,
                            timestampLedger,
                            djScratchMailboxes[deckId] ?: DjScratchControlMailbox(),
                        ),
                    )
                    // Media3 1.5.1 omits the user AudioProcessor chain when
                    // float output is selected. Resonate's native DSP and the
                    // timestamp/PCM history stages require the PCM16 processor path.
                    .setEnableFloatOutput(false)
                    .setEnableAudioTrackPlaybackParams(enableAudioOutputPlaybackParams)
                    .build()
                return TimestampedDjAudioSink(delegate, timestampLedger, outputRoute).also { timestampedSinksByDeck[deckId] = it }
            }
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
            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                if (reason != Player.DISCONTINUITY_REASON_SEEK || !djDualDeckMode) return
                val physicalDeckId = when {
                    deck === activePlayer -> activeDeckId
                    deck === standbyPlayer -> standbyDeckId()
                    else -> null
                } ?: return
                djScratchMailboxes[physicalDeckId]?.snapshot()?.let { snapshot ->
                    djScratchMailboxes[physicalDeckId]?.clear(snapshot.mediaId)
                }
                val loop = djLoops[physicalDeckId] ?: return
                if (playerForPhysicalDeck(physicalDeckId) === deck &&
                    deck.currentMediaItem?.mediaId == loop.expectedMediaId
                ) {
                    armDjLoopBoundary(physicalDeckId, deck, loop, allowPastEnd = false)
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                // If the canonical DJ deck ends naturally while its physical
                // partner is already playing, hand MediaSession/focus ownership
                // to that audible deck. Do not do this for pause or buffering:
                // those states are handled by the operator/transport policies.
                if (djDualDeckMode && deck === activePlayer &&
                    playbackState == Player.STATE_ENDED
                ) {
                    val peerDeckId = standbyDeckId()
                    if (standbyPlayer?.isPlaying == true && !isCommunicationActive()) {
                        promoteDjCanonicalDeck(peerDeckId)
                        setAudioFocusHandling(true)
                    } else {
                        applyDeckVolumes()
                    }
                    return
                }
                // An incoming deck that reaches EOS during an audible fade
                // cannot be promoted. Invalidate the scheduled ramp immediately.
                if (deck === standbyPlayer &&
                    playbackState == Player.STATE_ENDED &&
                    crossfadeStatus in setOf("starting", "fading")
                ) {
                    abortIncomingCrossfade("incoming_ended_during_fade")
                    return
                }
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
                if (deck === standbyPlayer &&
                    crossfadeStatus in setOf(
                        "preparing", "waiting_ready", "ready", "starting", "fading",
                    )
                ) {
                    // Ignore late errors from a retired standby after promotion
                    // or cancellation; they no longer own the active transition.
                    abortIncomingCrossfade("incoming_player_error")
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
                    // A MediaItem transition retires platter ownership even when
                    // the next queue occurrence has the same mediaId (Repeat One,
                    // duplicate playlist entries, or a repeated URI). Media ID alone
                    // is not an occurrence identity, so never carry scratch velocity
                    // or its PCM cursor across this boundary.
                    djScratchMailboxes[physicalDeckId]?.clear()
                    val loop = djLoops[physicalDeckId]
                    if (loop != null && loop.expectedMediaId != mediaItem?.mediaId) {
                        clearDjDeckLoopInternal(physicalDeckId)
                    }
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

            override fun onPlaybackParametersChanged(playbackParameters: PlaybackParameters) {
                // The cursor rate is compensated against the playback speed
                // sampled when the platter command is published. Retire any
                // active command on a speed change; the next platter update
                // will be remapped against the new native speed readback.
                val physicalDeckId = when {
                    deck === activePlayer -> activeDeckId
                    deck === standbyPlayer -> standbyDeckId()
                    else -> null
                }
                if (physicalDeckId != null &&
                    djScratchMailboxes[physicalDeckId]?.snapshot()?.active == true
                ) {
                    djScratchMailboxes[physicalDeckId]?.clear()
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
                    djScratchMailboxes[deckId]?.clear()
                    if (isIndependentDeckPause) {
                        suppressDjPeerPauseDeckId = null
                    } else {
                        djScratchMailboxes[standbyDeckId()]?.clear()
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
                // In persistent DJ mode, either physical deck can start or
                // stop independently. Recompute physical A/B gains on both
                // callbacks so the surviving deck returns to unity when its
                // partner pauses, and the stored crossfader is restored when
                // the second deck becomes audible. A native transition owns
                // gain exclusively while starting/fading.
                if (djDualDeckMode) {
                    if (crossfadeStatus !in setOf("starting", "fading")) {
                        applyDeckVolumes()
                    }
                    if (isPlaying) {
                        val physicalDeckId = when {
                            deck === activePlayer -> activeDeckId
                            deck === standbyPlayer -> standbyDeckId()
                            else -> null
                        }
                        if (physicalDeckId != null) {
                            djLoops[physicalDeckId]?.let { loop ->
                                armDjLoopBoundary(physicalDeckId, deck, loop, allowPastEnd = true)
                            }
                        }
                    }
                    return
                }
                if (deck === standbyPlayer) {
                    // Do not attenuate the outgoing deck while ExoPlayer is
                    // still starting the incoming audio output. The fade clock
                    // begins only once the incoming deck is actually playing.
                    if (isPlaying && crossfadeStatus == "starting") {
                        val duration = startingCrossfadeDurationMs
                        if (duration != null && activePlayer.isPlaying) {
                            startCrossfadeRamp(duration, fadeGeneration)
                        }
                    } else if (crossfadeStatus == "fading" && isPlaying &&
                        crossfadeResumePending
                    ) {
                        // Resume the clock only when the incoming output is
                        // audible again; buffering after a pause cannot consume
                        // the remaining transition duration.
                        crossfadeResumePending = false
                        if (crossfadeClock.resume(android.os.SystemClock.elapsedRealtime())) {
                            fadeRunnable?.let(mainHandler::post)
                        }
                    } else if (crossfadeStatus == "fading" && !isPlaying &&
                        !crossfadeResumePending
                    ) {
                        // If only the incoming decoder buffers, freeze the
                        // envelope at its exact position until that output is
                        // audible again. The outgoing deck remains canonical.
                        recordCrossfadeInterruption("incoming_output_interrupted")
                        if (crossfadeClock.pause(android.os.SystemClock.elapsedRealtime())) {
                            crossfadeResumePending = true
                            fadeRunnable?.let(mainHandler::removeCallbacks)
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
        // cancelCrossfade may be completing a short outgoing-gain recovery
        // ramp. Preserve that live envelope when a rapid preload replaces standby.
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
        cancelCrossfade(
            clearOverlays = false,
            resetStandbySpeed = false,
            reason = "new_crossfade",
        )
        cancelCrossfadeGainRestore()
        gainPolicy.resetDecks()
        applyDeckVolumes()
        // A crossfade owns both outputs; release active platters through
        // their short native fade before either deck enters the transition.
        for (deckId in listOf("A", "B")) {
            val player = playerForPhysicalDeck(deckId)
            val mediaId = player?.currentMediaItem?.mediaId
            val mailbox = djScratchMailboxes[deckId] ?: continue
            if (player != null && !mediaId.isNullOrBlank()) {
                mailbox.publish(
                    mediaId = mediaId,
                    active = false,
                    velocity = 1.0,
                    anchorMediaTimeUs = player.currentPosition.coerceAtLeast(0L) * 1_000L,
                )
            } else {
                mailbox.clear()
            }
        }
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
        crossfadeResumePending = false
        crossfadeStatus = "fading"
        val task = object : Runnable {
            override fun run() {
                if (isDestroyed || !Media3CrossfadeEnvelope.shouldAdvanceRamp(
                        generationMatches = generation == fadeGeneration,
                        status = crossfadeStatus,
                    )
                ) return
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
                    // The final envelope tick has already driven this output to
                    // zero through Media3GainPolicy. Keep the composed gain owner
                    // authoritative while swapping the canonical player reference.
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
            recordCrossfadeInterruption("transport_pause")
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
        recordCrossfadeInterruption("transport_pause")
        crossfadeResumePending = false
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
        DspEngineSinkHook.activateDeck(standbyDeckId())
        crossfadeResumePending = true
        standby.play()
        // Local sources may resume synchronously. Otherwise the standby
        // isPlaying listener resumes the clock when audio output is ready.
        if (standby.isPlaying && crossfadeResumePending) {
            crossfadeResumePending = false
            if (crossfadeClock.resume(android.os.SystemClock.elapsedRealtime())) {
                mainHandler.post(fadeRunnable!!)
            }
        }
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
        cancelCrossfade(reason = reason)
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
        // Player selection can bypass the explicit DJ-mode exit action. Clear
        // all DJ-only processing before either physical deck returns to the
        // ordinary Player lifecycle.
        if (!DspEngineRegistry.clearDjEqOverlay("A") ||
            !DspEngineRegistry.clearDjEqOverlay("B") ||
            !DspEngineRegistry.clearDjDeckFilter("A") ||
            !DspEngineRegistry.clearDjDeckFilter("B")) return false
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
            if (djDualDeckMode) {
                val loop = djLoops[activeDeckId]
                if (loop != null &&
                    (positionMs < loop.range.startMs || positionMs >= loop.range.endMs)
                ) {
                    clearDjDeckLoopInternal(activeDeckId)
                }
            }
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

    private fun recordCrossfadeInterruption(reason: String, progress: Float? = null) {
        val now = android.os.SystemClock.elapsedRealtime()
        lastCrossfadeInterruptionReason = reason
        lastCrossfadeInterruptionProgress = progress ?: if (crossfadeStatus == "fading") {
            crossfadeClock.progress(now)
        } else {
            0f
        }
        lastCrossfadeInterruptionElapsedRealtimeMs = now
        lastCrossfadeInterruptionActivePositionMs =
            if (::activePlayer.isInitialized) activePlayer.currentPosition.coerceAtLeast(0L) else 0L
        lastCrossfadeInterruptionIncomingPositionMs =
            standbyPlayer?.currentPosition?.coerceAtLeast(0L) ?: 0L
    }

    private fun cancelCrossfadeGainRestore() {
        cancelRestoreGeneration++
        cancelRestoreRunnable?.let(mainHandler::removeCallbacks)
        cancelRestoreRunnable = null
    }

    private fun restoreOutgoingGainAfterCancellation(
        startProgress: Float,
        expectedPlayer: ExoPlayer,
        expectedDeckId: String,
    ) {
        cancelCrossfadeGainRestore()
        val generation = cancelRestoreGeneration
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val durationMs = 72L
        val task = object : Runnable {
            override fun run() {
                if (generation != cancelRestoreGeneration || isDestroyed) return
                // Never apply an old deck's recovery gain to a newly promoted
                // or newly selected canonical player.
                val ownsCanonicalDeck =
                    activePlayer === expectedPlayer && activeDeckId == expectedDeckId
                if (!Media3CrossfadeEnvelope.shouldRestoreCancelledGain(
                        generationMatches = generation == cancelRestoreGeneration,
                        canonicalDeckMatches = ownsCanonicalDeck,
                    )
                ) {
                    if (generation == cancelRestoreGeneration) {
                        cancelCrossfadeGainRestore()
                        gainPolicy.resetDecks()
                        applyDeckVolumes()
                    }
                    return
                }
                val elapsed = (android.os.SystemClock.elapsedRealtime() - startedAt)
                    .coerceAtLeast(0L)
                val fraction = (elapsed.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
                val progress = Media3CrossfadeEnvelope.restorationProgress(
                    startProgress = startProgress,
                    elapsedFraction = fraction,
                )
                val (activeGain, _) = Media3CrossfadeEnvelope.gains(progress)
                gainPolicy.setCrossfadeGains(active = activeGain, standby = 0f)
                applyDeckVolumes()
                if (fraction >= 1f) {
                    cancelRestoreRunnable = null
                    gainPolicy.resetDecks()
                    applyDeckVolumes()
                } else {
                    mainHandler.postDelayed(this, 16L)
                }
            }
        }
        cancelRestoreRunnable = task
        mainHandler.post(task)
    }

    private fun abortIncomingCrossfade(reason: String) {
        cancelCrossfade(reason = reason)
        // Keep the terminal failure visible to the provider recovery loop.
        crossfadeStatus = "incoming_error"
    }

    fun cancelCrossfade(
        clearOverlays: Boolean = true,
        resetStandbySpeed: Boolean = true,
        reason: String = "explicit_cancel",
    ): Boolean {
        val wasAudibleFade = crossfadeStatus == "fading"
        crossfadeResumePending = false
        val interruptedProgress = if (wasAudibleFade) {
            crossfadeClock.progress(android.os.SystemClock.elapsedRealtime())
        } else {
            0f
        }
        val restorePlayer = if (wasAudibleFade) activePlayer else null
        val restoreDeckId = if (restorePlayer != null) activeDeckId else null
        if (wasAudibleFade) recordCrossfadeInterruption(reason, interruptedProgress)
        stopTransitionPreview()
        pendingCrossfadeDurationMs = null
        startingCrossfadeDurationMs = null
        fadeGeneration++
        if (clearOverlays) DspEngineRegistry.clearAllTemporaryEqOverlays()
        fadeRunnable?.let(mainHandler::removeCallbacks)
        fadeRunnable = null
        crossfadeClock.reset()
        if (::activePlayer.isInitialized) {
            // Silence the incoming output first. During an audible fade, retain
            // the exact outgoing gain and restore it smoothly instead of jumping.
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
            if (wasAudibleFade && restorePlayer != null && restoreDeckId != null) {
                val (outgoingGain, _) = Media3CrossfadeEnvelope.gains(interruptedProgress)
                gainPolicy.setCrossfadeGains(active = outgoingGain, standby = 0f)
                restoreOutgoingGainAfterCancellation(
                    startProgress = interruptedProgress,
                    expectedPlayer = restorePlayer,
                    expectedDeckId = restoreDeckId,
                )
                // The restore runnable now owns gain composition, including
                // persistent A/B mode, until the canonical deck is back at unity.
                applyDeckVolumes()
            } else if (cancelRestoreRunnable == null) {
                gainPolicy.resetDecks()
                applyDeckVolumes()
            }
        }
        return true
    }

    fun crossfadeState(): Map<String, Any?> = mapOf(
        "status" to crossfadeStatus,
        "generation" to fadeGeneration,
        "lastInterruptionReason" to lastCrossfadeInterruptionReason,
        "lastInterruptionProgress" to lastCrossfadeInterruptionProgress,
        "lastInterruptionElapsedRealtimeMs" to lastCrossfadeInterruptionElapsedRealtimeMs,
        "lastInterruptionActivePositionMs" to lastCrossfadeInterruptionActivePositionMs,
        "lastInterruptionIncomingPositionMs" to lastCrossfadeInterruptionIncomingPositionMs,
        "gainRestoreInProgress" to (cancelRestoreRunnable != null),
        "resumePending" to crossfadeResumePending,
        "progress" to when (crossfadeStatus) {
            "fading" -> crossfadeClock.progress(android.os.SystemClock.elapsedRealtime())
            "completed" -> 1f
            else -> 0f
        },
        "activeDeckId" to activeDeckId,
        "djDualDeckMode" to djDualDeckMode,
        "djCrossfaderPosition" to djCrossfaderPosition,
        "djDeckGainA" to djDeckGainA,
        "djDeckGainB" to djDeckGainB,
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
            "channelGain" to if (deckId == "A") djDeckGainA else djDeckGainB,
            "speed" to player.playbackParameters.speed,
            "pitch" to player.playbackParameters.pitch,
            "audioSessionId" to player.audioSessionId,
            "loopActive" to (djLoops[deckId] != null),
            "loopStartMs" to djLoops[deckId]?.range?.startMs,
            "loopEndMs" to djLoops[deckId]?.range?.endMs,
        )
    }

    private var isDestroyed = false

    override fun onDestroy() {
        isDestroyed = true
        cancelCrossfade(reason = "service_destroyed")
        cancelCrossfadeGainRestore()
        djLoops.values.forEach { it.boundaryMessage?.cancel() }
        djLoops.clear()
        djScratchMailboxes.values.forEach { it.clear() }
        mainHandler.removeCallbacksAndMessages(null)
        // Clear process-local DJ EQ/filter state even if teardown bypassed the
        // normal mode-exit command. This prevents stale overlays from leaking
        // into the next Media3 service instance or ordinary Player session.
        DspEngineRegistry.resetDjDeckOverlaysForServiceTeardown()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.unregisterAudioDeviceCallback(scratchAudioDeviceCallback)
        }
        timestampedSinksByDeck.clear()
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