part of 'music_provider.dart';

/// Canonical provider integration for the injected Media3 session.
/// Every method here reads and writes the same session; just_audio is not a
/// fallback once the handoff has been committed.
extension MusicProviderMedia3 on MusicProvider {
  Future<void> _preloadNextForMedia3Crossfade() async {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive ||
        !effectiveCrossfadeEnabled || _crossfadePreloadInFlight ||
        (!canCrossfadeNext && !_crossfadeInProgress)) return;
    final next = _crossfadeTargetSong;
    final nextIndex = _crossfadeTargetIndex;
    final outgoing = currentSong;
    final outgoingIndex = _queueIndex;
    final alreadyPreparedForOccurrence =
        _preloadedNextSongId == next?.id &&
        _preloadedNextQueueIndex == nextIndex &&
        _preloadedNextPath == next?.filePath.trim() &&
        _preloadedOutgoingSongId == outgoing?.id &&
        _preloadedOutgoingQueueIndex == outgoingIndex &&
        _preloadedOutgoingPath == outgoing?.filePath.trim();
    if (next == null || outgoing == null || nextIndex < 0 ||
        alreadyPreparedForOccurrence) return;

    final generation = _automaticTransitionGeneration;
    final transportEpoch = _userTransportEpoch;
    final preloadGeneration = ++_media3PreloadGeneration;
    bool stillOwnsPreload() =>
        preloadGeneration == _media3PreloadGeneration &&
        generation == _automaticTransitionGeneration &&
        transportEpoch == _userTransportEpoch &&
        _media3ProviderSessionActive &&
        effectiveCrossfadeEnabled &&
        _queueIndex == outgoingIndex &&
        currentSong?.id == outgoing.id &&
        currentSong?.filePath.trim() == outgoing.filePath.trim() &&
        _crossfadeTargetSong?.id == next.id &&
        _crossfadeTargetSong?.filePath.trim() == next.filePath.trim() &&
        _crossfadeTargetIndex == nextIndex &&
        nextIndex < _queue.length &&
        _queue[nextIndex].id == next.id &&
        _queue[nextIndex].filePath.trim() == next.filePath.trim();
    _crossfadePreloadInFlight = true;
    try {
      if (_djAnalysis != null &&
          (_djBeatAlignActive || _djTempoMatchActive || _djSfxActive)) {
        _djAnalysis!.scheduleAnalyze(outgoing);
        _djAnalysis!.scheduleAnalyze(next);
        final start = _queueIndex + 1;
        final end = (start + 4).clamp(0, _queue.length);
        for (var i = start; i < end; i++) {
          if (i != nextIndex) _djAnalysis!.scheduleAnalyze(_queue[i]);
        }
      }

      final preparation = await _prepareMedia3DjHandoff(
        outgoingSong: outgoing,
        incomingSong: next,
        outgoingPositionMs: session.position.inMilliseconds,
      );
      if (!stillOwnsPreload()) return;
      await session.preloadNext(
        next,
        queueIndex: nextIndex,
        startPosition: preparation.incomingStartPosition,
      );
      if (!stillOwnsPreload()) return;
      await session.setDeckPlaybackSpeeds(
        activeSpeed: preparation.activeSpeed,
        standbySpeed: preparation.standbySpeed,
      );
      if (!stillOwnsPreload()) return;
      final bassDuckAmount = preparation.incomingBassDuckAmount;
      if (bassDuckAmount != null && bassDuckAmount > 0 && bassDuckAmount < 1) {
        // Convert the planner's linear attenuation into a bounded dB overlay
        // on the incoming deck only. It is removed halfway through the blend.
        final duckDb = 20 * math.log(1 - bassDuckAmount) / math.ln10;
        final boundedDuckDb = duckDb.clamp(-6.0, -1.0).toDouble();
        await session.setDeckEqOverlay(
          deck: 'standby',
          centersHz: const [60.0, 90.0, 120.0],
          gainsDb: List<double>.filled(3, boundedDuckDb),
        );
      }
      if (!stillOwnsPreload()) return;
      _media3DjTransitionPreparation = preparation;
      _preloadedNextSongId = next.id;
      _preloadedNextQueueIndex = nextIndex;
      _preloadedNextPath = next.filePath.trim();
      _preloadedOutgoingSongId = outgoing.id;
      _preloadedOutgoingQueueIndex = outgoingIndex;
      _preloadedOutgoingPath = outgoing.filePath.trim();
      final activeDeckId = _media3ShadowState?.activeDeckId ?? 'A';
      final standbyDeckId = activeDeckId == 'A' ? 'B' : 'A';
      unawaited(_applyMedia3DspAnalysisHint(
        song: next,
        deckId: standbyDeckId,
        standby: true,
      ));
      await ResonateDiagnostics.record('media3_crossfade_preloaded', {
        'outgoingSongId': outgoing.id,
        'incomingSongId': next.id,
        'outgoingQueueIndex': outgoingIndex,
        'incomingQueueIndex': nextIndex,
        'incomingStartMs': preparation.incomingStartPosition.inMilliseconds,
        'activeSpeed': preparation.activeSpeed,
        'standbySpeed': preparation.standbySpeed,
      });
    } catch (error) {
      if (stillOwnsPreload()) {
        _preloadedNextSongId = null;
        _media3DjTransitionPreparation = null;
        // A preload may fail after tempo matching has partially reached the
        // native decks. Treat overlay removal and speed restoration as
        // independent teardown operations so one native failure cannot leave
        // the standby deck at a DJ stretch rate.
        final cleanupErrors = <String>[];
        try {
          await session.clearDeckEqOverlay(deck: 'standby');
        } catch (cleanupError) {
          cleanupErrors.add('clear_standby_overlay: $cleanupError');
        }
        if (stillOwnsPreload()) {
          try {
            await session.setDeckPlaybackSpeeds(
              activeSpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
              standbySpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
            );
          } catch (cleanupError) {
            cleanupErrors.add('reset_deck_speeds: $cleanupError');
          }
        }
        await ResonateDiagnostics.record('media3_crossfade_preload_failed', {
          'songId': next.id,
          'error': error.toString(),
          'cleanupErrors': cleanupErrors,
        });
      }
    } finally {
      if (preloadGeneration == _media3PreloadGeneration) {
        _crossfadePreloadInFlight = false;
      }
      _drainPendingMedia3Completion();
    }
  }

  Future<void> _runMedia3AutomaticCrossfade() async {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) return;
    if (_transportInFlight || _loadingSource || _userTransportPending) {
      _automaticCrossfadeInFlight = false;
      _crossfadeInProgress = false;
      _transitionArmedAt = null;
      _drainPendingMedia3Completion();
      return;
    }
    final outgoingSong = currentSong;
    final outgoingIndex = _queueIndex;
    final nextSong = _crossfadeTargetSong;
    final nextIndex = _crossfadeTargetIndex;
    if (outgoingSong == null || nextSong == null || nextIndex < 0 ||
        !session.isPlaying) {
      _automaticCrossfadeInFlight = false;
      _crossfadeInProgress = false;
      _transitionArmedAt = null;
      _drainPendingMedia3Completion();
      return;
    }

    var transitionGeneration = _automaticTransitionGeneration;
    final controlLease = await playbackControlArbiter.acquire(
      owner: 'media3_automatic_crossfade',
      priority: PlaybackControlPriority.automatic,
      onRevoked: (revocation) => _onPlaybackControlLeaseRevoked(
        transitionGeneration: transitionGeneration,
        revocation: revocation,
      ),
    );
    if (controlLease == null) {
      _automaticCrossfadeInFlight = false;
      _crossfadeInProgress = false;
      _transitionArmedAt = null;
      _drainPendingMedia3Completion();
      return;
    }
    final generation = _authority.beginAutomatic('media3_automatic_crossfade');
    transitionGeneration = ++_automaticTransitionGeneration;
    final transportEpoch = _userTransportEpoch;
    final outgoingDeckId = _media3ShadowState?.activeDeckId ?? 'A';
    bool stillOwnsTransition() =>
        controlLease.isCurrent &&
        _media3ProviderSessionActive &&
        !_disposed &&
        _userWantsPlaying &&
        !_recentlyUserPaused &&
        transportEpoch == _userTransportEpoch &&
        transitionGeneration == _automaticTransitionGeneration &&
        !_authority.isStale(generation) &&
        !_transportInFlight &&
        !_userTransportPending;
    bool targetOccurrenceIsCurrent() =>
        _queueIndex == outgoingIndex &&
        currentSong?.id == outgoingSong.id &&
        currentSong?.filePath.trim() == outgoingSong.filePath.trim() &&
        _crossfadeTargetSong?.id == nextSong.id &&
        _crossfadeTargetSong?.filePath.trim() == nextSong.filePath.trim() &&
        _crossfadeTargetIndex == nextIndex &&
        nextIndex < _queue.length &&
        _queue[nextIndex].id == nextSong.id &&
        _queue[nextIndex].filePath.trim() == nextSong.filePath.trim();
    bool preloadMatchesTargetOccurrence() =>
        _preloadedNextSongId == nextSong.id &&
        _preloadedNextQueueIndex == nextIndex &&
        _preloadedNextPath == nextSong.filePath.trim() &&
        _preloadedOutgoingSongId == outgoingSong.id &&
        _preloadedOutgoingQueueIndex == outgoingIndex &&
        _preloadedOutgoingPath == outgoingSong.filePath.trim();

    _crossfadeInProgress = true;
    _transitionArmedAt = DateTime.now();
    Duration? incomingPositionAtPromotion;
    try {
      // A preload can still be decoding when the end-window trigger arrives.
      // Wait for the in-flight session command rather than racing a second
      // standby replacement against it.
      for (var wait = 0; _crossfadePreloadInFlight && wait < 80; wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!stillOwnsTransition()) return;
      }
      if (_crossfadePreloadInFlight) {
        // A slow local decoder is not a failed preload. Replacing the active
        // queue here would stop the outgoing track while the standby deck is
        // still preparing, which is especially audible at a reviewed phrase
        // boundary. Leave playback untouched; the next position tick will
        // retry once the in-flight preload has either completed or failed.
        await ResonateDiagnostics.recordDj(
          stage: 'media3_preload',
          outcome: 'deferred_still_preparing',
          reason: 'standby_preload_exceeded_transition_wait_window',
          songId: nextSong.id,
          extra: {
            'waitWindowMs': 2000,
            'positionMs': session.position.inMilliseconds,
            'remainingMs': session.duration == null
                ? null
                : session.duration!.inMilliseconds -
                    session.position.inMilliseconds,
          },
        );
        return;
      }
      var preparation = _media3DjTransitionPreparation;
      if (!preloadMatchesTargetOccurrence() || preparation == null) {
        await _preloadNextForMedia3Crossfade();
        preparation = _media3DjTransitionPreparation;
      }
      if (!stillOwnsTransition()) return;
      if (!preloadMatchesTargetOccurrence()) {
        // A failed standby decode is not permission to interrupt the active
        // track with a queue reload. Clean up the unused deck and let Media3's
        // canonical queue completion advance gaplessly when the outgoing item
        // ends. The next track remains selected in the native queue.
        await session.cancelCrossfade();
        if (!stillOwnsTransition()) return;
        await session.clearDeckEqOverlay(deck: 'standby');
        if (!stillOwnsTransition()) return;
        await session.setDeckPlaybackSpeeds(
          activeSpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
          standbySpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
        );
        if (!stillOwnsTransition()) return;
        _crossfadeRuntime.deferTransition(
          outgoingSongId: outgoingSong.id,
          outgoingQueueIndex: outgoingIndex,
          outgoingPath: outgoingSong.filePath.trim(),
          incomingSongId: nextSong.id,
          incomingQueueIndex: nextIndex,
          incomingPath: nextSong.filePath.trim(),
        );
        _preloadedNextSongId = null;
        _media3DjTransitionPreparation = null;
        await ResonateDiagnostics.recordDj(
          stage: 'media3_preload',
          outcome: 'deferred_to_gapless_completion',
          reason: 'standby_preload_failed',
          songId: nextSong.id,
          extra: {
            'outgoingSongId': outgoingSong.id,
            'queueIndex': nextIndex,
            'positionMs': session.position.inMilliseconds,
          },
        );
        return;
      }

      final djActive = _djHandoffsLive;
      final plannedDurationMs = preparation?.transitionDurationMs;
      final plannedCueMs =
          preparation?.outgoingStartPosition?.inMilliseconds;
      var hasPlannedCue = false;

      // A selected outgoing mix point is a time on the outgoing deck, not permission
      // to start the fade immediately. Wait for that musical boundary while
      // playback continues. If it cannot be reached in a bounded window, use
      // the ordinary safe fade.
      if (plannedCueMs != null) {
        final initialPositionMs = session.position.inMilliseconds;
        if (plannedCueMs >= initialPositionMs - 250) {
          final cueWait = Stopwatch()..start();
          while (session.position.inMilliseconds + 80 < plannedCueMs) {
            if (!stillOwnsTransition() ||
                !session.isPlaying ||
                session.currentSong?.id != outgoingSong.id ||
                session.queueIndex != _queueIndex ||
                _crossfadeTargetSong?.id != nextSong.id ||
                _crossfadeTargetIndex != nextIndex) {
              await ResonateDiagnostics.recordDj(
                stage: 'media3_transition_cue',
                outcome: 'cancelled_before_cue',
                reason: 'playback_or_queue_ownership_changed',
                songId: nextSong.id,
                extra: {'cueMs': plannedCueMs},
              );
              return;
            }
            if (cueWait.elapsed >= const Duration(seconds: 20)) break;
            await Future<void>.delayed(const Duration(milliseconds: 24));
          }
          hasPlannedCue =
              session.position.inMilliseconds + 250 >= plannedCueMs;
          await ResonateDiagnostics.recordDj(
            stage: 'media3_transition_cue',
            outcome: hasPlannedCue ? 'reached' : 'wait_window_expired',
            reason: hasPlannedCue
                ? 'outgoing_mix_point_reached'
                : 'cue_not_reached_in_time',
            songId: nextSong.id,
            extra: {
              'cueMs': plannedCueMs,
              'positionMs': session.position.inMilliseconds,
              'waitMs': cueWait.elapsedMilliseconds,
            },
          );
        } else {
          await ResonateDiagnostics.recordDj(
            stage: 'media3_transition_cue',
            outcome: 'stale',
            reason: 'outgoing_mix_point_already_passed',
            songId: nextSong.id,
            extra: {
              'cueMs': plannedCueMs,
              'positionMs': initialPositionMs,
            },
          );
        }
      }

      final effectivePlannedDurationMs =
          hasPlannedCue ? plannedDurationMs : null;
      final configuredDurationMs = effectivePlannedDurationMs != null
          ? effectivePlannedDurationMs.clamp(2000, 15000).toInt()
          : (djActive
                  ? (_crossfadeDurationMs + _lastDjCrossfadeBiasMs).clamp(500, 6500)
                  : _crossfadeDurationMs.clamp(500, 12000))
              .toInt();
      final remainingMs = session.duration == null
          ? null
          : session.duration!.inMilliseconds - session.position.inMilliseconds;
      if (remainingMs == null) {
        throw StateError('Media3 crossfade trigger has no validated duration.');
      }
      if (remainingMs < 1200) {
        // A standby deck that finishes preparing too close to the outgoing
        // track's end must not force a queue reload. Let the canonical Media3
        // queue completion path advance naturally; tear down only the unused
        // transition resources and leave the active deck untouched.
        await session.cancelCrossfade();
        if (!stillOwnsTransition()) return;
        await session.clearDeckEqOverlay(deck: 'standby');
        if (!stillOwnsTransition()) return;
        await session.setDeckPlaybackSpeeds(
          activeSpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
          standbySpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
        );
        if (!stillOwnsTransition()) return;
        _crossfadeRuntime.deferTransition(
          outgoingSongId: outgoingSong.id,
          outgoingQueueIndex: outgoingIndex,
          outgoingPath: outgoingSong.filePath.trim(),
          incomingSongId: nextSong.id,
          incomingQueueIndex: nextIndex,
          incomingPath: nextSong.filePath.trim(),
        );
        _preloadedNextSongId = null;
        _media3DjTransitionPreparation = null;
        await ResonateDiagnostics.recordDj(
          stage: 'media3_crossfade',
          outcome: 'deferred_to_gapless_completion',
          reason: 'standby_ready_inside_unsafe_fade_tail',
          songId: nextSong.id,
          extra: {
            'remainingMs': remainingMs,
            'minimumFadeWindowMs': 1200,
          },
        );
        return;
      }
      if (!hasPlannedCue && remainingMs > configuredDurationMs + 4500) {
        if (plannedCueMs != null) {
          // A reviewed cue that is stale or not yet reached must never turn
          // into an immediate queue advance. Leave the outgoing deck playing
          // and let the normal end-window trigger retry with a safe crossfade.
          await ResonateDiagnostics.recordDj(
            stage: 'media3_transition_cue',
            outcome: 'deferred_to_safe_crossfade',
            reason: 'phrase_boundary_not_executable_yet',
            songId: nextSong.id,
            extra: {
              'cueMs': plannedCueMs,
              'positionMs': session.position.inMilliseconds,
              'remainingMs': remainingMs,
            },
          );
          return;
        }
        throw StateError('Media3 crossfade trigger is outside the validated end window.');
      }
      // Never let the outgoing deck reach ENDED before the native fade can
      // promote the prepared deck. Keep the small tail guard used by the
      // previous provider-owned crossfade implementation.
      final durationMs = remainingMs < configuredDurationMs
          ? (remainingMs - 150).clamp(500, configuredDurationMs).toInt()
          : configuredDurationMs;

      // Media3GainPolicy is the only output-gain owner for this session.
      // Refresh its composed factors from current provider state; never flatten
      // them into a stale setVolume snapshot around the native fade.
      await _applyActiveMasterVolume();
      if (!stillOwnsTransition()) return;
      if (_djSfxActive) {
        final plannedSfxMs = preparation?.transitionSfxTriggerMs;
        final sfxDelay = plannedSfxMs == null
            ? Duration.zero
            : _snapSfxDelayToPhrase(
                planned: Duration(
                  milliseconds: plannedSfxMs.clamp(0, durationMs - 120).toInt(),
                ),
                fadeMs: durationMs,
                outgoingProfile: preparation?.outgoingProfile,
              );
        await _engageDjTransitionSfx(
          energyScore: _lastDjEnergyScore,
          transitionKind: preparation?.transitionKind,
          delay: sfxDelay,
          outgoingProfile: preparation?.outgoingProfile,
        );
      }
      if (!stillOwnsTransition()) return;
      if (!targetOccurrenceIsCurrent() || !preloadMatchesTargetOccurrence()) {
        await session.cancelCrossfade();
        if (!stillOwnsTransition()) return;
        await session.clearDeckEqOverlay(deck: 'standby');
        if (!stillOwnsTransition()) return;
        await session.setDeckPlaybackSpeeds(
          activeSpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
          standbySpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
        );
        if (!stillOwnsTransition()) return;
        _preloadedNextSongId = null;
        _media3DjTransitionPreparation = null;
        await ResonateDiagnostics.record('media3_crossfade_target_rejected', {
          'outgoingSongId': outgoingSong.id,
          'outgoingQueueIndex': outgoingIndex,
          'incomingSongId': nextSong.id,
          'incomingQueueIndex': nextIndex,
          'reason': 'queue_occurrence_changed_before_native_fade',
        });
        return;
      }

      await ResonateDiagnostics.record('media3_crossfade_start', {
        'outgoingSongId': outgoingSong.id,
        'incomingSongId': nextSong.id,
        'queueIndex': nextIndex,
        'outgoingQueueIndex': outgoingIndex,
        'durationMs': durationMs,
        'remainingMs': remainingMs,
        'incomingStartMs': preparation?.incomingStartPosition.inMilliseconds ?? 0,
        'activeSpeed': preparation?.activeSpeed ?? 1.0,
        'standbySpeed': preparation?.standbySpeed ?? 1.0,
      });
      await session.crossfade(duration: Duration(milliseconds: durationMs));

      var fadeElapsedMs = 0;
      var activeElapsedMs = 0;
      var bassDuckCleared = preparation?.incomingBassDuckAmount == null;
      final bassDuckReleaseMs = (preparation?.incomingBassDuckDurationMs ??
              (durationMs ~/ 2))
          .clamp(1, durationMs)
          .toInt();
      var lastTick = DateTime.now();
      while (!_crossfadeRuntime.acknowledgesNativePromotion(
        crossfadeStatus: session.crossfadeStatus,
        activeDeckId: _media3ShadowState?.activeDeckId ?? outgoingDeckId,
        outgoingDeckId: outgoingDeckId,
        currentSongId: session.currentSong?.id,
        currentPath: session.currentSong?.filePath,
        currentQueueIndex: session.queueIndex ?? -1,
        incomingSongId: nextSong.id,
        incomingPath: nextSong.filePath,
        incomingQueueIndex: nextIndex,
      )) {
        await Future<void>.delayed(const Duration(milliseconds: 36));
        if (session.crossfadeStatus == 'incoming_error') {
          throw StateError('Media3 standby deck failed while starting the DJ transition.');
        }
        if (session.crossfadeStatus == 'cancelled' && stillOwnsTransition()) {
          throw StateError('Media3 crossfade was cancelled before deck promotion.');
        }
        final now = DateTime.now();
        final tickDeltaMs = now.difference(lastTick).inMilliseconds;
        if (session.isPlaying) {
          // This is only a stall watchdog. It must not drive the fade or FX
          // timeline because the incoming native decoder can buffer alone.
          activeElapsedMs += tickDeltaMs;
        }
        lastTick = now;
        if (session.crossfadeStatus == 'fading') {
          fadeElapsedMs = _crossfadeRuntime.elapsedMillisecondsForNativeProgress(
            progress: _media3ShadowState?.crossfadeProgress ?? 0.0,
            durationMs: durationMs,
          );
        } else if (session.crossfadeStatus == 'completed') {
          fadeElapsedMs = durationMs;
        } else {
          // Preparing/starting/paused transitions have not consumed native
          // fade time yet. Resume and buffering are reflected by native progress.
          fadeElapsedMs = 0;
        }
        if (!stillOwnsTransition()) return;
        if (!bassDuckCleared && fadeElapsedMs >= bassDuckReleaseMs) {
          await session.clearDeckEqOverlay(deck: 'standby');
          // Pause/Stop or a new queue selection can take ownership while the
          // native overlay clear is in flight. Do not let this stale transition
          // continue its FX work after that command has superseded it.
          if (!stillOwnsTransition()) return;
          bassDuckCleared = true;
        }
        if (_djSfxEngaged) {
          await _tickDjClubFxSweep(
            (fadeElapsedMs / durationMs).clamp(0.0, 1.0).toDouble(),
          );
        }
        if (activeElapsedMs > durationMs + 8000) {
          throw TimeoutException('Media3 native crossfade did not promote the incoming deck.');
        }
      }
      // The terminal native status plus physical deck change and exact queue
      // occurrence above form the promotion acknowledgement. Capture the live
      // incoming position; all recovery below is deliberately transport-neutral.
      if (!stillOwnsTransition()) return;
      incomingPositionAtPromotion = session.position;

      await session.setDeckPlaybackSpeeds(
        activeSpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
        standbySpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
      );
      if (!stillOwnsTransition()) return;
      // Recompose from the latest user/settings state after native ownership
      // transfers. Do not restore the transition's earlier gain snapshot.
      await _applyActiveMasterVolume();
      if (!stillOwnsTransition()) return;
      await _restoreDjTransitionSfx();
      if (!stillOwnsTransition()) return;
      // The polling loop can observe promotion before the Flutter state stream
      // delivers its media-item transition. Finalize the outgoing history row
      // explicitly here and start the incoming row after reconciling its position.
      // expectedSongId makes this idempotent if the state stream got there first.
      unawaited(_finishHistoryEvent(
        finalPositionMs: _historySession.positionMs,
        expectedSongId: outgoingSong.id,
      ));
      _preloadedNextSongId = null;
      _media3DjTransitionPreparation = null;
      _crossfadeRuntime.clearDeferredTransition();
      _repeatSelfDjPreparation = null;
      _repeatSelfDjPreloadInFlight = false;
      _lastCompletionSongId = null;
      _crossfadeInProgress = false;
      _automaticCrossfadeInFlight = false;
      _transitionArmedAt = null;
      _reconcileMedia3ProviderSession();
      // The shared Media3 master gain now belongs to the promoted track. Apply
      // its cached leveling trim only after the native deck handoff commits.
      await _refreshTrackLevelingFor(nextSong);
      unawaited(_startHistoryEvent(nextSong));
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.record('media3_crossfade_committed', {
        'outgoingSongId': outgoingSong.id,
        'outgoingQueueIndex': outgoingIndex,
        'incomingSongId': nextSong.id,
        'incomingQueueIndex': nextIndex,
        'queueIndex': _queueIndex,
        'positionMs': session.position.inMilliseconds,
        'playing': session.isPlaying,
      });
      // Only announce a handoff after Media3 has promoted and committed the
      // incoming track. This is automatic Player-origin DJ, not manual Console.
      unawaited(VoiceCueService.instance.speak(
        cueId: 'dj_transition_performance.voice_dj_nice_transition',
        origin: VoiceCueOrigin.playerAuto,
        eventId: 'media3_auto_crossfade_${transitionGeneration}_${nextSong.id}',
        confirmed: true,
      ));
    } catch (error) {
      if (stillOwnsTransition()) {
        final incomingAlreadyPromoted =
            session.currentSong?.id == nextSong.id &&
            session.currentSong?.filePath.trim() == nextSong.filePath.trim() &&
            session.queueIndex == nextIndex;
        var recoveryStage = incomingAlreadyPromoted
            ? 'recover_promoted_deck'
            : 'cancel_unpromoted_transition';
        Future<void> bestEffortCleanup(
          String stage,
          Future<void> Function() action,
        ) async {
          recoveryStage = stage;
          try {
            await action();
          } catch (cleanupError) {
            await ResonateDiagnostics.record('media3_crossfade_cleanup_failed', {
              'stage': stage,
              'outgoingSongId': outgoingSong.id,
              'outgoingQueueIndex': outgoingIndex,
              'incomingSongId': nextSong.id,
              'incomingQueueIndex': nextIndex,
              'error': cleanupError.toString(),
            });
          }
        }

        try {
          // A completed native promotion is irreversible here: never reload
          // its queue item, because that would restart an already-playing track.
          // Before promotion, cancel only the standby transition and leave the
          // outgoing active decoder and its current position untouched.
          if (!incomingAlreadyPromoted) {
            await bestEffortCleanup(
              'cancel_crossfade',
              () => session.cancelCrossfade(),
            );
          }
          if (!stillOwnsTransition()) {
            await ResonateDiagnostics.record('media3_crossfade_recovery_aborted', {
              'stage': recoveryStage,
              'reason': 'transport_or_pause_took_ownership',
              'outgoingSongId': outgoingSong.id,
              'incomingSongId': nextSong.id,
            });
            return;
          }

          await bestEffortCleanup(
            incomingAlreadyPromoted
                ? 'clear_active_overlay'
                : 'clear_standby_overlay',
            () => session.clearDeckEqOverlay(
              deck: incomingAlreadyPromoted ? 'active' : 'standby',
            ),
          );
          if (!stillOwnsTransition()) {
            await ResonateDiagnostics.record('media3_crossfade_recovery_aborted', {
              'stage': recoveryStage,
              'reason': 'transport_or_pause_took_ownership',
              'outgoingSongId': outgoingSong.id,
              'incomingSongId': nextSong.id,
            });
            return;
          }

          await bestEffortCleanup(
            'reset_deck_speeds',
            () => session.setDeckPlaybackSpeeds(
              activeSpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
              standbySpeed: session.playbackSpeed.clamp(0.5, 2.0).toDouble(),
            ),
          );
          if (!stillOwnsTransition()) {
            await ResonateDiagnostics.record('media3_crossfade_recovery_aborted', {
              'stage': recoveryStage,
              'reason': 'transport_or_pause_took_ownership',
              'outgoingSongId': outgoingSong.id,
              'incomingSongId': nextSong.id,
            });
            return;
          }

          if (incomingAlreadyPromoted) {
            await bestEffortCleanup(
              'restore_composed_gain',
              () => _applyActiveMasterVolume(),
            );
          }
          if (!stillOwnsTransition()) {
            await ResonateDiagnostics.record('media3_crossfade_recovery_aborted', {
              'stage': recoveryStage,
              'reason': 'transport_or_pause_took_ownership',
              'outgoingSongId': outgoingSong.id,
              'incomingSongId': nextSong.id,
            });
            return;
          }

          await bestEffortCleanup(
            'restore_dj_effects',
            () => _restoreDjTransitionSfx(),
          );
          if (!stillOwnsTransition()) {
            await ResonateDiagnostics.record('media3_crossfade_recovery_aborted', {
              'stage': recoveryStage,
              'reason': 'transport_or_pause_took_ownership',
              'outgoingSongId': outgoingSong.id,
              'incomingSongId': nextSong.id,
            });
            return;
          }

          if (incomingAlreadyPromoted) {
            // Promotion is authoritative. Reconcile the current native
            // position and finalize history without loading or playing again.
            unawaited(_finishHistoryEvent(
              finalPositionMs: _historySession.positionMs,
              expectedSongId: outgoingSong.id,
            ));
            _reconcileMedia3ProviderSession();
            _preloadedNextSongId = null;
            _media3DjTransitionPreparation = null;
            _crossfadeRuntime.clearDeferredTransition();
            _repeatSelfDjPreparation = null;
            _repeatSelfDjPreloadInFlight = false;
            _lastCompletionSongId = null;
            _crossfadeInProgress = false;
            _automaticCrossfadeInFlight = false;
            _transitionArmedAt = null;
            await _refreshTrackLevelingFor(nextSong);
            unawaited(_startHistoryEvent(nextSong));
            _publishServiceState();
            notifyListeners();
            await ResonateDiagnostics.record('media3_crossfade_recovered_after_promotion', {
              'outgoingSongId': outgoingSong.id,
              'outgoingQueueIndex': outgoingIndex,
              'incomingSongId': nextSong.id,
              'incomingQueueIndex': nextIndex,
              'positionMs': session.position.inMilliseconds,
              'positionAtNativePromotionMs': incomingPositionAtPromotion?.inMilliseconds,
              'incomingPositionPreserved': incomingPositionAtPromotion == null
                  ? null
                  : session.position.inMilliseconds >=
                      incomingPositionAtPromotion.inMilliseconds - 100,
              'playing': session.isPlaying,
              'error': error.toString(),
            });
          } else {
            // Do not load the next queue entry or call play() here. The active
            // outgoing deck remains canonical; Media3's normal queue completion
            // is the only authority allowed to advance after a failed fade.
            final outgoingStillActive =
                session.currentSong?.id == outgoingSong.id &&
                session.currentSong?.filePath.trim() ==
                    outgoingSong.filePath.trim() &&
                session.queueIndex == outgoingIndex;
            _crossfadeRuntime.deferTransition(
              outgoingSongId: outgoingSong.id,
              outgoingQueueIndex: outgoingIndex,
              outgoingPath: outgoingSong.filePath.trim(),
              incomingSongId: nextSong.id,
              incomingQueueIndex: nextIndex,
              incomingPath: nextSong.filePath.trim(),
            );
            _preloadedNextSongId = null;
            _media3DjTransitionPreparation = null;
            _crossfadeInProgress = false;
            _automaticCrossfadeInFlight = false;
            _transitionArmedAt = null;
            _reconcileMedia3ProviderSession();
            await ResonateDiagnostics.record('media3_crossfade_deferred_to_gapless', {
              'outgoingSongId': outgoingSong.id,
              'outgoingQueueIndex': outgoingIndex,
              'incomingSongId': nextSong.id,
              'incomingQueueIndex': nextIndex,
              'outgoingStillActive': outgoingStillActive,
              'outgoingPositionMs': session.position.inMilliseconds,
              'outgoingPlaying': session.isPlaying,
              'nativeStatus': session.crossfadeStatus,
              'reason': 'transition_failed_before_promotion',
              'error': error.toString(),
            });
          }
        } catch (recoveryError) {
          await ResonateDiagnostics.record('media3_crossfade_failed', {
            'outgoingSongId': outgoingSong.id,
            'outgoingQueueIndex': outgoingIndex,
            'incomingSongId': nextSong.id,
            'incomingQueueIndex': nextIndex,
            'error': error.toString(),
            'recoveryStage': recoveryStage,
            'recoveryError': recoveryError.toString(),
          });
        }
      }
      if (transitionGeneration == _automaticTransitionGeneration &&
          transportEpoch == _userTransportEpoch) {
        _preloadedNextSongId = null;
        _media3DjTransitionPreparation = null;
        await _restoreDjTransitionSfx();
      }
    } finally {
      if (transitionGeneration == _automaticTransitionGeneration) {
        _crossfadeInProgress = false;
        _automaticCrossfadeInFlight = false;
        _transitionArmedAt = null;
        _djStretchSpeedOut = null;
        _djStretchSpeedIn = null;
        _lastDjIncomingBeatMs = const <int>[];
        _lastDjIncomingBpm = null;
      }
      await controlLease.release();
      _drainPendingMedia3Completion();
    }
  }

  Future<void> _syncMedia3ProviderQueue() async {
    if (_media3ProviderSession == null) return;
    final session = (await _ensureMedia3ProviderSessionActive())!;
    await session.synchronizeQueue(_queue);
    await session.setShuffleMode(effectiveShuffleEnabled);
    await session.setRepeatMode(switch (_repeatMode) {
      PlaybackRepeatMode.one => PlaybackQueueRepeatMode.one,
      PlaybackRepeatMode.all => PlaybackQueueRepeatMode.all,
      PlaybackRepeatMode.off => PlaybackQueueRepeatMode.off,
    });
  }

  Future<bool> _playSongOnMedia3ProviderSession(
    Song song, {
    List<Song>? queue,
    required int startIndex,
    required bool resume,
    required int intentToken,
  }) async {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) return false;
    if (await _isCommunicationActive()) {
      _userWantsPlaying = false;
      isPlaying = false;
      _publishServiceState();
      notifyListeners();
      return false;
    }
    final requested = queue != null && queue.isNotEmpty
        ? List<Song>.of(queue)
        : <Song>[song];
    final normalized = requested
        .where((item) => item.filePath.trim().isNotEmpty)
        .toList(growable: false);
    if (normalized.isEmpty) return false;

    // Preserve the requested queue occurrence, not merely the first matching
    // song ID. Playlists may legitimately contain the same media more than
    // once, and filtering unplayable entries changes the native queue index.
    int? requestedPlayableIndex;
    if (startIndex >= 0 &&
        startIndex < requested.length &&
        requested[startIndex].id == song.id &&
        requested[startIndex].filePath.trim() == song.filePath.trim() &&
        requested[startIndex].filePath.trim().isNotEmpty) {
      requestedPlayableIndex = requested
          .take(startIndex)
          .where((item) => item.filePath.trim().isNotEmpty)
          .length;
    }
    final matchingOccurrences = <int>[
      for (var i = 0; i < normalized.length; i++)
        if (normalized[i].id == song.id &&
            normalized[i].filePath.trim() == song.filePath.trim())
          i,
    ];
    final resolvedIndex = requestedPlayableIndex ??
        (matchingOccurrences.length == 1 ? matchingOccurrences.single : -1);
    if (resolvedIndex < 0 || resolvedIndex >= normalized.length) {
      await ResonateDiagnostics.record('media3_provider_play_rejected', {
        'songId': song.id,
        'requestedIndex': startIndex,
        'reason': 'ambiguous_queue_occurrence',
      });
      return false;
    }
    final selected = normalized[resolvedIndex];
    // Media3 is the production path, so resolve its per-track RMS trim here
    // rather than relying on the legacy playSong finalizer. The selected track
    // must have its own gain before the first audible PCM block.
    var selectedTrackLevel = 1.0;
    if (_audioLevelingEnabled) {
      final cachedLevel = await _loudnessService.getCached(selected);
      if (!_playbackIntentGate.isCurrent(intentToken)) return false;
      if (cachedLevel != null &&
          (cachedLevel.targetRmsDbfs - _audioLevelingTargetRmsDbfs).abs() < 0.001) {
        final safeGainDb = cachedLevel.gainDb.clamp(-12.0, 0.0).toDouble();
        selectedTrackLevel = math.pow(10.0, safeGainDb / 20.0).toDouble();
      }
    }
    final nextQueue = effectiveShuffleEnabled && normalized.length > 1
        ? <Song>[
            selected,
            ...(<Song>[...normalized]..removeAt(resolvedIndex)..shuffle(math.Random())),
          ]
        : normalized;
    final nextIndex = effectiveShuffleEnabled && normalized.length > 1
        ? 0
        : resolvedIndex;

    _loadingSource = true;
    _userWantsPlaying = true;
    _media3PendingSelectionSongId = selected.id;
    _media3PendingSelectionPath = selected.filePath.trim();
    _media3PendingSelectionQueueIndex = nextIndex;
    _queue = nextQueue;
    _queueIndex = nextIndex;
    _trackLevelingScale = selectedTrackLevel;
    _eqPreampScale =
        (_eqPreampUserScale * selectedTrackLevel).clamp(0.0, 1.0).toDouble();
    try {
      await session.setAudioFocusHandling(true);
      await session.loadQueue(nextQueue, startIndex: nextIndex);
      await session.setRepeatMode(switch (_repeatMode) {
        PlaybackRepeatMode.one => PlaybackQueueRepeatMode.one,
        PlaybackRepeatMode.all => PlaybackQueueRepeatMode.all,
        PlaybackRepeatMode.off => PlaybackQueueRepeatMode.off,
      });
      await session.setShuffleMode(effectiveShuffleEnabled);
      await session.setVolume(1.0);
      await session.setGainFactors(
        trackLevel: selectedTrackLevel,
        preamp: _eqPreampUserScale,
        sleepFade: _sleepFadeScale,
        focusDuck: _isDucked ? (_audioFocusLevel == 1 ? 0.18 : MusicProvider._duckLevel) : 1.0,
      );
      var requestedStartPosition = Duration.zero;
      if (resume && _resumeSongId == selected.id && _resumePositionMs > 0) {
        final durationMs = selected.duration.inMilliseconds;
        final safeMs = _resumePositionMs
            .clamp(0, durationMs > 0 ? durationMs : _resumePositionMs)
            .toInt();
        requestedStartPosition = Duration(milliseconds: safeMs);
      }
      await session.seek(requestedStartPosition);
      if (!_playbackIntentGate.isCurrent(intentToken)) return false;
      await session.play();

      final previousId = currentSong?.id;
      final nativeSelectionCommitted =
          session.currentSong?.id == selected.id &&
          session.currentSong?.filePath.trim() == selected.filePath.trim() &&
          session.queueIndex == nextIndex;
      if (nativeSelectionCommitted) {
        // Synchronous session getters can expose the incoming item before the
        // state stream has drained older outgoing-item snapshots. Reconcile the
        // readable native state, but retain the selection fence until a matching
        // state-stream event confirms this exact occurrence.
        _reconcileMedia3ProviderSession();
      } else {
        // loadQueue/play may complete before Media3 publishes its new timeline.
        // Do not let the previous item's still-readable snapshot roll the
        // just-accepted library selection back to the old player UI.
        currentSong = selected;
        _queueIndex = nextIndex;
        currentDuration = selected.duration;
        currentPosition = requestedStartPosition;
      }
      isPlaying = session.isPlaying;
      _lastCompletionSongId = null;
      _crossfadeInProgress = false;
      _automaticCrossfadeInFlight = false;
      _gaplessWindow.active = false;
      _gaplessWindow.songIds = const [];
      _podcastSession.onSongStarted(
        modes: _modes,
        song: selected,
        resumePosition: resume ? session.position : null,
      );
      _audiobookSession.onSongStarted(
        modes: _modes,
        song: selected,
        resumePosition: resume ? session.position : null,
      );
      _modes?.onPlaybackStarted(selected, position: session.position);
      if (previousId != selected.id) {
        unawaited(_finishHistoryEvent());
        unawaited(_startHistoryEvent(selected));
      }
      await _persistQueue();
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.record('media3_provider_play_committed', {
        'songId': selected.id,
        'queueIndex': nextIndex,
        'playing': session.isPlaying,
        'positionMs': session.position.inMilliseconds,
      });
      return true;
    } catch (error, stack) {
      _media3PendingSelectionSongId = null;
      _media3PendingSelectionPath = null;
      _media3PendingSelectionQueueIndex = null;
      _userWantsPlaying = false;
      isPlaying = false;
      debugPrint('Media3 provider play failed: $error');
      debugPrint('$stack');
      await ResonateDiagnostics.record('media3_provider_command_failed', {
        'command': 'play',
        'songId': song.id,
        'error': error.toString(),
      });
      _publishServiceState();
      notifyListeners();
      return false;
    } finally {
      _loadingSource = false;
    }
  }

  void _reconcileMedia3ProviderSession() {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) return;
    final nativeSong = session.currentSong;
    final nativeIndex = Media3MusicProviderAdapter.resolveCurrentQueueIndex(
      _queue,
      mediaId: nativeSong?.id,
      playableIndex: session.queueIndex ?? -1,
    );
    if (nativeIndex != null) {
      _queueIndex = nativeIndex;
      currentSong = _queue[nativeIndex];
    } else if (nativeSong != null) {
      final matches = _queue.where((song) => song.id == nativeSong.id);
      if (matches.length == 1) {
        currentSong = matches.first;
        _queueIndex = _queue.indexOf(matches.first);
      }
    }
    currentPosition = session.position;
    currentDuration = session.duration ?? currentSong?.duration;
    isPlaying = session.isPlaying;
  }

  void _acceptMedia3ProviderState(Media3ProviderState state) {
    if (!_media3ProviderSessionActive || _disposed) return;
    final session = _media3ProviderSession;
    if (session == null) return;
    final pendingSongId = _media3PendingSelectionSongId;
    var pendingSelectionMismatch = false;
    if (pendingSongId != null) {
      final pendingPath = _media3PendingSelectionPath;
      final pendingIndex = _media3PendingSelectionQueueIndex;
      final statePath = state.currentSong?.filePath.trim();
      final matchesPending = state.mediaId == pendingSongId &&
          (pendingPath == null || statePath == null || statePath == pendingPath) &&
          (pendingIndex == null || state.queueIndex == null ||
              state.queueIndex == pendingIndex);
      if (matchesPending) {
        _media3PendingSelectionSongId = null;
        _media3PendingSelectionPath = null;
        _media3PendingSelectionQueueIndex = null;
      } else {
        // Fence track identity, duration, position and completion from the
        // outgoing timeline, but do not discard the native transport state.
        // isPlaying belongs to the MediaSession itself, not to a queue row;
        // dropping these snapshots made the Play/Pause control stale until a
        // later timeline refresh happened to match the selected occurrence.
        pendingSelectionMismatch = true;
      }
    }
    final oldSongId = currentSong?.id;
    final previousQueueIndex = _queueIndex;
    final previousPosition = currentPosition;
    // While a library selection is awaiting its matching native timeline
    // event, an outgoing snapshot must not mutate the optimistic selection.
    // Keep this guard around identity reconciliation itself (not merely around
    // the later position update); otherwise the stale row is assigned before
    // the pending-selection early return can protect the UI.
    if (!pendingSelectionMismatch) {
      final resolvedIndex = Media3MusicProviderAdapter.resolveCurrentQueueIndex(
        _queue,
        mediaId: state.mediaId,
        playableIndex: state.queueIndex ?? -1,
      );
      if (resolvedIndex != null) {
        _queueIndex = resolvedIndex;
        currentSong = _queue[resolvedIndex];
      } else if (state.currentSong != null) {
        // State with an unresolved queue occurrence is not allowed to rewrite
        // the provider queue index. A unique ID match is safe; duplicates are not.
        final matches = _queue.where((song) =>
            song.id == state.currentSong!.id && state.currentSong!.filePath.trim().isNotEmpty);
        if (matches.length == 1) {
          currentSong = matches.first;
          _queueIndex = _queue.indexOf(matches.first);
        }
      }
    }
    final songChanged = currentSong != null && oldSongId != currentSong!.id;
    final activeDeckId = state.activeDeckId == 'B' ? 'B' : 'A';
    final activeSongId = currentSong?.id;
    if (activeSongId != null &&
        (_dspHintedActiveSongId != activeSongId ||
            _dspHintedActiveDeckId != activeDeckId)) {
      _dspHintedActiveSongId = activeSongId;
      _dspHintedActiveDeckId = activeDeckId;
      unawaited(_applyMedia3DspAnalysisHint(
        song: currentSong!,
        deckId: activeDeckId,
        standby: false,
      ));
    }
    if (songChanged) {
      currentDuration = state.duration ?? currentSong!.duration;
      _lastCompletionSongId = null;
    }
    // Notification, headset and Android Auto controls can change the native
    // MediaSession repeat mode without going through MusicProvider.setRepeatMode.
    // Ignore the temporary native repeat-off window used by Repeat One DJ handoffs.
    final observedRepeatMode = switch (state.repeatMode) {
      'one' => PlaybackRepeatMode.one,
      'all' => PlaybackRepeatMode.all,
      _ => PlaybackRepeatMode.off,
    };
    if (!_repeatSelfFadeExecuting &&
        !_repeatSelfHandoffInFlight &&
        !_repeatSelfHandoffArmed &&
        _repeatModeCommandPendingGeneration == 0 &&
        observedRepeatMode != _repeatMode) {
      final transitionActive = _crossfadeInProgress ||
          _automaticCrossfadeInFlight || _crossfadePreloadInFlight ||
          _preloadedNextSongId != null;
      if (transitionActive) {
        _cancelAutomaticPlaybackWork(reason: 'external_repeat_mode_changed');
      }
      final previousMode = _repeatMode;
      _repeatSelfDjPlanning = false;
      _repeatSelfDjPreloadInFlight = false;
      _repeatSelfDjPreparation = null;
      _repeatMode = observedRepeatMode;
      unawaited(ResonateDiagnostics.record('media3_repeat_mode_external_change', {
        'previousMode': previousMode.name,
        'observedMode': observedRepeatMode.name,
        'songId': currentSong?.id,
        'queueIndex': _queueIndex,
        'positionMs': state.position.inMilliseconds,
        'activeDeckId': state.activeDeckId,
        'crossfadeStatus': state.crossfadeStatus,
        'transitionWasActive': transitionActive,
      }));
    } else if (!_repeatSelfFadeExecuting &&
        !_repeatSelfHandoffInFlight &&
        !_repeatSelfHandoffArmed &&
        _repeatModeCommandPendingGeneration != 0 &&
        observedRepeatMode != _repeatMode) {
      unawaited(ResonateDiagnostics.record('media3_repeat_mode_stale_snapshot_ignored', {
        'requestedMode': _repeatMode.name,
        'observedMode': observedRepeatMode.name,
        'pendingGeneration': _repeatModeCommandPendingGeneration,
        'songId': currentSong?.id,
        'queueIndex': _queueIndex,
        'positionMs': state.position.inMilliseconds,
        'activeDeckId': state.activeDeckId,
        'crossfadeStatus': state.crossfadeStatus,
      }));
    }
    if (pendingSelectionMismatch) {
      // Preserve the optimistic library selection and its zero/resume position
      // until Media3 confirms the selected occurrence, while still reflecting
      // the authoritative session-level play/pause state immediately.
      isPlaying = state.isPlaying;
      _publishServiceState(positionOnly: true);
      notifyListeners();
      return;
    }
    currentPosition = state.position;
    if (songChanged) {
      // The incoming snapshot already belongs to the next song. Finalize the
      // outgoing history row with the last position observed for that song,
      // not the new track's position (or a stale legacy-player position).
      unawaited(_finishHistoryEvent(
        finalPositionMs: previousPosition.inMilliseconds,
        expectedSongId: oldSongId,
      ));
      unawaited(_startHistoryEvent(currentSong!));
    }
    // Media3 is the canonical position source after cutover. Keep the active
    // listening event checkpoint current so a crossfade handoff does not
    // misclassify a nearly/full-length listen as a skip.
    if (currentSong != null &&
        _historySession.activeEvent?.songId == currentSong!.id) {
      _historySession.positionMs = state.position.inMilliseconds;
    }
    if (state.isPlaying && !_crossfadeInProgress) {
      _maybeStartAutomaticCrossfade(state.position);
    }
    if (!state.isCompleted &&
        state.position + const Duration(seconds: 1) < previousPosition) {
      _lastCompletionSongId = null;
    }
    currentDuration = state.duration ?? currentSong?.duration;
    // Keep the persisted queue occurrence aligned with native promotion. A
    // resume checkpoint for the incoming track is useless if the saved queue
    // index still points at the outgoing track after process death.
    if (oldSongId != currentSong?.id || previousQueueIndex != _queueIndex) {
      unawaited(_persistQueue());
    }
    // Persist from canonical Media3 observations so force-stop recovery does
    // not depend on a Flutter lifecycle callback being delivered.
    _persistResumePosition();
    // Buffering does not clear the user's play intent. isPlaying is strictly
    // the reconciled native state, not an optimistic command flag.
    isPlaying = state.isPlaying;
    if (state.isCompleted) {
      final completedId = currentSong?.id;
      if (completedId != null && completedId != _lastCompletionSongId) {
        _lastCompletionSongId = completedId;
        unawaited(_handleMedia3ProviderCompletion(completedId));
      }
    } else if (state.hasError) {
      unawaited(ResonateDiagnostics.record('media3_provider_state_error', {
        'songId': currentSong?.id,
        'error': state.error,
      }));
    }
    _publishServiceState(positionOnly: true);
    notifyListeners();
    _armEndOfTrackWatchdog();
    if (!state.isPlaying &&
        state.playWhenReady &&
        !state.isBuffering &&
        !state.isCompleted) {
      _recoverMedia3ProviderPlayback();
    }
  }

  /// Resolve measured PCM metrics off the playback thread, then apply them
  /// only to the physical deck that still owns this exact song occurrence.
  /// Background hint writes never preempt an active DJ/crossfade/user controller.
  Future<void> _applyMedia3DspAnalysisHint({
    required Song song,
    required String deckId,
    required bool standby,
  }) async {
    if (!_media3ProviderSessionActive ||
        _disposed ||
        !const {'A', 'B'}.contains(deckId) ||
        song.id.trim().isEmpty) return;
    final generation = (_dspAnalysisHintGenerations[deckId] ?? 0) + 1;
    _dspAnalysisHintGenerations[deckId] = generation;
    bool currentRequest() =>
        !_disposed &&
        _media3ProviderSessionActive &&
        _dspAnalysisHintGenerations[deckId] == generation &&
        (standby
            ? _preloadedNextSongId == song.id &&
                _preloadedNextQueueIndex == _crossfadeTargetIndex &&
                _preloadedNextPath == song.filePath.trim() &&
                (_media3ShadowState?.activeDeckId ?? 'A') != deckId
            : currentSong?.id == song.id &&
                (_media3ShadowState?.activeDeckId ?? 'A') == deckId);
    try {
      final analysisService = _djAnalysis ??= DjAnalysisService();
      // Playback consumes an existing, fully measured profile only.
      // It must never launch offline decoding/analysis during app startup,
      // song selection, or preload. DJ analysis can populate this cache
      // independently; a missing profile simply means no deck hint yet.
      final profile = await analysisService.getProfile(song.id);
      if (!currentRequest()) {
        await ResonateDiagnostics.record('media3_dsp_analysis_hint_skipped', {
          'deckId': deckId,
          'songId': song.id,
          'standby': standby,
          'reason': 'request_stale_after_profile_lookup',
          'stage': 'profile_lookup',
          'generation': generation,
        });
        return;
      }
      if (profile == null) {
        await ResonateDiagnostics.record('media3_dsp_analysis_hint_skipped', {
          'deckId': deckId,
          'songId': song.id,
          'standby': standby,
          'reason': 'profile_unavailable',
          'stage': 'profile_lookup',
          'generation': generation,
        });
        return;
      }
      final profileRejection = profile.songId != song.id
          ? 'profile_song_mismatch'
          : !profile.dspAnalysis.isMeasured
              ? 'profile_not_measured'
              : !profile.dspAnalysis.isValid
                  ? 'profile_invalid'
                  : profile.dspAnalysis.maxSafeBassDb == null
                      ? 'max_safe_bass_unavailable'
                      : null;
      if (profileRejection != null) {
        await ResonateDiagnostics.record('media3_dsp_analysis_hint_skipped', {
          'deckId': deckId,
          'songId': song.id,
          'standby': standby,
          'reason': profileRejection,
          'stage': 'profile_validation',
          'profileSongIdMatches': profile.songId == song.id,
          'isMeasured': profile.dspAnalysis.isMeasured,
          'isValid': profile.dspAnalysis.isValid,
          'hasMaxSafeBassDb': profile.dspAnalysis.maxSafeBassDb != null,
          'analysisVersion': profile.analysisVersion,
        });
        return;
      }

      final lease = await playbackControlArbiter.acquire(
        owner: 'dsp_analysis_hint',
        priority: PlaybackControlPriority.background,
      );
      if (lease == null) {
        await ResonateDiagnostics.record('media3_dsp_analysis_hint_skipped', {
          'deckId': deckId,
          'songId': song.id,
          'standby': standby,
          'reason': 'arbiter_lease_unavailable',
          'activeOwner': playbackControlArbiter.activeOwner,
        });
        return;
      }
      try {
        final requestCurrentBeforeWrite = currentRequest();
        final writeAuthorized = requestCurrentBeforeWrite &&
            lease.authorizeWrite('dsp:analysis_hint:$deckId:$song.id');
        if (!writeAuthorized) {
          await ResonateDiagnostics.record('media3_dsp_analysis_hint_skipped', {
            'deckId': deckId,
            'songId': song.id,
            'standby': standby,
            'reason': requestCurrentBeforeWrite
                ? 'arbiter_write_not_authorized'
                : 'request_stale_before_native_write',
            'leaseCurrent': lease.isCurrent,
            'activeOwner': playbackControlArbiter.activeOwner,
          });
          return;
        }
        final metrics = profile.dspAnalysis;
        final bridgeResult = await AudioEffectsBridge.setLiveDspDeckAnalysisHintDetailed(
          deckId: deckId,
          songId: song.id,
          samplePeakDb: metrics.samplePeakDb,
          truePeakDb: metrics.truePeakDb,
          rmsDb: metrics.rmsDb,
          crestDb: metrics.crestDb,
          bassEnergyDb: metrics.bassEnergyDb,
          maxSafeBassDb: metrics.maxSafeBassDb,
        );
        final bridgeAccepted = bridgeResult['ok'] == true;
        final leaseCurrentAfterBridge = lease.isCurrent;
        final requestCurrentAfterBridge = currentRequest();
        final accepted = bridgeAccepted &&
            leaseCurrentAfterBridge &&
            requestCurrentAfterBridge;
        await ResonateDiagnostics.record('media3_dsp_analysis_hint', {
          'deckId': deckId,
          'songId': song.id,
          'applied': accepted,
          'bridgeAccepted': bridgeAccepted,
          'bridgeReason': bridgeResult['reason'],
          'bridgeError': bridgeResult['error'],
          'leaseCurrentAfterBridge': leaseCurrentAfterBridge,
          'requestCurrentAfterBridge': requestCurrentAfterBridge,
          'standby': standby,
          'analysisVersion': profile.analysisVersion,
        });
      } finally {
        await lease.release();
      }
    } catch (error) {
      await ResonateDiagnostics.record('media3_dsp_analysis_hint_failed', {
        'deckId': deckId,
        'songId': song.id,
        'standby': standby,
        'error': error.toString(),
      });
    }
  }

  Future<void> _handleMedia3ProviderCompletion(String completedSongId) async {
    if (!_media3ProviderSessionActive || _disposed) return;
    final completionTransportEpoch = _userTransportEpoch;
    // A native completion from the outgoing deck is expected during a
    // crossfade. The transition owns advancement until it either commits or
    // performs its same-session fallback.
    if (_crossfadeInProgress ||
        _automaticCrossfadeInFlight ||
        _repeatSelfHandoffInFlight ||
        _crossfadePreloadInFlight) {
      // Defer instead of dropping: if a transition is cancelled without
      // promoting a new deck, the still-active completed track must advance.
      _pendingMedia3CompletionSongId = completedSongId;
      _pendingMedia3CompletionDeckId =
          _media3ShadowState?.activeDeckId ?? 'A';
      _pendingMedia3CompletionTransportEpoch = completionTransportEpoch;
      await ResonateDiagnostics.record('media3_provider_completion_deferred', {
        'songId': completedSongId,
        'activeDeckId': _pendingMedia3CompletionDeckId,
        'transportEpoch': completionTransportEpoch,
      });
      return;
    }
    // Completion observation can be delivered asynchronously after the user
    // has already paused at the end of a track. Explicit pause intent wins;
    // never turn a late completion callback into an automatic next/play.
    if (!_userWantsPlaying) {
      await ResonateDiagnostics.record('media3_provider_completion_ignored', {
        'songId': completedSongId,
        'reason': 'user_paused',
      });
      return;
    }
    _endOfTrackWatchdog?.cancel();
    _endOfTrackWatchdog = null;
    final completedSong = currentSong;
    if (completedSong != null && completedSong.id == completedSongId) {
      _modes?.onPlaybackCompleted(completedSong);
    }
    currentPosition = currentDuration ?? currentPosition;
    _publishServiceState();
    notifyListeners();
    await ResonateDiagnostics.record('media3_provider_completion_observed', {
      'songId': completedSongId,
      'queueIndex': _queueIndex,
      'queueLength': _queue.length,
      'repeatMode': _repeatMode.name,
    });
    // A Pause/Next/Previous may arrive while the diagnostic/history boundary
    // yields. Never let this old completion mint a fresh transport token.
    if (_disposed ||
        completionTransportEpoch != _userTransportEpoch ||
        !_userWantsPlaying ||
        _crossfadeInProgress ||
        _automaticCrossfadeInFlight ||
        _repeatSelfHandoffInFlight ||
        currentSong?.id != completedSongId) {
      await ResonateDiagnostics.record('media3_provider_completion_ignored', {
        'songId': completedSongId,
        'reason': 'transport_changed_before_advance',
        'completionEpoch': completionTransportEpoch,
        'currentEpoch': _userTransportEpoch,
      });
      return;
    }
    if (!_completionAdvanceInProgress) {
      await onTrackEnded(completedSongId);
    }
  }

  void _drainPendingMedia3Completion() {
    // A preload may finish while the full crossfade is still running. Keep
    // the pending completion until the final owner has released the transition.
    if (_crossfadeInProgress ||
        _automaticCrossfadeInFlight ||
        _repeatSelfHandoffInFlight ||
        _crossfadePreloadInFlight) {
      return;
    }
    final songId = _pendingMedia3CompletionSongId;
    final deckId = _pendingMedia3CompletionDeckId;
    final transportEpoch = _pendingMedia3CompletionTransportEpoch;
    _pendingMedia3CompletionSongId = null;
    _pendingMedia3CompletionDeckId = null;
    _pendingMedia3CompletionTransportEpoch = null;
    if (songId == null ||
        deckId == null ||
        transportEpoch == null ||
        _disposed ||
        !_userWantsPlaying ||
        transportEpoch != _userTransportEpoch ||
        currentSong?.id != songId ||
        (_media3ShadowState?.activeDeckId ?? 'A') != deckId) {
      return;
    }
    unawaited(_handleMedia3ProviderCompletion(songId));
  }

  void _recoverMedia3ProviderPlayback() {
    final session = _media3ProviderSession;
    if (session == null ||
        !_media3ProviderSessionActive ||
        !_userWantsPlaying ||
        !(_media3ShadowState?.playWhenReady ?? false) ||
        _focusLostAt != null ||
        _loadingSource ||
        _transportInFlight ||
        _completionAdvanceInProgress ||
        _recentlyUserPaused ||
        session.isCompleted ||
        session.isBuffering ||
        !session.isReady ||
        session.isPlaying) {
      return;
    }
    final now = DateTime.now();
    if (_lastSilentRecoverAt != null &&
        now.difference(_lastSilentRecoverAt!) < const Duration(seconds: 4)) {
      return;
    }
    _lastSilentRecoverAt = now;
    // Recovery is speculative work. A pause/next/previous command can arrive
    // while communication state or audio focus is being queried, so bind this
    // recovery to the transport epoch and revalidate immediately before play.
    final recoveryTransportEpoch = _userTransportEpoch;
    bool stillOwnsRecovery() =>
        recoveryTransportEpoch == _userTransportEpoch &&
        _media3ProviderSessionActive &&
        identical(_media3ProviderSession, session) &&
        !_disposed &&
        _userWantsPlaying &&
        !_recentlyUserPaused &&
        (_media3ShadowState?.playWhenReady ?? false);
    bool sessionStillNeedsRecovery() =>
        stillOwnsRecovery() &&
        session.isReady &&
        !session.isBuffering &&
        !session.isCompleted &&
        !session.isPlaying;
    unawaited(() async {
      try {
        if (!sessionStillNeedsRecovery()) return;
        if (await _isCommunicationActive()) return;
        if (!sessionStillNeedsRecovery()) return;
        await session.setAudioFocusHandling(true);
        // Focus acquisition is asynchronous: native playback may recover on
        // its own while it is pending. Re-check both user authority and native
        // state so the watchdog never restarts an already-running deck.
        if (!sessionStillNeedsRecovery()) return;
        await session.play();
        await ResonateDiagnostics.record('media3_provider_recovery', {
          'songId': session.currentSong?.id ?? currentSong?.id,
          'playing': session.isPlaying,
          'positionMs': session.position.inMilliseconds,
          'transportEpoch': recoveryTransportEpoch,
        });
      } catch (error) {
        await ResonateDiagnostics.record('media3_provider_recovery_failed', {
          'songId': currentSong?.id,
          'error': error.toString(),
        });
      }
    }());
  }
}
