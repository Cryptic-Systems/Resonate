part of 'music_provider.dart';

/// Serialized transport commands separated from the core provider body.
/// Kept in the same Dart library to preserve access to private transport state.
extension MusicProviderTransport on MusicProvider {
Future<bool> playSong(Song song, {List<Song>? queue, int startIndex = 0, bool resumeIfPossible = false, int? resumeAtMs}) {
    final intentToken = _playbackIntentGate.issue();
    final wasXf = _crossfadeInProgress || _automaticCrossfadeInFlight;
    _cancelAutomaticPlaybackWork();
    if (wasXf) {
      unawaited(ResonateDiagnostics.record('crossfade_preempted_by_user', {
        'stage': 'play_song',
        'requestedSongId': song.id,
        'wasSongId': currentSong?.id,
        'queueIndex': _queueIndex,
      }));
    }
    _lastCompletionSongId = null;
    if (resumeAtMs != null && resumeAtMs > 1500) {
      _resumeSongId = song.id;
      _resumePositionMs = resumeAtMs;
      _resumeStore.bySongId[song.id] = resumeAtMs;
    } else if (resumeIfPossible) {
      final mapped = resumePositionFor(song.id);
      if (mapped != null) {
        _resumeSongId = song.id;
        _resumePositionMs = mapped;
      }
    }
    // Precise resume is a Mode playback policy. Normal/routine modes keep
    // the existing start-from-zero behavior; content/session modes that
    // explicitly require precise resume may restore the saved position.
    final shouldResume = _modePreciseResume &&
        resumeIfPossible &&
        _resumeSongId == song.id &&
        _resumePositionMs > 1500;
    return _serializePlayback(
      () => _playSongInternal(song, queue: queue, startIndex: startIndex, resume: shouldResume, playbackIntentToken: intentToken),
      command: 'play', source: 'normal_player', userInitiated: true, intentToken: intentToken,
      onSuperseded: () async => false,
    );
  }

Future<void> pause({String source = 'normal_player'}) {
    final intentToken = _playbackIntentGate.issue();
    final fromSystemFocus = source == 'system';
    final fromNoisy = source == 'becoming_noisy';
    // Clear user intent immediately (before async lane) so stream listeners and
    // ensureAudiblePlayback cannot race a late play() back in.
    if (!fromSystemFocus) {
      _userWantsPlaying = false;
      isPlaying = false;
      _lastUserPauseAt = DateTime.now();
      _volumeFadeGen++;
      _cancelAutomaticPlaybackWork();
      _crossfadeInProgress = false;
      _automaticCrossfadeInFlight = false;
      _repeatSelfHandoffInFlight = false;
      notifyListeners();
      _publishServiceState();
    }
    return _serializePlayback(() async {
      try {
        if (!fromSystemFocus) {
          _userWantsPlaying = false;
        }
        if (_media3ProviderSession != null) {
          final session = (await _ensureMedia3ProviderSessionActive())!;
          // Legacy engines are disposed at handoff. Pause the canonical session
          // directly; never recreate a Flutter player as a silence barrier.
          await session.pause();
          // A pause is an explicit relinquishment of media focus. This also
          // closes the race where a resume enabled focus while session startup
          // was completing immediately before the pause took ownership.
          await session.setAudioFocusHandling(false);
          unawaited(ResonateDiagnostics.record('media3_pause_canonical_only', {
            'legacyEnginesRetired': _legacyEnginesRetired,
            'transportEpoch': _userTransportEpoch,
          }));
          this._reconcileMedia3ProviderSession();
          isPlaying = session.isPlaying;
          _isDucked = false;
          _persistResumePosition(force: true);
          _podcastSession.onPaused(currentPosition);
          _audiobookSession.onPaused(currentPosition);
          _modes?.onPlaybackPaused();
          _publishServiceState();
          notifyListeners();
          return;
        }
        final midTransition =
            _crossfadeInProgress || _repeatSelfHandoffInFlight;
        if (_audioFocusSettings.pauseResumeFadeEnabled && !midTransition && !fromSystemFocus) {
          await _fadePlayerVolume(
            audioPlayer,
            _effectiveCrossfadeMaster,
            0.0,
            durationMs: MusicProvider._transportFadeMs,
            steps: 6,
          );
        }
        try {
          await audioPlayer.pause();
        } catch (_) {}
        try {
          await inactivePlayer.pause();
        } catch (_) {}
        try {
          await _playerA.pause();
        } catch (_) {}
        try {
          await _playerB.pause();
        } catch (_) {}
        if (!midTransition) {
          try {
            await audioPlayer.setVolume(_effectiveCrossfadeMaster.clamp(0.0, 1.0));
          } catch (_) {}
          try {
            await inactivePlayer.setVolume(0.0);
          } catch (_) {}
        }
        isPlaying = false;
        _isDucked = false;
        _persistResumePosition(force: true);
        _podcastSession.onPaused(currentPosition);
    _audiobookSession.onPaused(currentPosition);
        _modes?.onPlaybackPaused();
        _publishServiceState();
        notifyListeners();
        // Diagnostics must not hold the serialized transport lane: a slow
        // write here can block the next play/resume command after pause.
        unawaited(ResonateDiagnostics.record('audio_focus_pause', {
          'source': source,
          'userWantsPlaying': _userWantsPlaying,
          'preservedIntent': fromSystemFocus,
          'hardStop': true,
          'noisy': fromNoisy,
        }));
      } catch (_) {}
    }, command: 'pause', source: source, userInitiated: !fromSystemFocus, intentToken: intentToken);
  }

Future<void> nextSong({String source = 'normal_player'}) {
    // Manual Next supersedes an automatic DJ/crossfade transition. The intent
    // token below invalidates the in-flight fade so it cannot commit afterward.
    // Keep queueing only for unrelated transport/load contention.
    if (_transportInFlight || _loadingSource) {
      _pendingNextSteps = (_pendingNextSteps + 1).clamp(0, 12);
      return Future<void>.value();
    }
    final wasCrossfadeActive = _crossfadeInProgress || _automaticCrossfadeInFlight;
    final intentToken = _playbackIntentGate.issue();
    _cancelAutomaticPlaybackWork();
    if (wasCrossfadeActive) {
      unawaited(ResonateDiagnostics.record('automatic_transition_preempted', {
        'command': 'next',
        'source': source,
        'songId': currentSong?.id,
        'queueIndex': _queueIndex,
      }));
    }

    return _serializePlayback(
      () async {
        if (_queue.isEmpty) return;
        final extra = _pendingNextSteps;
        _pendingNextSteps = 0;
        final steps = 1 + extra;
        // Phase 7: early skip after a DJ handoff → soft negative signal.
        try {
          final handoffAt = _lastDjHandoffAt;
          final fromId = _lastDjFromId;
          final toId = _lastDjToId;
          final strategy = _lastDjStrategy;
          if (handoffAt != null &&
              fromId != null &&
              toId != null &&
              strategy != null &&
              currentSong?.id == toId) {
            final age = DateTime.now().difference(handoffAt);
            final posMs = currentPosition.inMilliseconds;
            final durMs = (currentDuration ?? currentSong?.duration)?.inMilliseconds ?? 0;
            final earlyByTime = age < const Duration(seconds: 120) && posMs < 45000;
            final earlyByRatio =
                durMs > 0 && posMs < (durMs * 0.35).round() && age < const Duration(minutes: 3);
            if (earlyByTime || earlyByRatio) {
              // Heavier penalty the earlier the skip (deeper transition memory).
              final weight = posMs < 5000
                  ? 4
                  : posMs < 15000
                      ? 3
                      : posMs < 30000
                          ? 2
                          : 1;
              unawaited(DjTransitionMemory.recordOutcome(
                fromId: fromId,
                toId: toId,
                strategy: strategy,
                successful: false,
                weight: weight,
                score: _lastDjTransitionScore,
                confidence: _lastDjTransitionConfidence,
                risks: _lastDjTransitionRisks,
                transitionDurationMs: _lastDjTransitionDurationMs,
                recoveryAttempts: _lastDjRecoveryAttempts,
              ));
              unawaited(ResonateDiagnostics.recordDj(
                stage: 'learn',
                outcome: 'early_skip',
                reason: strategy,
                songId: toId,
                extra: {
                  'fromId': fromId,
                  'positionMs': posMs,
                  'weight': weight,
                  'ageMs': age.inMilliseconds,
                },
              ));
              _lastDjHandoffAt = null;
            }
          }
        } catch (_) {}
        _transportInFlight = true;
        try {
          if (_media3ProviderSession != null) {
            final session = (await _ensureMedia3ProviderSessionActive())!;
            for (var i = 0; i < steps.clamp(1, 12); i++) {
              if (!_playbackIntentGate.isCurrent(intentToken)) break;
              await session.next();
            }
            this._reconcileMedia3ProviderSession();
            isPlaying = session.isPlaying;
            currentPosition = session.position;
            currentDuration = session.duration ?? currentSong?.duration;
            _publishServiceState();
            notifyListeners();
            return;
          }
          var stepsLeft = steps.clamp(1, 12);
          while (stepsLeft > 0) {
            stepsLeft--;
            if (_queue.isEmpty) break;
            if (_queueIndex >= _queue.length - 1) {
              if (_repeatMode == PlaybackRepeatMode.all) {
                await _playSongInternal(_queue.first, queue: _queue, startIndex: 0, playbackIntentToken: intentToken);
              } else if (_repeatMode == PlaybackRepeatMode.one && currentSong != null) {
                await _playSongInternal(currentSong!, queue: _queue, startIndex: _queueIndex, playbackIntentToken: intentToken);
              }
              break;
            }
            final nextIndex = _queueIndex + 1;
            if (await _tryGaplessSeekToQueueIndex(nextIndex)) {
              if (_pendingNextSteps > 0 && stepsLeft == 0) {
                stepsLeft = _pendingNextSteps.clamp(0, 12);
                _pendingNextSteps = 0;
              }
              continue;
            }
            await _playSongInternal(
              _queue[nextIndex],
              queue: _queue,
              startIndex: nextIndex,
              playbackIntentToken: intentToken,
            );
            if (_pendingNextSteps > 0 && stepsLeft == 0) {
              stepsLeft = _pendingNextSteps.clamp(0, 12);
              _pendingNextSteps = 0;
            }
          }
        } finally {
          _transportInFlight = false;
          unawaited(_refreshTrackLevelingFor(currentSong));
          if (_pendingNextSteps > 0) {
            final again = _pendingNextSteps;
            _pendingNextSteps = 0;
            unawaited(Future<void>.delayed(const Duration(milliseconds: 40), () {
              for (var i = 0; i < again; i++) {
                unawaited(this.nextSong(source: source));
              }
            }));
          }
        }
      },
      command: 'next',
      source: source,
      userInitiated: true,
      intentToken: intentToken,
      onSuperseded: () async {},
    );
  }

Future<void> previousSong({String source = 'normal_player'}) {
    final intentToken = _playbackIntentGate.issue();
    _cancelAutomaticPlaybackWork();

    return _serializePlayback(
      () async {
        _transportInFlight = true;
        try {
          if (_media3ProviderSession != null) {
            final session = (await _ensureMedia3ProviderSessionActive())!;
            await session.previous();
            this._reconcileMedia3ProviderSession();
            isPlaying = session.isPlaying;
            currentPosition = session.position;
            currentDuration = session.duration ?? currentSong?.duration;
            _publishServiceState();
            notifyListeners();
            return;
          }
          if (_queueIndex > 0) {
            final previousIndex = _queueIndex - 1;
            if (await _tryGaplessSeekToQueueIndex(previousIndex)) return;
            await _playSongInternal(
              _queue[previousIndex],
              queue: _queue,
              startIndex: previousIndex,
              playbackIntentToken: intentToken,
            );
          } else {
            await audioPlayer.seek(Duration.zero);
            currentPosition = Duration.zero;
            if (_historySession.activeEvent != null) _historySession.positionMs = 0;
            _persistResumePosition(force: true);
            notifyListeners();
            _publishServiceState();
          }
        } finally {
          _transportInFlight = false;
          unawaited(_refreshTrackLevelingFor(currentSong));
        }
      },
      command: 'previous',
      source: source,
      userInitiated: true,
      intentToken: intentToken,
      onSuperseded: () async {},
    );
  }

Future<void> seek(Duration position, {String source = 'normal_player'}) {
    final intentToken = _playbackIntentGate.issue();
    final injectedSession = _media3ProviderSession;
    _cancelAutomaticPlaybackWork();
    return _serializePlayback(
      () async {
        if (!_playbackIntentGate.isCurrent(intentToken)) return;
        try {
          final session = injectedSession == null
              ? null
              : await _ensureMedia3ProviderSessionActive();
          if (!_playbackIntentGate.isCurrent(intentToken) || _disposed) return;
          if (injectedSession != null &&
              (!identical(injectedSession, _media3ProviderSession) ||
                  !identical(session, injectedSession) ||
                  !_media3ProviderSessionActive)) {
            return;
          }
          if (injectedSession == null && _legacyEnginesRetired) return;
          final duration = session != null
              ? (session.duration ?? currentDuration ?? Duration.zero)
              : (audioPlayer.duration ?? currentDuration ?? Duration.zero);
          final fromMs = currentPosition.inMilliseconds;
          final safe = Duration(
            milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds).toInt(),
          );
          if (session != null) {
            await session.seek(safe);
            if (!_playbackIntentGate.isCurrent(intentToken) || _disposed) return;
            currentPosition = session.position;
            isPlaying = session.isPlaying;
          } else {
            await audioPlayer.seek(safe);
            if (!_playbackIntentGate.isCurrent(intentToken) || _disposed) return;
            currentPosition = safe;
          }
          currentPosition = safe;
          if (_historySession.activeEvent != null) {
            _historySession.positionMs = safe.inMilliseconds;
          }
          // Local seek/replay evidence for Intelligence ranking (no audio content).
          final songId = currentSong?.id;
          if (songId != null && (fromMs - safe.inMilliseconds).abs() > 2500) {
            unawaited(IntelligenceSeekMemory().record(
              songId: songId,
              fromMs: fromMs,
              toMs: safe.inMilliseconds,
            ));
          }
          _persistResumePosition(force: true);
          _publishServiceState();
          notifyListeners();
        } catch (e) {
          debugPrint('Seek failed: $e');
        }
      },
      command: 'seek',
      source: source,
      userInitiated: true,
      intentToken: intentToken,
    );
  }


  /// Remaining public transport operations and queue-aware navigation helpers.
  Future<bool> playQueueIndex(int index) {
    if (_queue.isEmpty || index < 0 || index >= _queue.length) {
      return Future<bool>.value(false);
    }
    final wasCrossfadeActive =
        _crossfadeInProgress || _automaticCrossfadeInFlight;
    final intentToken = _playbackIntentGate.issue();
    // Explicit queue selection has the same priority as Play Song/Next:
    // invalidate any native standby transition before loading the requested
    // occurrence. Clearing only the Dart flags leaves Media3 free to promote
    // its stale preload after the user's selection.
    _cancelAutomaticPlaybackWork();
    if (wasCrossfadeActive) {
      unawaited(ResonateDiagnostics.record('automatic_transition_preempted', {
        'command': 'play_queue_index',
        'songId': currentSong?.id,
        'requestedSongId': _queue[index].id,
        'queueIndex': index,
      }));
    }
    _completionAdvanceInProgress = false;
    _lastCompletionSongId = null;
    return _serializePlayback(
      () => _playSongInternal(
        _queue[index],
        queue: _queue,
        startIndex: index,
        playbackIntentToken: intentToken,
      ),
      command: 'play',
      source: 'normal_player',
      userInitiated: true,
      intentToken: intentToken,
      onSuperseded: () async => false,
    );
  }

  Future<void> resumePlayback({String source = 'normal_player'}) {
    _podcastSession.onResumed(currentPosition);
    _audiobookSession.onResumed(currentPosition);
    _modes?.onPlaybackResumed(currentSong);
    final intentToken = _playbackIntentGate.issue();
    final injectedSession = _media3ProviderSession;
    bool stillOwnsResume([PlaybackEngineSession? session]) =>
        !_disposed &&
        _playbackIntentGate.isCurrent(intentToken) &&
        (injectedSession == null
            ? !_legacyEnginesRetired
            : identical(injectedSession, _media3ProviderSession) &&
                (session == null ||
                    (_media3ProviderSessionActive &&
                        identical(session, injectedSession))));
    _cancelAutomaticPlaybackWork();
    return _serializePlayback(() async {
      try {
        if (!stillOwnsResume()) return;
        final communicationActive = await _isCommunicationActive();
        if (!stillOwnsResume()) return;
        if (communicationActive) {
          _userWantsPlaying = false;
          isPlaying = false;
          await ResonateDiagnostics.record('playback_blocked_communication', {
            'source': source,
            'songId': currentSong?.id,
          });
          _publishServiceState();
          notifyListeners();
          return;
        }
        if (injectedSession != null) {
          final session = await _ensureMedia3ProviderSessionActive();
          if (session == null || !stillOwnsResume(session)) return;

          // Session activation is asynchronous. A call or a newer transport
          // intent can arrive while it is starting; neither may be overwritten
          // by this now-stale resume request.
          if (await _isCommunicationActive()) {
            if (!stillOwnsResume(session)) return;
            _userWantsPlaying = false;
            isPlaying = false;
            await session.setAudioFocusHandling(false);
            await ResonateDiagnostics.record(
              'playback_blocked_communication_after_media3_activation',
              {'source': source, 'songId': currentSong?.id},
            );
            _publishServiceState();
            notifyListeners();
            return;
          }
          if (!stillOwnsResume(session)) return;

          await session.setAudioFocusHandling(true);
          // Focus handling itself crosses the platform boundary. Revalidate
          // both communication policy and transport ownership before play.
          if (!stillOwnsResume(session)) {
            try {
              await session.setAudioFocusHandling(false);
            } catch (_) {}
            return;
          }
          if (await _isCommunicationActive()) {
            if (!stillOwnsResume(session)) {
              try {
                await session.setAudioFocusHandling(false);
              } catch (_) {}
              return;
            }
            _userWantsPlaying = false;
            isPlaying = false;
            await session.setAudioFocusHandling(false);
            await ResonateDiagnostics.record(
              'playback_blocked_communication_after_media3_focus',
              {'source': source, 'songId': currentSong?.id},
            );
            _publishServiceState();
            notifyListeners();
            return;
          }
          if (!stillOwnsResume(session)) {
            try {
              await session.setAudioFocusHandling(false);
            } catch (_) {}
            return;
          }

          _userWantsPlaying = true;
          _isDucked = false;
          if (session.currentSong == null && currentSong != null) {
            await _playSongInternal(
              currentSong!,
              queue: _queue,
              startIndex: _queueIndex,
              resume: true,
              playbackIntentToken: intentToken,
            );
          } else {
            await session.play();
          }
          if (!stillOwnsResume(session)) return;
          this._reconcileMedia3ProviderSession();
          isPlaying = session.isPlaying;
          currentPosition = session.position;
          currentDuration = session.duration ?? currentSong?.duration;
          _publishServiceState();
          notifyListeners();
          return;
        }
        if (source != 'system' &&
            !await _claimAudioFocus(reason: 'resume_$source')) {
          if (!stillOwnsResume()) return;
          _userWantsPlaying = false;
          isPlaying = false;
          return;
        }
        if (!stillOwnsResume()) return;
        _userWantsPlaying = true;
        _isDucked = false;
        if (audioPlayer.audioSource != null) {
          // If we are sitting on a completed source, seek to zero first.
          if (audioPlayer.processingState == ProcessingState.completed) {
            try {
              await audioPlayer.seek(Duration.zero);
            } catch (_) {}
          }
          if (!stillOwnsResume()) return;
          final midTransition = _transitionLive;
          final target = _effectiveCrossfadeMaster.clamp(0.0, 1.0);
          // Start quiet then fade in (skip only during a real ramp).
          if (!midTransition && _audioFocusSettings.pauseResumeFadeEnabled) {
            try {
              await audioPlayer.setVolume(0.0);
            } catch (_) {}
          }
          if (!stillOwnsResume()) return;
          var attempts = 0;
          while (attempts < 12) {
            if (!stillOwnsResume()) return;
            if (attempts == 0 || attempts == 3 || attempts == 6) {
              try {
                audioPlayer.play();
              } catch (_) {}
            }
            attempts++;
            await Future<void>.delayed(const Duration(milliseconds: 90));
            if (!stillOwnsResume()) return;
            if (audioPlayer.playing) break;
          }
          final midTransitionAfterStart = _transitionLive;
          if (!midTransitionAfterStart && audioPlayer.playing && _audioFocusSettings.pauseResumeFadeEnabled) {
            await _fadePlayerVolume(
              audioPlayer,
              0.0,
              target,
              durationMs: MusicProvider._transportFadeMs,
              steps: 6,
            );
          } else if (!midTransitionAfterStart) {
            await audioPlayer.setVolume(target);
          }
          if (!stillOwnsResume()) return;
          isPlaying = audioPlayer.playing || _userWantsPlaying;
          _publishServiceState();
          await ResonateDiagnostics.record('resume_playback', {
            'source': source,
            'playing': audioPlayer.playing,
            'attempts': attempts,
          });
          notifyListeners();
          return;
        }
        if (currentSong != null) {
          await _playSongInternal(
            currentSong!,
            queue: _queue,
            startIndex: _queueIndex,
            resume: true,
            playbackIntentToken: intentToken,
          );
        }
      } catch (e) {
        debugPrint('resumePlayback failed: $e');
      }
    }, command: 'play', source: source, userInitiated: source != 'system', intentToken: intentToken);
  }

  Future<void> togglePlayPause({String source = 'normal_player'}) {
    // The UI/intent flags can remain optimistic while an OEM player has
    // actually stopped. Decide from both engines' native state so the mini
    // player can recover playback instead of repeatedly issuing pause.
    final nativePlaybackActive = _media3ProviderSession != null
        ? _media3ProviderSession!.isPlaying
        : (_playerA.playing || _playerB.playing);
    if (nativePlaybackActive) {
      return this.pause(source: source);
    }
    return resumePlayback(source: source);
  }


  

  Future<void> stop({String source = 'normal_player'}) {
    final intentToken = _playbackIntentGate.issue();
    _cancelAutomaticPlaybackWork();
    return _serializePlayback(() async {
      if (!_playbackIntentGate.isCurrent(intentToken)) return;
      _userWantsPlaying = false;
      _podcastSession.onStopped(currentPosition);
    _audiobookSession.onStopped(currentPosition);
      _modes?.onPlaybackStopped();
      await _finishHistoryEvent();
      if (_media3ProviderSession != null) {
        final session = (await _ensureMedia3ProviderSessionActive())!;
        await session.stop();
        await session.setAudioFocusHandling(false);
      } else {
        await _stopBoth();
      }
      isPlaying = false;
      currentPosition = Duration.zero;
      // Abandon audio focus so other apps can play without mixing with us.
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
      } catch (e) {
        debugPrint('AudioSession setActive(false) on stop failed: $e');
      }
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.record('audio_focus_stop', {'source': source});
    }, command: 'stop', source: source, userInitiated: true, intentToken: intentToken);
  }

  Future<bool> _tryGaplessSeekToQueueIndex(int queueIndex) async {
    if (_media3ProviderSessionActive) return false;
    if (!_gaplessWindow.active || effectiveCrossfadeEnabled) return false;
    if (queueIndex < 0 || queueIndex >= _queue.length) return false;
    final song = _queue[queueIndex];
    final local = _gaplessWindow.songIds.indexOf(song.id);
    if (local < 0) return false;
    try {
      await audioPlayer.seek(Duration.zero, index: local);
      _queueIndex = queueIndex;
      currentSong = song;
      unawaited(_refreshTrackLevelingFor(currentSong));
      currentDuration = song.duration ?? audioPlayer.duration;
      currentPosition = Duration.zero;
      isPlaying = true;
      _userWantsPlaying = true;
      try {
        audioPlayer.play();
      } catch (_) {}
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.record('playback_gapless_seek', {
        'localIndex': local,
        'queueIndex': queueIndex,
        'songId': song.id,
      });
      return true;
    } catch (e) {
      debugPrint('Gapless seek failed: $e');
      return false;
    }
  }

  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) {
      await _finishHistoryEvent();
      _queue = <Song>[];
      _queueIndex = 0;
      if (_media3ProviderSession != null) {
        final session = (await _ensureMedia3ProviderSessionActive())!;
        await session.clearQueue();
        await session.stop();
      }
      await _persistQueue();
      notifyListeners();
      return;
    }
    final index = startIndex.clamp(0, songs.length - 1).toInt();
    await this.playSong(songs[index], queue: songs, startIndex: index);
  }
}
