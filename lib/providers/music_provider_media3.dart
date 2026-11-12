part of 'music_provider.dart';

/// Canonical provider integration for the injected Media3 session.
/// Every method here reads and writes the same session; just_audio is not a
/// fallback once the handoff has been committed.
extension MusicProviderMedia3 on MusicProvider {
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
    if (!state.isCompleted &&
        state.position + const Duration(seconds: 1) < previousPosition) {
      _lastCompletionSongId = null;
    }
    currentDuration = state.duration ?? currentSong?.duration;
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
    if (!state.isPlaying && !state.isBuffering && !state.isCompleted) {
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
    unawaited(() async {
      if (await _isCommunicationActive()) return;
      try {
        await session.setAudioFocusHandling(true);
        await session.play();
        await ResonateDiagnostics.record('media3_provider_recovery', {
          'songId': session.currentSong?.id ?? currentSong?.id,
          'playing': session.isPlaying,
          'positionMs': session.position.inMilliseconds,
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
