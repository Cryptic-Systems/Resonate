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
    if (next == null || outgoing == null || nextIndex < 0 ||
        _preloadedNextSongId == next.id) return;

    final generation = _automaticTransitionGeneration;
    final transportEpoch = _userTransportEpoch;
    bool stillOwnsPreload() =>
        generation == _automaticTransitionGeneration &&
        transportEpoch == _userTransportEpoch &&
        _media3ProviderSessionActive &&
        effectiveCrossfadeEnabled &&
        _crossfadeTargetSong?.id == next.id;
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
      if (!stillOwnsPreload()) {
        await session.cancelCrossfade();
        return;
      }
      await session.setDeckPlaybackSpeeds(
        activeSpeed: preparation.activeSpeed,
        standbySpeed: preparation.standbySpeed,
      );
      if (!stillOwnsPreload()) {
        await session.cancelCrossfade();
        return;
      }
      _media3DjTransitionPreparation = preparation;
      _preloadedNextSongId = next.id;
      await ResonateDiagnostics.record('media3_crossfade_preloaded', {
        'outgoingSongId': outgoing.id,
        'incomingSongId': next.id,
        'queueIndex': nextIndex,
        'incomingStartMs': preparation.incomingStartPosition.inMilliseconds,
        'activeSpeed': preparation.activeSpeed,
        'standbySpeed': preparation.standbySpeed,
      });
    } catch (error) {
      if (stillOwnsPreload()) {
        _preloadedNextSongId = null;
        _media3DjTransitionPreparation = null;
        await ResonateDiagnostics.record('media3_crossfade_preload_failed', {
          'songId': next.id,
          'error': error.toString(),
        });
      }
    } finally {
      if (generation == _automaticTransitionGeneration &&
          transportEpoch == _userTransportEpoch) {
        _crossfadePreloadInFlight = false;
      }
    }
  }

  Future<void> _runMedia3AutomaticCrossfade() async {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) return;
    if (_transportInFlight || _loadingSource || _userTransportPending) {
      _automaticCrossfadeInFlight = false;
      _crossfadeInProgress = false;
      _transitionArmedAt = null;
      return;
    }
    final generation = _authority.beginAutomatic('media3_automatic_crossfade');
    final transitionGeneration = ++_automaticTransitionGeneration;
    final transportEpoch = _userTransportEpoch;
    final outgoingSong = currentSong;
    final nextSong = _crossfadeTargetSong;
    final nextIndex = _crossfadeTargetIndex;
    bool stillOwnsTransition() =>
        _media3ProviderSessionActive &&
        transportEpoch == _userTransportEpoch &&
        transitionGeneration == _automaticTransitionGeneration &&
        !_authority.isStale(generation) &&
        !_transportInFlight &&
        !_userTransportPending;
    if (outgoingSong == null || nextSong == null || nextIndex < 0 ||
        !session.isPlaying) {
      _automaticCrossfadeInFlight = false;
      _crossfadeInProgress = false;
      _transitionArmedAt = null;
      return;
    }

    _crossfadeInProgress = true;
    _transitionArmedAt = DateTime.now();
    try {
      // A preload can still be decoding when the end-window trigger arrives.
      // Wait for the in-flight session command rather than racing a second
      // standby replacement against it.
      for (var wait = 0; _crossfadePreloadInFlight && wait < 80; wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!stillOwnsTransition()) return;
      }
      var preparation = _media3DjTransitionPreparation;
      if (_preloadedNextSongId != nextSong.id || preparation == null) {
        await _preloadNextForMedia3Crossfade();
        preparation = _media3DjTransitionPreparation;
      }
      if (!stillOwnsTransition()) return;
      if (_preloadedNextSongId != nextSong.id) {
        throw StateError('Media3 standby deck did not preload the intended queue occurrence.');
      }

      final djActive = _djBeatAlignActive || _djTempoMatchActive || _djSfxActive;
      final configuredDurationMs = (djActive
              ? (_crossfadeDurationMs + _lastDjCrossfadeBiasMs).clamp(500, 6500)
              : _crossfadeDurationMs.clamp(500, 12000))
          .toInt();
      final remainingMs = session.duration == null
          ? null
          : session.duration!.inMilliseconds - session.position.inMilliseconds;
      if (remainingMs == null || remainingMs < 1200 ||
          remainingMs > configuredDurationMs + 4500) {
        throw StateError('Media3 crossfade trigger is outside the validated end window.');
      }
      // Never let the outgoing deck reach ENDED before the native fade can
      // promote the prepared deck. Keep the small tail guard used by the
      // previous provider-owned crossfade implementation.
      final durationMs = remainingMs < configuredDurationMs
          ? (remainingMs - 150).clamp(500, configuredDurationMs).toInt()
          : configuredDurationMs;

      await session.setVolume(_effectiveCrossfadeMaster.clamp(0.0, 1.0));
      if (!stillOwnsTransition()) return;
      if (_djSfxActive) {
        await _engageDjTransitionSfx(
          energyScore: _lastDjEnergyScore,
          transitionKind: preparation?.transitionKind,
          outgoingProfile: preparation?.outgoingProfile,
        );
      }
      if (!stillOwnsTransition()) return;

      await ResonateDiagnostics.record('media3_crossfade_start', {
        'outgoingSongId': outgoingSong.id,
        'incomingSongId': nextSong.id,
        'queueIndex': nextIndex,
        'durationMs': durationMs,
        'remainingMs': remainingMs,
        'incomingStartMs': preparation?.incomingStartPosition.inMilliseconds ?? 0,
        'activeSpeed': preparation?.activeSpeed ?? 1.0,
        'standbySpeed': preparation?.standbySpeed ?? 1.0,
      });
      // Subscribe before issuing the command so a fast native handoff cannot
      // be missed by the provider's completion observer.
      final promoted = session.stateStream.firstWhere(
        (state) =>
            state.currentSong?.id == nextSong.id &&
            state.queueIndex == nextIndex &&
            state.isPlaying,
      );
      await session.crossfade(duration: Duration(milliseconds: durationMs));

      var elapsedMs = 0;
      var lastTick = DateTime.now();
      while (session.currentSong?.id != nextSong.id ||
          session.queueIndex != nextIndex) {
        await Future<void>.delayed(const Duration(milliseconds: 36));
        final now = DateTime.now();
        if (session.isPlaying) {
          elapsedMs += now.difference(lastTick).inMilliseconds;
        }
        lastTick = now;
        if (!stillOwnsTransition()) return;
        if (_djSfxEngaged) {
          await _tickDjClubFxSweep(
            (elapsedMs / durationMs).clamp(0.0, 1.0).toDouble(),
          );
        }
        if (elapsedMs > durationMs + 8000) {
          throw TimeoutException('Media3 native crossfade did not promote the incoming deck.');
        }
      }
      await promoted;
      if (!stillOwnsTransition()) return;

      await session.setDeckPlaybackSpeeds(
        activeSpeed: 1.0,
        standbySpeed: 1.0,
      );
      await session.setVolume(_effectiveCrossfadeMaster.clamp(0.0, 1.0));
      await _restoreDjTransitionSfx();
      _preloadedNextSongId = null;
      _media3DjTransitionPreparation = null;
      _lastCompletionSongId = null;
      _crossfadeInProgress = false;
      _automaticCrossfadeInFlight = false;
      _transitionArmedAt = null;
      _reconcileMedia3ProviderSession();
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.record('media3_crossfade_committed', {
        'outgoingSongId': outgoingSong.id,
        'incomingSongId': nextSong.id,
        'queueIndex': _queueIndex,
        'positionMs': session.position.inMilliseconds,
        'playing': session.isPlaying,
      });
    } catch (error) {
      if (stillOwnsTransition()) {
        try {
          await session.cancelCrossfade();
          await session.setDeckPlaybackSpeeds(
            activeSpeed: 1.0,
            standbySpeed: 1.0,
          );
          await _restoreDjTransitionSfx();
          // Safe same-session fallback: load the selected occurrence into the
          // active Media3 deck. Never revive either legacy just_audio player.
          await session.loadQueue(_queue, startIndex: nextIndex);
          await session.setVolume(_effectiveCrossfadeMaster.clamp(0.0, 1.0));
          await session.play();
          _reconcileMedia3ProviderSession();
          await ResonateDiagnostics.record('media3_crossfade_fallback', {
            'outgoingSongId': outgoingSong.id,
            'incomingSongId': nextSong.id,
            'queueIndex': nextIndex,
            'error': error.toString(),
          });
        } catch (fallbackError) {
          await ResonateDiagnostics.record('media3_crossfade_failed', {
            'outgoingSongId': outgoingSong.id,
            'incomingSongId': nextSong.id,
            'error': error.toString(),
            'fallbackError': fallbackError.toString(),
          });
        }
      }
      _preloadedNextSongId = null;
      _media3DjTransitionPreparation = null;
      await _restoreDjTransitionSfx();
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
    }
  }

  /// Same-track repeat-one handoff on the physical standby deck. The
  /// canonical queue occurrence remains unchanged; only the active A/B deck
  /// changes after the native equal-power fade has completed.
  Future<void> _runMedia3RepeatSelfCrossfade({
    required int loopMs,
    required int remainingMs,
  }) async {
    final session = _media3ProviderSession;
    final song = currentSong;
    final queueIndex = _queueIndex;
    if (session == null ||
        !_media3ProviderSessionActive ||
        song == null ||
        queueIndex < 0 ||
        queueIndex >= _queue.length ||
        !session.isPlaying) {
      _repeatSelfHandoffInFlight = false;
      _automaticCrossfadeInFlight = false;
      _transitionArmedAt = null;
      return;
    }

    final generation = ++_automaticTransitionGeneration;
    final transportEpoch = _userTransportEpoch;
    final outgoingDeckId = _media3ShadowState?.activeDeckId ?? 'A';
    final durationMs = math.min(loopMs, remainingMs - 180)
        .clamp(500, 4000)
        .toInt();
    bool stillOwnsTransition() =>
        _media3ProviderSessionActive &&
        !_disposed &&
        generation == _automaticTransitionGeneration &&
        transportEpoch == _userTransportEpoch &&
        !_transportInFlight &&
        !_userTransportPending &&
        _userWantsPlaying &&
        effectiveCrossfadeEnabled &&
        _repeatMode == PlaybackRepeatMode.one;

    try {
      // Prevent the outgoing deck from repeating itself while the incoming
      // copy is being prepared and faded in. The new active deck is restored
      // to repeat-one immediately after promotion.
      await session.setRepeatMode(PlaybackQueueRepeatMode.off);
      if (!stillOwnsTransition()) return;

      await session.preloadNext(
        song,
        queueIndex: queueIndex,
        startPosition: Duration.zero,
      );
      if (!stillOwnsTransition()) {
        await session.cancelCrossfade();
        return;
      }
      _preloadedNextSongId = song.id;
      await session.setDeckPlaybackSpeeds(
        activeSpeed: 1.0,
        standbySpeed: 1.0,
      );
      if (!stillOwnsTransition()) {
        await session.cancelCrossfade();
        return;
      }

      _crossfadeInProgress = true;
      final promoted = session.stateStream.firstWhere(
        (state) => state.activeDeckId != outgoingDeckId && state.isPlaying,
      );
      await ResonateDiagnostics.record('media3_repeat_self_crossfade_start', {
        'songId': song.id,
        'queueIndex': queueIndex,
        'fromDeck': outgoingDeckId,
        'durationMs': durationMs,
        'remainingMs': remainingMs,
      });
      await session.crossfade(duration: Duration(milliseconds: durationMs));
      final promotedState = await promoted.timeout(
        Duration(milliseconds: durationMs + 6500),
        onTimeout: () => throw TimeoutException(
          'Media3 repeat-one standby deck was not promoted.',
        ),
      );
      if (!stillOwnsTransition()) return;

      await session.setDeckPlaybackSpeeds(
        activeSpeed: 1.0,
        standbySpeed: 1.0,
      );
      await session.setRepeatMode(PlaybackQueueRepeatMode.one);
      _preloadedNextSongId = null;
      _media3DjTransitionPreparation = null;
      _lastCompletionSongId = null;
      _reconcileMedia3ProviderSession();
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.record('media3_repeat_self_crossfade_committed', {
        'songId': song.id,
        'queueIndex': queueIndex,
        'fromDeck': outgoingDeckId,
        'toDeck': promotedState.activeDeckId,
        'positionMs': promotedState.position.inMilliseconds,
      });
    } catch (error) {
      if (stillOwnsTransition()) {
        try {
          await session.cancelCrossfade();
          await session.setDeckPlaybackSpeeds(
            activeSpeed: 1.0,
            standbySpeed: 1.0,
          );
          await session.setRepeatMode(PlaybackQueueRepeatMode.one);
          await ResonateDiagnostics.record('media3_repeat_self_crossfade_fallback', {
            'songId': song.id,
            'queueIndex': queueIndex,
            'error': error.toString(),
            'fallback': 'native_repeat_one_on_current_deck',
          });
        } catch (recoveryError) {
          await ResonateDiagnostics.record('media3_repeat_self_recovery_failed', {
            'songId': song.id,
            'error': error.toString(),
            'recoveryError': recoveryError.toString(),
          });
        }
      }
      _preloadedNextSongId = null;
      _media3DjTransitionPreparation = null;
    } finally {
      // A user may change repeat mode while the fade is in flight. Restore the
      // provider's latest policy, never a stale captured value.
      if (_media3ProviderSessionActive && !_disposed) {
        try {
          await session.setRepeatMode(switch (_repeatMode) {
            PlaybackRepeatMode.one => PlaybackQueueRepeatMode.one,
            PlaybackRepeatMode.all => PlaybackQueueRepeatMode.all,
            PlaybackRepeatMode.off => PlaybackQueueRepeatMode.off,
          });
        } catch (_) {}
      }
      if (generation == _automaticTransitionGeneration) {
        _crossfadeInProgress = false;
        _automaticCrossfadeInFlight = false;
        _repeatSelfHandoffInFlight = false;
        _transitionArmedAt = null;
      }
    }
  }

  Future<void> _syncMedia3ProviderQueue() async {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) return;
    await session.synchronizeQueue(_queue);
    await session.setShuffleMode(_shuffleEnabled);
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
    final selectedIndex = normalized.indexWhere((item) => item.id == song.id);
    final resolvedIndex = selectedIndex >= 0
        ? selectedIndex
        : startIndex.clamp(0, normalized.length - 1).toInt();
    final selected = normalized[resolvedIndex];
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
    _queue = nextQueue;
    _queueIndex = nextIndex;
    try {
      await session.setAudioFocusHandling(true);
      await session.loadQueue(nextQueue, startIndex: nextIndex);
      await session.setRepeatMode(switch (_repeatMode) {
        PlaybackRepeatMode.one => PlaybackQueueRepeatMode.one,
        PlaybackRepeatMode.all => PlaybackQueueRepeatMode.all,
        PlaybackRepeatMode.off => PlaybackQueueRepeatMode.off,
      });
      await session.setShuffleMode(_shuffleEnabled);
      await session.setVolume(1.0);
      await session.setGainFactors(
        trackLevel: _trackLevelingScale,
        preamp: _eqPreampUserScale,
        sleepFade: _sleepFadeScale,
        focusDuck: _isDucked ? (_audioFocusLevel == 1 ? 0.18 : MusicProvider._duckLevel) : 1.0,
      );
      if (resume && _resumeSongId == selected.id && _resumePositionMs > 0) {
        final durationMs = selected.duration.inMilliseconds;
        final safeMs = _resumePositionMs
            .clamp(0, durationMs > 0 ? durationMs : _resumePositionMs)
            .toInt();
        await session.seek(Duration(milliseconds: safeMs));
      } else {
        await session.seek(Duration.zero);
      }
      if (!_playbackIntentGate.isCurrent(intentToken)) return false;
      await session.play();

      final previousId = currentSong?.id;
      _reconcileMedia3ProviderSession();
      currentSong ??= selected;
      currentDuration ??= session.duration ?? selected.duration;
      currentPosition = session.position;
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
    final oldSongId = currentSong?.id;
    final previousQueueIndex = _queueIndex;
    final previousPosition = currentPosition;
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
          song.id == state.currentSong!.id && song.filePath.trim().isNotEmpty);
      if (matches.length == 1) {
        currentSong = matches.first;
        _queueIndex = _queue.indexOf(matches.first);
      }
    }
    if (currentSong != null && oldSongId != currentSong!.id) {
      currentDuration = state.duration ?? currentSong!.duration;
      unawaited(_finishHistoryEvent());
      unawaited(_startHistoryEvent(currentSong!));
      _lastCompletionSongId = null;
    }
    currentPosition = state.position;
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

  Future<void> _handleMedia3ProviderCompletion(String completedSongId) async {
    if (!_media3ProviderSessionActive || _disposed) return;
    _endOfTrackWatchdog?.cancel();
    _endOfTrackWatchdog = null;
    final completedSong = currentSong;
    if (completedSong != null && completedSong.id == completedSongId) {
      _modes?.onPlaybackCompleted(completedSong);
    }
    currentPosition = currentDuration ?? currentPosition;
    _userWantsPlaying = true;
    _publishServiceState();
    notifyListeners();
    await ResonateDiagnostics.record('media3_provider_completion_observed', {
      'songId': completedSongId,
      'queueIndex': _queueIndex,
      'queueLength': _queue.length,
      'repeatMode': _repeatMode.name,
    });
    if (!_completionAdvanceInProgress) {
      await onTrackEnded(completedSongId);
    }
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
    unawaited(() async {
      try {
        if (!stillOwnsRecovery()) return;
        if (await _isCommunicationActive()) return;
        if (!stillOwnsRecovery()) return;
        await session.setAudioFocusHandling(true);
        // This is the critical stale-work barrier: never let a watchdog that
        // began before Pause issue play() after the user's newer command.
        if (!stillOwnsRecovery()) return;
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
