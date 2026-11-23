part of 'music_provider.dart';

/// Apply tempo correction only when both beat grids are trustworthy and
/// genuinely close. A plausible but wrong BPM octave can otherwise produce
/// a severe slow-motion / granular-sounding incoming deck on cross-genre pairs.
DjTempoStretchPlan? _safeProfileTempoStretch(
  DjTrackProfile outgoing,
  DjTrackProfile incoming, {
  required DjTransitionCandidate candidate,
  required int maxStretchPercent,
}) {
  final a = outgoing.beatGrid;
  final b = incoming.beatGrid;
  if (!a.usable ||
      !b.usable ||
      candidate.risks.contains(DjRiskType.tempoInstability)) {
    return null;
  }

  return computeSafeTempoStretch(
    bpmA: a.bpm!,
    bpmB: b.bpm!,
    confidenceA: a.confidence,
    confidenceB: b.confidence,
    maxStretchPercent: maxStretchPercent,
  );
}
/// A standby deck prepared for an explicit operator handoff. Queue occurrence
/// identity is retained so duplicate song IDs cannot silently retarget Deck B.
class ManualDjPreparedDeck {
  const ManualDjPreparedDeck({
    required this.outgoingSong,
    required this.incomingSong,
    required this.outgoingQueueIndex,
    required this.incomingQueueIndex,
    required this.cuePosition,
  });

  final Song outgoingSong;
  final Song incomingSong;
  final int outgoingQueueIndex;
  final int incomingQueueIndex;
  final Duration cuePosition;

  ManualDjPreparedDeck withCue(Duration value) => ManualDjPreparedDeck(
        outgoingSong: outgoingSong,
        incomingSong: incomingSong,
        outgoingQueueIndex: outgoingQueueIndex,
        incomingQueueIndex: incomingQueueIndex,
        cuePosition: value,
      );
}

extension MusicProviderDjHandoff on MusicProvider {

  Future<void> previewDjTransition({
    required Uri outgoingUri, required Uri incomingUri,
    required Duration outgoingStart, required Duration incomingStart,
    required Duration duration,
  }) async {
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) {
      throw StateError('Start a track once to activate Media3 before auditioning a DJ transition.');
    }
    if (session is! PlaybackTransitionPreviewBackend) {
      throw UnsupportedError('The active playback session does not support isolated DJ preview.');
    }
    await (session as PlaybackTransitionPreviewBackend).playTransitionPreview(
      outgoingUri: outgoingUri, incomingUri: incomingUri,
      outgoingStart: outgoingStart, incomingStart: incomingStart, duration: duration,
    );
  }

  Future<void> stopDjTransitionPreview() async {
    final session = _media3ProviderSession;
    if (session is PlaybackTransitionPreviewBackend) {
      await (session as PlaybackTransitionPreviewBackend).stopTransitionPreview();
    }
  }

  bool _sameManualDjEntry(Song candidate, Song expected) =>
      candidate.id == expected.id &&
      candidate.filePath.trim() == expected.filePath.trim();

  /// Maps the native queue onto Resonate's operator-facing queue by
  /// ordered media identity. Native playback may omit entries that remain in
  /// the provider queue; never infer a native index from an original index.
  /// Returning null means the two queues cannot be reconciled safely.
  Map<int, int>? _manualDjNativeQueueIndices(List<Song> nativeQueue) {
    final indices = <int, int>{};
    var originalCursor = 0;
    for (var nativeIndex = 0;
        nativeIndex < nativeQueue.length;
        nativeIndex++) {
      final nativeSong = nativeQueue[nativeIndex];
      while (originalCursor < _queue.length &&
          !_sameManualDjEntry(_queue[originalCursor], nativeSong)) {
        originalCursor++;
      }
      if (originalCursor >= _queue.length) return null;
      indices[originalCursor] = nativeIndex;
      originalCursor++;
    }
    return indices;
  }

  bool _manualDjPreparedDeckIsCurrent(
    PlaybackEngineSession session,
    ManualDjPreparedDeck prepared,
  ) {
    final currentSong = session.currentSong;
    final nativeQueue = session.queue;
    final nativeIndices = _manualDjNativeQueueIndices(nativeQueue);
    final outgoingNativeIndex = nativeIndices?[prepared.outgoingQueueIndex];
    final incomingNativeIndex = nativeIndices?[prepared.incomingQueueIndex];
    // PreparedDeck stores original Resonate queue occurrences. Resolve both
    // through the current native playlist and require an ordered identity map.
    return _media3ProviderSessionActive &&
        !_disposed &&
        currentSong != null &&
        nativeIndices != null &&
        outgoingNativeIndex != null &&
        incomingNativeIndex != null &&
        outgoingNativeIndex != incomingNativeIndex &&
        _queueStore.index == prepared.outgoingQueueIndex &&
        _sameManualDjEntry(currentSong, prepared.outgoingSong) &&
        session.queueIndex == outgoingNativeIndex &&
        _sameManualDjEntry(
          nativeQueue[outgoingNativeIndex],
          prepared.outgoingSong,
        ) &&
        _sameManualDjEntry(
          _queue[prepared.outgoingQueueIndex],
          prepared.outgoingSong,
        ) &&
        _sameManualDjEntry(
          _queue[prepared.incomingQueueIndex],
          prepared.incomingSong,
        ) &&
        _sameManualDjEntry(
          nativeQueue[incomingNativeIndex],
          prepared.incomingSong,
        );
  }

  Future<void> prepareManualDjDeck({
    required int incomingQueueIndex,
    Duration incomingStartPosition = Duration.zero,
  }) async {
    await cancelPreparedManualDjDeck();
    final session = _media3ProviderSession;
    if (session == null || !_media3ProviderSessionActive) {
      throw StateError('Media3 playback must be active before preparing Deck B.');
    }
    if (!session.isPlaying) {
      throw StateError('Resume playback before preparing Deck B.');
    }
    final outgoingSong = session.currentSong;
    final committedQueue = session.queue;
    final nativeIndices = _manualDjNativeQueueIndices(committedQueue);
    final outgoingNativeIndex = session.queueIndex;
    int? outgoingIndex;
    if (nativeIndices != null && outgoingNativeIndex != null) {
      for (final entry in nativeIndices.entries) {
        if (entry.value == outgoingNativeIndex) {
          outgoingIndex = entry.key;
          break;
        }
      }
    }
    if (outgoingSong == null ||
        outgoingNativeIndex == null ||
        outgoingIndex == null ||
        _queueStore.index != outgoingIndex ||
        incomingQueueIndex < 0 ||
        incomingQueueIndex >= _queue.length ||
        incomingQueueIndex == outgoingIndex) {
      throw ArgumentError.value(
        incomingQueueIndex,
        'incomingQueueIndex',
        'Choose a different playable track occurrence from the active queue.',
      );
    }
    final incomingSong = _queue[incomingQueueIndex];
    final incomingNativeIndex = nativeIndices?[incomingQueueIndex];
    if (nativeIndices == null ||
        incomingNativeIndex == null ||
        incomingNativeIndex == outgoingNativeIndex ||
        outgoingNativeIndex < 0 ||
        outgoingNativeIndex >= committedQueue.length ||
        !_sameManualDjEntry(
          committedQueue[outgoingNativeIndex],
          outgoingSong,
        ) ||
        incomingNativeIndex >= committedQueue.length ||
        !_sameManualDjEntry(
          committedQueue[incomingNativeIndex],
          incomingSong,
        )) {
      throw StateError(
        'The DJ queue changed or the selected track is not playable; refresh the workspace before preparing Deck B.',
      );
    }
    if (incomingStartPosition < Duration.zero ||
        (incomingSong.duration > Duration.zero &&
            incomingStartPosition >= incomingSong.duration)) {
      throw ArgumentError.value(
        incomingStartPosition,
        'incomingStartPosition',
        'Cue position must be non-negative and inside the incoming track.',
      );
    }

    final prepared = ManualDjPreparedDeck(
      outgoingSong: outgoingSong,
      incomingSong: incomingSong,
      outgoingQueueIndex: outgoingIndex,
      incomingQueueIndex: incomingQueueIndex,
      cuePosition: incomingStartPosition,
    );
    final lease = await playbackControlArbiter.acquire(
      owner: 'dj_manual_transition',
      priority: PlaybackControlPriority.interactive,
      onRevoked: (revocation) async {
        if (revocation.reason == PlaybackControlRevocationReason.released) return;
        final pendingPreparationSettled =
            _manualDjPreparingLease?.generation == revocation.generation
                ? _manualDjPreparationSettled
                : null;
        if (pendingPreparationSettled != null) {
          _manualDjPreparationInvalidated = true;
        }
        _manualDjPreparedDeck = null;
        _manualDjPreparedLease = null;
        // Invalidate the standby immediately, then wait for any dispatched
        // preload to settle before the arbiter grants the higher-priority
        // controller. A second cleanup fences a late native prepare result.
        Future<void> retireStandby() async {
          try { await session.cancelCrossfade(); } catch (_) {}
          try { await session.clearDeckEqOverlay(deck: 'standby'); } catch (_) {}
          try {
            await session.setDeckPlaybackSpeeds(
              activeSpeed: 1.0,
              standbySpeed: 1.0,
            );
          } catch (_) {}
        }
        await retireStandby();
        if (pendingPreparationSettled != null) {
          await pendingPreparationSettled.future;
          await retireStandby();
        }
        notifyListeners();
      },
    );
    if (lease == null) {
      throw StateError('DJ playback authority is busy; Deck B was not changed.');
    }

    final preparationDone = Completer<void>();
    final preparationSettled = Completer<void>();
    _manualDjPreparingDeck = prepared;
    _manualDjPreparingLease = lease;
    _manualDjPreparationDone = preparationDone;
    _manualDjPreparationSettled = preparationSettled;
    _manualDjPreparationInvalidated = false;

    try {
      if (!lease.authorizeWrite('dj_manual_preload')) {
        throw StateError('Manual DJ lease expired before deck preparation.');
      }
      try {
        await session.preloadNext(
          incomingSong,
          queueIndex: incomingNativeIndex,
          startPosition: incomingStartPosition,
        );
      } finally {
        if (!preparationSettled.isCompleted) preparationSettled.complete();
      }
      if (_manualDjPreparationInvalidated ||
          !identical(_manualDjPreparingLease, lease) ||
          !lease.isCurrent ||
          !_manualDjPreparedDeckIsCurrent(session, prepared)) {
        throw StateError('Manual DJ preparation was superseded.');
      }
      if (session.crossfadeStatus != 'ready') {
        throw StateError('Media3 standby deck did not reach its ready state.');
      }
      // Keep the interactive lease while the operator reviews Deck B. This
      // prevents automatic DJ work from replacing the standby occurrence.
      // User transport remains able to preempt this lease.
      _manualDjPreparingDeck = null;
      _manualDjPreparingLease = null;
      _manualDjPreparationDone = null;
      _manualDjPreparationSettled = null;
      _manualDjPreparationInvalidated = false;
      _manualDjPreparedDeck = prepared;
      _manualDjPreparedLease = lease;
      preparationDone.complete();
      await ResonateDiagnostics.recordDj(
        stage: 'manual_deck_prepare',
        outcome: 'ready',
        reason: 'operator_requested',
        songId: incomingSong.id,
        extra: {
          'outgoingSongId': outgoingSong.id,
          'incomingQueueIndex': incomingQueueIndex,
          'incomingNativeQueueIndex': incomingNativeIndex,
          'cuePositionMs': incomingStartPosition.inMilliseconds,
          'leaseHeldForReview': true,
        },
      );
      _publishServiceState();
      notifyListeners();
    } catch (error) {
      _manualDjPreparedDeck = null;
      _manualDjPreparedLease = null;
      if (identical(_manualDjPreparingLease, lease)) {
        _manualDjPreparingDeck = null;
        _manualDjPreparingLease = null;
        _manualDjPreparationDone = null;
        _manualDjPreparationSettled = null;
        _manualDjPreparationInvalidated = false;
      }
      if (!preparationSettled.isCompleted) preparationSettled.complete();
      if (lease.isCurrent) {
        try { await session.cancelCrossfade(); } catch (_) {}
        try { await session.clearDeckEqOverlay(deck: 'standby'); } catch (_) {}
        try {
          await session.setDeckPlaybackSpeeds(
            activeSpeed: 1.0,
            standbySpeed: 1.0,
          );
        } catch (_) {}
      }
      await lease.release();
      if (!preparationDone.isCompleted) preparationDone.complete();
      await ResonateDiagnostics.recordDj(
        stage: 'manual_deck_prepare',
        outcome: 'failed',
        reason: error.toString(),
        songId: incomingSong.id,
        extra: {'incomingQueueIndex': incomingQueueIndex},
      );
      rethrow;
    }
  }

  /// Releases a prepared standby deck and its retained interactive lease.
  /// Safe after revocation, promotion, or repeated cancellation.
  Future<void> cancelPreparedManualDjDeck() async {
    final preparingLease = _manualDjPreparingLease;
    final preparationDone = _manualDjPreparationDone;
    final session = _media3ProviderSession;
    if (preparingLease != null && preparationDone != null) {
      _manualDjPreparationInvalidated = true;
      if (preparingLease.isCurrent && session != null) {
        try { await session.cancelCrossfade(); } catch (_) {}
        try { await session.clearDeckEqOverlay(deck: 'standby'); } catch (_) {}
        try {
          await session.setDeckPlaybackSpeeds(
            activeSpeed: 1.0,
            standbySpeed: 1.0,
          );
        } catch (_) {}
      }
      // Keep the lease until the in-flight preload acknowledges completion.
      // Its owner then performs the final cleanup and releases authority.
      await preparationDone.future;
      return;
    }

    final lease = _manualDjPreparedLease;
    _manualDjPreparedDeck = null;
    _manualDjPreparedLease = null;
    if (lease == null) return;
    if (lease.isCurrent && session != null) {
      try { await session.cancelCrossfade(); } catch (_) {}
      try { await session.clearDeckEqOverlay(deck: 'standby'); } catch (_) {}
      try {
        await session.setDeckPlaybackSpeeds(
          activeSpeed: 1.0,
          standbySpeed: 1.0,
        );
      } catch (_) {}
    }
    await lease.release();
    if (!_disposed) notifyListeners();
  }

  /// Applies atomic active/standby speed and pitch only while the operator
  /// still owns the prepared-deck lease. The UI must never call the session
  /// capability directly; this is the single-writer gate for manual tempo.
  ///
  /// Logical active/standby factors are applied to the verified native player
  /// roles. The method deliberately refuses transitions and stale queue maps.
  Future<void> setPreparedManualDjDeckParameters({
    required double activeSpeed,
    required double activePitch,
    required double standbySpeed,
    required double standbyPitch,
  }) async {
    final session = _media3ProviderSession;
    final prepared = _manualDjPreparedDeck;
    final lease = _manualDjPreparedLease;
    if (session == null ||
        session is! PlaybackDeckParametersSession ||
        !_media3ProviderSessionActive ||
        prepared == null ||
        lease == null ||
        !lease.isCurrent ||
        !_manualDjPreparedDeckIsCurrent(session, prepared) ||
        !session.isPlaying ||
        session.crossfadeStatus != 'ready' ||
        _crossfadeInProgress ||
        _automaticCrossfadeInFlight) {
      throw StateError(
        'Manual tempo is unavailable until Deck B is prepared and playback is idle between transitions.',
      );
    }
    if (!lease.authorizeWrite('dj_manual_deck_playback_parameters')) {
      throw StateError('Manual DJ lease expired before tempo update.');
    }
    await (session as PlaybackDeckParametersSession)
        .setDeckPlaybackParameters(
      activeSpeed: activeSpeed,
      activePitch: activePitch,
      standbySpeed: standbySpeed,
      standbyPitch: standbyPitch,
    );
    // A user transport command may preempt this lease while the native
    // MethodChannel call is in flight. Never report the write as committed
    // after ownership or queue identity has changed.
    if (!lease.isCurrent ||
        !identical(_manualDjPreparedLease, lease) ||
        !identical(_manualDjPreparedDeck, prepared) ||
        !_manualDjPreparedDeckIsCurrent(session, prepared)) {
      throw StateError('Manual tempo update was superseded by playback authority or queue change.');
    }
    await ResonateDiagnostics.recordDj(
      stage: 'manual_deck_parameters',
      outcome: 'applied',
      reason: 'operator_requested',
      songId: prepared.incomingSong.id,
      extra: {
        'outgoingQueueIndex': prepared.outgoingQueueIndex,
        'incomingQueueIndex': prepared.incomingQueueIndex,
        'activeSpeed': activeSpeed,
        'activePitch': activePitch,
        'standbySpeed': standbySpeed,
        'standbyPitch': standbyPitch,
      },
    );
  }

  Future<void> cuePreparedManualDjDeck(Duration position) async {
    if (position < Duration.zero) {
      throw ArgumentError.value(position, 'position', 'Must not be negative.');
    }
    final session = _media3ProviderSession;
    final prepared = _manualDjPreparedDeck;
    final lease = _manualDjPreparedLease;
    if (session == null ||
        session is! PlaybackStandbyCueBackend ||
        prepared == null ||
        lease == null ||
        !lease.isCurrent ||
        !_manualDjPreparedDeckIsCurrent(session, prepared)) {
      await cancelPreparedManualDjDeck();
      throw StateError('Prepare Deck B again before changing its cue point.');
    }
    if (prepared.incomingSong.duration > Duration.zero &&
        position >= prepared.incomingSong.duration) {
      throw ArgumentError.value(
        position,
        'position',
        'Cue position must be inside the incoming track.',
      );
    }
    if (!lease.authorizeWrite('dj_manual_standby_cue') ||
        session.crossfadeStatus != 'ready') {
      await cancelPreparedManualDjDeck();
      throw StateError('Prepared Deck B is no longer available for cueing.');
    }
    final incomingNativeIndex =
        _manualDjNativeQueueIndices(session.queue)?[prepared.incomingQueueIndex];
    if (incomingNativeIndex == null) {
      await cancelPreparedManualDjDeck();
      throw StateError('The selected Deck B track is no longer in the native queue.');
    }
    await (session as PlaybackStandbyCueBackend).seekStandby(
      position: position,
      expectedMediaId: prepared.incomingSong.id,
      expectedQueueIndex: incomingNativeIndex,
    );
    if (!lease.isCurrent ||
        !_manualDjPreparedDeckIsCurrent(session, prepared)) {
      throw StateError('Deck B cue operation was superseded.');
    }
    _manualDjPreparedDeck = prepared.withCue(position);
    await ResonateDiagnostics.recordDj(
      stage: 'manual_deck_cue',
      outcome: 'applied',
      reason: 'operator_requested',
      songId: prepared.incomingSong.id,
      extra: {
        'incomingQueueIndex': prepared.incomingQueueIndex,
        'cuePositionMs': position.inMilliseconds,
      },
    );
    notifyListeners();
  }

  Future<void> crossfadePreparedManualDjDeck({
    required Duration duration,
  }) async {
    if (duration < const Duration(milliseconds: 250) ||
        duration > const Duration(seconds: 15)) {
      throw ArgumentError.value(duration, 'duration', 'Must be 250 ms–15 s.');
    }
    final session = _media3ProviderSession;
    final prepared = _manualDjPreparedDeck;
    final lease = _manualDjPreparedLease;
    if (session == null ||
        prepared == null ||
        lease == null ||
        !lease.isCurrent ||
        !_manualDjPreparedDeckIsCurrent(session, prepared) ||
        !session.isPlaying ||
        session.crossfadeStatus != 'ready') {
      await cancelPreparedManualDjDeck();
      throw StateError('Prepare Deck B again before starting the crossfade.');
    }
    final incomingNativeIndex =
        _manualDjNativeQueueIndices(session.queue)?[prepared.incomingQueueIndex];
    if (incomingNativeIndex == null) {
      await cancelPreparedManualDjDeck();
      throw StateError('The selected Deck B track is no longer in the native queue.');
    }
    try {
      if (!lease.authorizeWrite('dj_manual_crossfade') ||
          !_manualDjPreparedDeckIsCurrent(session, prepared)) {
        throw StateError('Manual DJ lease expired before crossfade start.');
      }
      await session.crossfade(duration: duration);

      final timeout = Stopwatch()..start();
      while (session.currentSong == null ||
          !_sameManualDjEntry(session.currentSong!, prepared.incomingSong) ||
          session.queueIndex != incomingNativeIndex) {
        if (!lease.isCurrent) {
          throw StateError('Manual DJ transition was preempted by another playback controller.');
        }
        if (!_media3ProviderSessionActive || _disposed) {
          throw StateError('Media3 session ended during the manual DJ transition.');
        }
        if (!session.isPlaying && session.crossfadeStatus != 'paused') {
          throw StateError('Playback stopped before the manual DJ transition completed.');
        }
        if (session.crossfadeStatus == 'incoming_error' ||
            session.crossfadeStatus == 'cancelled') {
          throw StateError('Media3 could not complete the requested manual transition.');
        }
        if (timeout.elapsed > duration + const Duration(seconds: 8)) {
          throw TimeoutException('Media3 did not promote the prepared DJ deck.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      if (!lease.isCurrent) {
        throw StateError('Manual DJ transition lost playback authority at promotion.');
      }
      await session.setDeckPlaybackSpeeds(
        activeSpeed: 1.0,
        standbySpeed: 1.0,
      );
      if (!lease.isCurrent) {
        throw StateError('Manual DJ transition was preempted during deck normalization.');
      }
      _manualDjPreparedDeck = null;
      _manualDjPreparedLease = null;
      _preloadedNextSongId = null;
      _media3DjTransitionPreparation = null;
      _crossfadeInProgress = false;
      _automaticCrossfadeInFlight = false;
      _transitionArmedAt = null;
      _reconcileMedia3ProviderSession();
      await _refreshTrackLevelingFor(prepared.incomingSong);
      if (!lease.isCurrent) return;
      _publishServiceState();
      notifyListeners();
      await ResonateDiagnostics.recordDj(
        stage: 'manual_transition',
        outcome: 'committed',
        reason: 'operator_requested',
        songId: prepared.incomingSong.id,
        extra: {
          'outgoingSongId': prepared.outgoingSong.id,
          'incomingQueueIndex': prepared.incomingQueueIndex,
          'incomingStartPositionMs': prepared.cuePosition.inMilliseconds,
          'durationMs': duration.inMilliseconds,
        },
      );
    } catch (error) {
      if (lease.isCurrent) {
        try { await session.cancelCrossfade(); } catch (_) {}
        if (lease.isCurrent) {
          try { await session.clearDeckEqOverlay(deck: 'standby'); } catch (_) {}
        }
        if (lease.isCurrent) {
          try {
            await session.setDeckPlaybackSpeeds(
              activeSpeed: 1.0,
              standbySpeed: 1.0,
            );
          } catch (_) {}
        }
      }
      _manualDjPreparedDeck = null;
      _manualDjPreparedLease = null;
      await ResonateDiagnostics.recordDj(
        stage: 'manual_transition',
        outcome: 'failed',
        reason: error.toString(),
        songId: prepared.incomingSong.id,
        extra: {
          'outgoingSongId': prepared.outgoingSong.id,
          'incomingQueueIndex': prepared.incomingQueueIndex,
          'incomingStartPositionMs': prepared.cuePosition.inMilliseconds,
        },
      );
      rethrow;
    } finally {
      await lease.release();
    }
  }

  /// Backwards-compatible one-shot entry point. The workspace uses the
  /// explicit prepare/cue/crossfade operations above.
  Future<void> performManualDjTransition({
    required int incomingQueueIndex,
    required Duration duration,
    Duration incomingStartPosition = Duration.zero,
  }) async {
    await prepareManualDjDeck(
      incomingQueueIndex: incomingQueueIndex,
      incomingStartPosition: incomingStartPosition,
    );
    await crossfadePreparedManualDjDeck(duration: duration);
  }

  /// Step 2–3: optional beat seek + tempo stretch for the incoming handoff.
  Future<void> _prepareDjHandoff({
    required dynamic outgoing,
    required dynamic incoming,
    required Song? outgoingSong,
    required Song incomingSong,
  }) async {
    _lastDjCrossfadeBiasMs = 0;
    _activeDjExecutionPlan = null;
    if ((!_djHandoffsLive) || _djAnalysis == null) {
      return;
    }
    if (outgoingSong == null) return;
    try {
      final loadedProfiles = await Future.wait<DjTrackProfile?>([
        _djAnalysis!.getProfile(outgoingSong.id),
        _djAnalysis!.getProfile(incomingSong.id),
      ]);
      final rawProfileA = loadedProfiles[0];
      final rawProfileB = loadedProfiles[1];
      final pairPreset = await DjTransitionPresetStore.get(outgoingSong.id, incomingSong.id);
      final presetUsable = pairPreset?.isUsableFor(
        outgoingPositionMs: outgoing.position.inMilliseconds,
        outgoingDurationMs: rawProfileA?.durationMs ?? (outgoingSong.duration.inMilliseconds > 0 ? outgoingSong.duration.inMilliseconds : null),
        incomingDurationMs: rawProfileB?.durationMs ?? (incomingSong.duration.inMilliseconds > 0 ? incomingSong.duration.inMilliseconds : null),
      ) ?? false;
      final profileA = rawProfileA != null && presetUsable ? pairPreset!.applyOutgoing(rawProfileA) : rawProfileA;
      final profileB = rawProfileB != null && presetUsable ? pairPreset!.applyIncoming(rawProfileB) : rawProfileB;
      if (profileA != null && profileB != null) {
        // Autonomous layer: the musical brain proposes valid candidates;
        // local learning softly reranks them without ever removing fallback.
        final learnedCandidate = await _djAutopilotPlanner.choose(
          outgoing: profileA,
          incoming: profileB,
          outgoingPositionMs: outgoing.position.inMilliseconds,
          preferredDurationMs: presetUsable ? pairPreset!.durationMs : _crossfadeDurationMs,
          maxDurationMs: presetUsable ? 15000 : 6500,
          policy: _djPolicy,
          preferredKind: presetUsable ? pairPreset?.preferredKind : null,
        );
        final v2 = _djEngine.execution.plan(
          outgoing: profileA,
          incoming: profileB,
          candidate: learnedCandidate,
          policy: _djPolicy,
        );
        if (!v2.fallback) {
          await _applyV2DjHandoff(
            outgoing: outgoing,
            incoming: incoming,
            outgoingSong: outgoingSong,
            incomingSong: incomingSong,
            profileA: profileA,
            profileB: profileB,
            plan: v2,
          );
          _activeDjExecutionPlan = v2;
          return;
        }
        await ResonateDiagnostics.recordDj(stage: 'v2_brain', outcome: 'fallback', reason: v2.reason, songId: incomingSong.id, extra: {'kind': v2.candidate.kind.name, 'score': v2.candidate.score});
      }

      List<DjAnalysis> results;
      try {
        final aFuture = _djAnalysis!.analyzeSongCachedFirst(outgoingSong);
        final bFuture = _djAnalysis!.analyzeSongCachedFirst(incomingSong);
        results = await Future.wait<DjAnalysis>([aFuture, bFuture]).timeout(
          const Duration(milliseconds: 2200),
          onTimeout: () => const <DjAnalysis>[],
        );
      } catch (e) {
        await ResonateDiagnostics.recordDj(
          stage: 'handoff_prepare',
          outcome: 'failed',
          reason: 'analysis_wait: $e',
        );
        return;
      }
      if (results.length < 2) return;
      final analysisA = results[0];
      final analysisB = results[1];
      final outPos = outgoing.position.inMilliseconds;
      final outDur = outgoingSong.duration.inMilliseconds > 0
          ? outgoingSong.duration.inMilliseconds
          : analysisA.durationMs;
      final plan = await planDjTransitionLearned(
        analysisA: analysisA,
        analysisB: analysisB,
        tempoMatchActive: _djTempoMatchActive,
        beatAlignActive: _djBeatAlignActive,
        maxStretchPercent: _djMaxStretchPercent,
        fromSongId: outgoingSong.id,
        toSongId: incomingSong.id,
        outgoingPositionMs: outPos,
        outgoingDurationMs: outDur,
      );
      _lastDjCrossfadeBiasMs = plan.crossfadeBiasMs;
      _lastDjEnergyScore = plan.energyScore.isFinite
          ? plan.energyScore.clamp(0.0, 1.0).toDouble()
          : 0.5;

      if (plan.strategy == 'safe_fallback') {
        await ResonateDiagnostics.record('dj_handoff_safe_fallback', {
          'reason': plan.reason,
          'strategy': plan.strategy,
          'outgoingSongId': outgoingSong.id,
          'incomingSongId': incomingSong.id,
          ...plan.toDiagExtra(),
        });
        await ResonateDiagnostics.recordDj(
          stage: 'handoff',
          outcome: 'applied',
          reason: plan.reason,
          songId: incomingSong.id,
          extra: plan.toDiagExtra(),
        );
        return;
      }

      final bpmA = plan.bpmA;
      final bpmB = plan.bpmB;
      if (bpmA == null || bpmB == null || bpmA < 40 || bpmB < 40) {
        await ResonateDiagnostics.recordDj(
          stage: 'handoff',
          outcome: 'applied',
          reason: 'missing_bpm_after_plan',
          songId: incomingSong.id,
          extra: plan.toDiagExtra(),
        );
        return;
      }
      final stretch = plan.stretch;
      final effectiveBpmB = stretch?.effectiveBpm ?? bpmB;
      final beatOffsetB = analysisB.beatOffsetMs ?? 0;
      final beatOffsetA = analysisA.beatOffsetMs ?? 0;
      var beatApplied = false;
      var tempoApplied = false;

      if (plan.attemptBeatAlign) {
        final posMs = outgoing.position.inMilliseconds;
        final seek = plan.usePhraseGrid
            ? computePhraseAlignedSeekMs(
                bpmA: stretch != null ? stretch.effectiveBpm : bpmA,
                beatOffsetMsA: beatOffsetA,
                bpmB: effectiveBpmB,
                beatOffsetMsB: beatOffsetB,
                outgoingPositionMs: posMs,
                beatsPerPhrase: plan.phraseBeats,
                maxRelativeDelta: stretch != null ? 0.22 : 0.09,
              )
            : computeBeatAlignedSeekMs(
                bpmA: stretch != null ? stretch.effectiveBpm : bpmA,
                beatOffsetMsA: beatOffsetA,
                bpmB: effectiveBpmB,
                beatOffsetMsB: beatOffsetB,
                outgoingPositionMs: posMs,
                maxRelativeDelta: stretch != null ? 0.22 : 0.09,
              );
        if (seek == null) {
          await ResonateDiagnostics.recordDj(
            stage: 'beat_align',
            outcome: 'skipped',
            reason: 'bpm_delta',
            bpmA: bpmA,
            bpmB: bpmB,
            songId: incomingSong.id,
          );
        } else {
          final dur = incoming.duration ?? incomingSong.duration;
          var target = seek;
          if (dur > Duration.zero && target >= dur) {
            final periodMs = (60000.0 / effectiveBpmB).round();
            if (periodMs > 0) {
              target = Duration(milliseconds: target.inMilliseconds % periodMs);
            } else {
              target = Duration.zero;
            }
          }
          await incoming.seek(target);
          beatApplied = true;
          await ResonateDiagnostics.record('dj_beat_align_applied', {
            'outgoingSongId': outgoingSong.id,
            'incomingSongId': incomingSong.id,
            'bpmA': bpmA,
            'bpmB': bpmB,
            'seekMs': target.inMilliseconds,
            'outgoingPosMs': posMs,
            'stretched': stretch != null,
            'harmonicScore': plan.harmonicScore,
          });
        }
      }

      if (stretch != null) {
        try {
          if ((stretch.speedOutgoing - 1.0).abs() > 0.001) {
            await outgoing.setSpeed(stretch.speedOutgoing);
          }
          await incoming.setSpeed(stretch.speedIncoming);
          _djStretchSpeedOut = stretch.speedOutgoing;
          _djStretchSpeedIn = stretch.speedIncoming;
          tempoApplied = true;
          await ResonateDiagnostics.record('dj_tempo_match_applied', {
            'outgoingSongId': outgoingSong.id,
            'incomingSongId': incomingSong.id,
            'bpmA': bpmA,
            'bpmB': bpmB,
            'speedOut': stretch.speedOutgoing,
            'speedIn': stretch.speedIncoming,
            'mode': stretch.mode,
            'effectiveBpm': stretch.effectiveBpm,
            'harmonicScore': plan.harmonicScore,
          });
        } catch (e) {
          await _clearDjStretchSpeeds(outgoing: outgoing, incoming: incoming);
          await ResonateDiagnostics.recordDj(
            stage: 'tempo_match',
            outcome: 'failed',
            reason: e.toString(),
            songId: incomingSong.id,
          );
        }
      }

      final appliedStrategy = tempoApplied && beatApplied
          ? 'beat_tempo'
          : (tempoApplied
              ? 'tempo_match'
              : (beatApplied ? 'beat_align' : 'safe_fallback'));
      await ResonateDiagnostics.recordDj(
        stage: 'handoff',
        outcome: 'applied',
        reason: appliedStrategy,
        songId: incomingSong.id,
        bpmA: bpmA,
        bpmB: bpmB,
        extra: {
          ...plan.toDiagExtra(),
          'strategyApplied': appliedStrategy,
          'beatApplied': beatApplied,
          'tempoApplied': tempoApplied,
        },
      );
      _lastDjHandoffAt = DateTime.now();
      _lastDjFromId = outgoingSong.id;
      _lastDjToId = incomingSong.id;
      _lastDjStrategy = appliedStrategy;
      _lastDjTransitionScore = null;
      _lastDjTransitionConfidence = math.min(plan.confidenceA, plan.confidenceB);
      _lastDjTransitionRisks = const <String>[];
      _lastDjTransitionDurationMs = null;
      _lastDjRecoveryAttempts = 0;
      notifyListeners(); // dj transition chip
    } catch (e) {
      debugPrint('DJ handoff prepare skipped: $e');
      try {
        await ResonateDiagnostics.recordDj(
          stage: 'handoff_prepare',
          outcome: 'failed',
          reason: e.toString(),
        );
      } catch (_) {}
    }
  }

  Future<void> _applyV2DjHandoff({
    required dynamic outgoing,
    required dynamic incoming,
    required Song outgoingSong,
    required Song incomingSong,
    required DjTrackProfile profileA,
    required DjTrackProfile profileB,
    required DjExecutionPlan plan,
  }) async {
    final candidate = plan.candidate;
    _lastDjCrossfadeBiasMs = 0;
    _lastDjEnergyScore = candidate.scores['energy'] ?? 0.5;
    _lastDjBassDuckNeeded = candidate.risks.contains(DjRiskType.bassCollision);

    // The V2 execution planner is now the source of truth for transition
    // timing. The existing A/B crossfade loop remains the actual audio executor.
    // This deliberately keeps execution engine-neutral: if a step is unknown,
    // ordinary crossfade behavior remains the safe fallback.
    for (final step in plan.steps) {
      if (step.action == 'extend_crossfade') {
        final requested = (step.parameters['durationMs'] as num?)?.toInt();
        if (requested != null) {
          _lastDjCrossfadeBiasMs =
              (requested - candidate.durationMs).clamp(-4000, 8000).toInt();
        }
      }
    }

    final incomingDuration = incoming.duration ?? incomingSong.duration;
    final seekMs = candidate.incomingStartMs
        .clamp(0, incomingDuration.inMilliseconds)
        .toInt();
    await incoming.seek(Duration(milliseconds: seekMs));

    await ResonateDiagnostics.recordDj(
      stage: 'v2_execution',
      outcome: 'prepared',
      reason: 'timeline_mapped_to_ab',
      songId: incomingSong.id,
      extra: {
        'kind': candidate.kind.name,
        'incomingStartMs': seekMs,
        'durationMs': candidate.durationMs,
        'crossfadeBiasMs': _lastDjCrossfadeBiasMs,
        'steps': plan.steps.map((step) => {
          'action': step.action,
          'atMs': step.atMs,
          'parameters': step.parameters,
        }).toList(),
      },
    );

    var tempoApplied = false;
    _lastDjIncomingBeatMs = profileB.beatGrid.beatMs;
    _lastDjIncomingBpm = profileB.beatGrid.bpm;
    _djBeatCorrectionAttempts = 0;
    if (_djTempoMatchActive &&
        profileA.beatGrid.bpm != null &&
        profileB.beatGrid.bpm != null) {
      final stretch = _safeProfileTempoStretch(
        profileA,
        profileB,
        candidate: plan.candidate,
        maxStretchPercent: _djMaxStretchPercent,
      );
      if (stretch != null) {
        await outgoing.setSpeed(stretch.speedOutgoing);
        await incoming.setSpeed(stretch.speedIncoming);
        _djStretchSpeedOut = stretch.speedOutgoing;
        _djStretchSpeedIn = stretch.speedIncoming;
        tempoApplied = true;
      }
    }

    _lastDjHandoffAt = DateTime.now();
    _lastDjFromId = outgoingSong.id;
    _lastDjToId = incomingSong.id;
    _lastDjStrategy = candidate.kind.name;
    _lastDjTransitionScore = candidate.score;
    _lastDjTransitionConfidence = candidate.confidence;
    _lastDjTransitionRisks = candidate.risks.map((r) => r.name).toList();
    _lastDjTransitionDurationMs = candidate.durationMs;
    _lastDjRecoveryAttempts = 0;
    notifyListeners(); // dj transition chip
    await ResonateDiagnostics.recordDj(
      stage: 'v2_handoff',
      outcome: 'applied',
      reason: plan.reason,
      songId: incomingSong.id,
      extra: {
        'kind': candidate.kind.name,
        'score': candidate.score,
        'confidence': candidate.confidence,
        'seekMs': seekMs,
        'tempoApplied': tempoApplied,
        'risks': candidate.risks.map((r) => r.name).toList(),
        'scores': candidate.scores,
      },
    );
  }

  /// Builds a player-agnostic DJ handoff for the injected Media3 session.
  /// The incoming phrase offset and independent deck rates are applied during
  /// standby preload, before the native equal-power crossfade is armed.
  Future<void> _prepareMedia3RepeatSelfDjTransition(
    Song song,
    int outgoingPositionMs,
    int generation,
  ) async {
    final transportEpoch = _userTransportEpoch;
    try {
      final preparation = await _prepareMedia3DjHandoff(
        outgoingSong: song,
        incomingSong: song,
        outgoingPositionMs: outgoingPositionMs,
      );
      if (_disposed ||
          generation != _repeatSelfDjPlanGeneration ||
          transportEpoch != _userTransportEpoch ||
          _repeatMode != PlaybackRepeatMode.one ||
          currentSong?.id != song.id ||
          !_djHandoffsLive) {
        return;
      }

      final profile = preparation.outgoingProfile;
      final cueMs = preparation.outgoingStartPosition?.inMilliseconds;
      final trackDurationMs =
          profile?.durationMs ?? song.duration.inMilliseconds;
      final fadeMs = preparation.transitionDurationMs ?? _crossfadeDurationMs;
      final hasSafeOutro = profile != null &&
          cueMs != null &&
          cueMs >= outgoingPositionMs &&
          cueMs <= trackDurationMs - 2000 &&
          trackDurationMs - cueMs <= 30000 &&
          trackDurationMs - cueMs >= fadeMs + 1200 &&
          (profile.transitions.safeMixOuts.any(
                (point) => point.timeMs == cueMs,
              ) ||
              profile.transitions.bestOutroMs == cueMs);
      if (hasSafeOutro) {
        _repeatSelfDjPreparation = preparation;
        await ResonateDiagnostics.recordDj(
          stage: 'repeat_self_dj_plan',
          outcome: 'prepared',
          reason: 'safe_outro_to_same_track_intro',
          songId: song.id,
          extra: {
            'outgoingCueMs': cueMs,
            'incomingCueMs': preparation.incomingStartPosition.inMilliseconds,
            'durationMs': fadeMs,
          },
        );
      } else {
        await ResonateDiagnostics.recordDj(
          stage: 'repeat_self_dj_plan',
          outcome: 'safe_fallback',
          reason: 'no_confident_outgoing_mix_point',
          songId: song.id,
        );
      }
    } catch (error) {
      await ResonateDiagnostics.recordDj(
        stage: 'repeat_self_dj_plan',
        outcome: 'safe_fallback',
        reason: 'planning_failed: $error',
        songId: song.id,
      );
    } finally {
      if (generation == _repeatSelfDjPlanGeneration) {
        _repeatSelfDjPlanning = false;
      }
    }
  }

  Future<Media3DjTransitionPreparation> _prepareMedia3DjHandoff({
    required Song outgoingSong,
    required Song incomingSong,
    required int outgoingPositionMs,
  }) async {
    _lastDjCrossfadeBiasMs = 0;
    _activeDjExecutionPlan = null;
    _lastDjIncomingBeatMs = const <int>[];
    _lastDjIncomingBpm = null;
    // Consume through the canonical key builder used by the approval handoff.
    // A review-time fallback must remain a fallback; never promote it into a
    // DJ execution plan merely because a later lookup happens to succeed.
    final approved = takeApprovedDjTransition(
      outgoingSong.id,
      incomingSong.id,
    );
    if (approved?.fallback == true) {
      await ResonateDiagnostics.recordDj(
        stage: 'media3_approved_plan',
        outcome: 'approved_fallback',
        reason: approved!.reason,
        songId: incomingSong.id,
        extra: {'fromSongId': outgoingSong.id},
      );
      return const Media3DjTransitionPreparation();
    }
    if ((!_djHandoffsLive && approved == null) ||
        !_modeCrossfadeAllowed ||
        _djAnalysis == null) {
      if (approved != null) {
        await ResonateDiagnostics.recordDj(
          stage: 'media3_approved_plan',
          outcome: 'rejected_runtime_unavailable',
          reason: !_modeCrossfadeAllowed
              ? 'mode_crossfade_restricted'
              : 'analysis_service_unavailable',
          songId: incomingSong.id,
          extra: {'fromSongId': outgoingSong.id},
        );
      }
      return const Media3DjTransitionPreparation();
    }

    try {
      final profiles = await Future.wait<DjTrackProfile?>([
        _djAnalysis!.getProfile(outgoingSong.id),
        _djAnalysis!.getProfile(incomingSong.id),
      ]);
      final rawProfileA = profiles[0];
      final rawProfileB = profiles[1];
      final pairPreset = await DjTransitionPresetStore.get(outgoingSong.id, incomingSong.id);
      final presetUsable = pairPreset?.isUsableFor(
        outgoingPositionMs: outgoingPositionMs,
        outgoingDurationMs: rawProfileA?.durationMs ?? (outgoingSong.duration.inMilliseconds > 0 ? outgoingSong.duration.inMilliseconds : null),
        incomingDurationMs: rawProfileB?.durationMs ?? (incomingSong.duration.inMilliseconds > 0 ? incomingSong.duration.inMilliseconds : null),
      ) ?? false;
      final profileA = rawProfileA != null && presetUsable ? pairPreset!.applyOutgoing(rawProfileA) : rawProfileA;
      final profileB = rawProfileB != null && presetUsable ? pairPreset!.applyIncoming(rawProfileB) : rawProfileB;
      if (profileA != null && profileB != null) {
        // Prefer the exact candidate the user reviewed and approved. The
        // execution planner revalidates it against the real outgoing position
        // and current deck durations before any seek or speed change.
        // A review can happen well before playback reaches this pair. Never
        // execute a reviewed cue that has already fallen behind the playhead.
        final approvedCueIsAhead = approved != null &&
            approved.candidate.outgoingStartMs >= outgoingPositionMs;
        final candidate = approvedCueIsAhead
            ? approved.candidate
            : await _djAutopilotPlanner.choose(
                outgoing: profileA,
                incoming: profileB,
                outgoingPositionMs: outgoingPositionMs,
                preferredDurationMs: presetUsable ? pairPreset!.durationMs : _crossfadeDurationMs,
                maxDurationMs: presetUsable ? 15000 : 6500,
                policy: _djPolicy,
                preferredKind: presetUsable ? pairPreset?.preferredKind : null,
              );
        final execution = _djEngine.execution.plan(
          outgoing: profileA,
          incoming: profileB,
          candidate: candidate,
          policy: _djPolicy,
        );
        if (approved != null) {
          await ResonateDiagnostics.recordDj(
            stage: 'media3_approved_plan',
            outcome: !approvedCueIsAhead
                ? 'rejected_stale_cue_replanned'
                : execution.fallback
                    ? 'rejected_replanned'
                    : 'accepted',
            reason: execution.reason,
            songId: incomingSong.id,
            extra: {
              'fromSongId': outgoingSong.id,
              'candidateKind': candidate.kind.name,
              'candidateDurationMs': candidate.durationMs,
            },
          );
        }
        if (!execution.fallback) {
          _activeDjExecutionPlan = execution;
          _lastDjCrossfadeBiasMs = execution.steps
              .where((step) => step.action == 'extend_crossfade')
              .map((step) => (step.parameters['durationMs'] as num?)?.toInt())
              .whereType<int>()
              .fold<int>(0, (bias, duration) =>
                  (duration - candidate.durationMs).clamp(-4000, 8000).toInt());
          _lastDjEnergyScore =
              (candidate.scores['energy'] ?? 0.5).clamp(0.0, 1.0).toDouble();
          _lastDjIncomingBeatMs = profileB.beatGrid.beatMs;
          _lastDjIncomingBpm = profileB.beatGrid.bpm;
          var activeSpeed = 1.0;
          var standbySpeed = 1.0;
          if (_djTempoMatchActive &&
              profileA.beatGrid.bpm != null &&
              profileB.beatGrid.bpm != null) {
            final stretch = _safeProfileTempoStretch(
              profileA,
              profileB,
              candidate: candidate,
              maxStretchPercent: _djMaxStretchPercent,
            );
            if (stretch != null) {
              activeSpeed = stretch.speedOutgoing;
              standbySpeed = stretch.speedIncoming;
              _djStretchSpeedOut = activeSpeed;
              _djStretchSpeedIn = standbySpeed;
            }
          }
          // The execution planner may extend or cap the candidate duration.
          // Pass its validated completion boundary to Media3, not the raw
          // candidate duration, so the actual fade matches the approved plan.
          final executionDurationMs = execution.steps.isNotEmpty
              ? execution.steps.last.atMs
              : candidate.durationMs;
          final outgoingMaterialAfterCueMs =
              (profileA.durationMs ?? outgoingSong.duration.inMilliseconds) -
                  candidate.outgoingStartMs;
          final hasProfileOutgoingCue =
              outgoingMaterialAfterCueMs <= 30000 &&
              outgoingMaterialAfterCueMs >= executionDurationMs + 1200 &&
              (profileA.transitions.safeMixOuts.any(
                    (point) => point.timeMs == candidate.outgoingStartMs,
                  ) ||
                  profileA.transitions.bestOutroMs == candidate.outgoingStartMs);
          final hasPlannedOutgoingCue = approvedCueIsAhead || presetUsable || hasProfileOutgoingCue;
          final seekMs = candidate.incomingStartMs
              .clamp(0, incomingSong.duration.inMilliseconds > 0
                  ? incomingSong.duration.inMilliseconds
                  : candidate.incomingStartMs)
              .toInt();
          _lastDjHandoffAt = DateTime.now();
          _lastDjFromId = outgoingSong.id;
          _lastDjToId = incomingSong.id;
          _lastDjStrategy = candidate.kind.name;
          _lastDjTransitionScore = candidate.score;
          _lastDjTransitionConfidence = candidate.confidence;
          _lastDjTransitionRisks =
              candidate.risks.map((risk) => risk.name).toList();
          _lastDjTransitionDurationMs =
              hasPlannedOutgoingCue ? executionDurationMs : null;
          _lastDjRecoveryAttempts = 0;
          await ResonateDiagnostics.recordDj(
            stage: 'media3_handoff_prepare',
            outcome: 'prepared',
            reason: execution.reason,
            songId: incomingSong.id,
            extra: {
              'kind': candidate.kind.name,
              'incomingStartMs': seekMs,
              'durationMs': hasPlannedOutgoingCue ? executionDurationMs : null,
              'candidateDurationMs': candidate.durationMs,
              'activeSpeed': activeSpeed,
              'standbySpeed': standbySpeed,
              'crossfadeBiasMs': _lastDjCrossfadeBiasMs,
              'risks': _lastDjTransitionRisks,
            },
          );
          notifyListeners();
          return Media3DjTransitionPreparation(
            incomingStartPosition: Duration(milliseconds: seekMs),
            activeSpeed: activeSpeed,
            standbySpeed: standbySpeed,
            outgoingProfile: profileA,
            transitionKind: candidate.kind,
            outgoingStartPosition: hasPlannedOutgoingCue
                ? Duration(milliseconds: candidate.outgoingStartMs)
                : null,
            transitionDurationMs:
                hasPlannedOutgoingCue ? executionDurationMs : null,
            incomingBassDuckAmount: _djBassDuckAmount(execution),
            incomingBassDuckDurationMs: _djBassDuckDuration(execution),
            transitionSfxTriggerMs: _djSfxTriggerMs(execution),
          );
        }

        // A profile-backed V2 rejection is authoritative. Do not pass the
        // same pair into the legacy planner, which may apply a less
        // conservative tempo stretch and recreate slow-motion/crackle.
        await ResonateDiagnostics.recordDj(
          stage: 'media3_handoff_prepare',
          outcome: 'safe_fallback',
          reason: execution.reason,
          songId: incomingSong.id,
          extra: {
            'planner': 'v2',
            'candidateKind': candidate.kind.name,
            'candidateScore': candidate.score,
            'candidateConfidence': candidate.confidence,
            'risks': candidate.risks.map((risk) => risk.name).toList(),
            'legacyTempoFallbackSkipped': true,
          },
        );
        return const Media3DjTransitionPreparation();
      }
    } catch (error) {
      await ResonateDiagnostics.recordDj(
        stage: 'media3_handoff_prepare',
        outcome: 'fallback',
        reason: 'profile_planning: $error',
        songId: incomingSong.id,
      );
    }

    // The legacy analysis planner remains a safe, player-agnostic fallback.
    try {
      final results = await Future.wait<DjAnalysis>([
        _djAnalysis!.analyzeSongCachedFirst(outgoingSong),
        _djAnalysis!.analyzeSongCachedFirst(incomingSong),
      ]).timeout(const Duration(milliseconds: 2200));
      if (results.length == 2) {
        final analysisA = results[0];
        final analysisB = results[1];
        final plan = await planDjTransitionLearned(
          analysisA: analysisA,
          analysisB: analysisB,
          tempoMatchActive: _djTempoMatchActive,
          beatAlignActive: _djBeatAlignActive,
          maxStretchPercent: _djMaxStretchPercent,
          fromSongId: outgoingSong.id,
          toSongId: incomingSong.id,
          outgoingPositionMs: outgoingPositionMs,
          outgoingDurationMs: outgoingSong.duration.inMilliseconds > 0
              ? outgoingSong.duration.inMilliseconds
              : analysisA.durationMs,
        );
        _lastDjCrossfadeBiasMs = plan.crossfadeBiasMs;
        _lastDjEnergyScore = plan.energyScore.isFinite
            ? plan.energyScore.clamp(0.0, 1.0).toDouble()
            : 0.5;
        var seekMs = 0;
        if (plan.attemptBeatAlign &&
            plan.bpmA != null &&
            plan.bpmB != null) {
          final stretch = plan.stretch;
          final effectiveBpmB = stretch?.effectiveBpm ?? plan.bpmB!;
          final target = plan.usePhraseGrid
              ? computePhraseAlignedSeekMs(
                  bpmA: stretch?.effectiveBpm ?? plan.bpmA!,
                  beatOffsetMsA: analysisA.beatOffsetMs ?? 0,
                  bpmB: effectiveBpmB,
                  beatOffsetMsB: analysisB.beatOffsetMs ?? 0,
                  outgoingPositionMs: outgoingPositionMs,
                  beatsPerPhrase: plan.phraseBeats,
                  maxRelativeDelta: stretch != null ? 0.22 : 0.09,
                )
              : computeBeatAlignedSeekMs(
                  bpmA: stretch?.effectiveBpm ?? plan.bpmA!,
                  beatOffsetMsA: analysisA.beatOffsetMs ?? 0,
                  bpmB: effectiveBpmB,
                  beatOffsetMsB: analysisB.beatOffsetMs ?? 0,
                  outgoingPositionMs: outgoingPositionMs,
                  maxRelativeDelta: stretch != null ? 0.22 : 0.09,
                );
          if (target != null) seekMs = target.inMilliseconds;
        }
        final safeSeekMs = seekMs.clamp(
          0,
          incomingSong.duration.inMilliseconds > 0
              ? incomingSong.duration.inMilliseconds
              : seekMs,
        ).toInt();
        final stretch = plan.stretch;
        final activeSpeed = stretch?.speedOutgoing ?? 1.0;
        final standbySpeed = stretch?.speedIncoming ?? 1.0;
        _lastDjIncomingBeatMs = const <int>[];
        _lastDjIncomingBpm = plan.bpmB;
        _djStretchSpeedOut = activeSpeed;
        _djStretchSpeedIn = standbySpeed;
        _lastDjHandoffAt = DateTime.now();
        _lastDjFromId = outgoingSong.id;
        _lastDjToId = incomingSong.id;
        _lastDjStrategy = plan.strategy;
        _lastDjTransitionConfidence =
            math.min(plan.confidenceA, plan.confidenceB);
        _lastDjTransitionDurationMs = null;
        _lastDjRecoveryAttempts = 0;
        await ResonateDiagnostics.recordDj(
          stage: 'media3_handoff_prepare',
          outcome: 'prepared',
          reason: plan.strategy,
          songId: incomingSong.id,
          bpmA: plan.bpmA,
          bpmB: plan.bpmB,
          extra: {
            ...plan.toDiagExtra(),
            'incomingStartMs': safeSeekMs,
            'activeSpeed': activeSpeed,
            'standbySpeed': standbySpeed,
          },
        );
        notifyListeners();
        return Media3DjTransitionPreparation(
          incomingStartPosition: Duration(milliseconds: safeSeekMs),
          activeSpeed: activeSpeed,
          standbySpeed: standbySpeed,
        );
      }
    } catch (error) {
      await ResonateDiagnostics.recordDj(
        stage: 'media3_handoff_prepare',
        outcome: 'fallback',
        reason: 'analysis_planning: $error',
        songId: incomingSong.id,
      );
    }
    return const Media3DjTransitionPreparation();
  }

  Future<void> _recoverDjEngineState({String reason = 'recover'}) async {
    // Media3 owns both physical decks and its own focus/gain policy after
    // provider cutover. Never recover through the retired EnginePair or
    // reactivate the legacy AudioSession: doing so can interrupt or duck the
    // canonical Media3 output when the DJ master toggle is changed.
    final media3 = _media3ProviderSessionActive ? _media3ProviderSession : null;
    if (media3 != null) {
      final recoveryTransportEpoch = _userTransportEpoch;
      bool wasPreempted() => recoveryTransportEpoch != _userTransportEpoch;
      try {
        await _restoreDjTransitionSfx();
        if (wasPreempted()) return;
        await media3.setDeckPlaybackSpeeds(activeSpeed: 1.0, standbySpeed: 1.0);
        if (wasPreempted()) return;
        await media3.setGainFactors(
          trackLevel: _trackLevelingScale,
          preamp: _eqPreampUserScale,
          sleepFade: _sleepFadeScale,
          focusDuck: _isDucked
              ? (_audioFocusLevel == 1 ? 0.18 : MusicProvider._duckLevel)
              : 1.0,
        );
        if (wasPreempted()) return;
        await ResonateDiagnostics.recordDj(
          stage: 'engine_recover',
          outcome: 'applied',
          reason: reason,
          extra: {
            'engine': 'Media3',
            'activeDeck': _media3ShadowState?.activeDeckId ?? 'A',
            'playing': media3.isPlaying,
            'positionMs': media3.position.inMilliseconds,
          },
        );
      } catch (error) {
        debugPrint('Media3 DJ engine recover failed: $error');
      }
      return;
    }
    // Recovery is asynchronous and may overlap a manual track selection. It
    // must never restore master volume on an engine captured before that
    // selection, or it can make the old track audible again.
    final recoveryTransportEpoch = _userTransportEpoch;
    bool wasPreempted() => recoveryTransportEpoch != _userTransportEpoch;
    try {
      await _clearDjStretchSpeeds(outgoing: _playerA, incoming: _playerB);
      if (wasPreempted()) return;
    } catch (_) {}
    try {
      await _restoreDjTransitionSfx();
      if (wasPreempted()) return;
    } catch (_) {}
    try {
      final active = audioPlayer;
      final inactive = inactivePlayer;
      final vol = _eqPreampScale.clamp(0.05, 1.0);
      try {
        await active.setSpeed(1.0);
      } catch (_) {}
      if (wasPreempted()) return;
      try {
        await inactive.setSpeed(1.0);
      } catch (_) {}
      if (wasPreempted()) return;
      try {
        if ((_userWantsPlaying || active.playing) && active.volume < vol * 0.85) {
          await active.setVolume(vol);
        }
      } catch (_) {}
      if (wasPreempted()) return;
      try {
        await inactive.setVolume(0.0);
      } catch (_) {}
      if (wasPreempted()) return;
      try {
        final session = await AudioSession.instance;
        await session.setActive(true);
      } catch (_) {}
      if (wasPreempted()) return;
      await ResonateDiagnostics.recordDj(
        stage: 'engine_recover',
        outcome: 'applied',
        reason: reason,
        extra: {
          'activeVolume': active.volume,
          'activePlaying': active.playing,
          'activeEngine': _activeIsA ? 'A' : 'B',
        },
      );
    } catch (e) {
      debugPrint('DJ engine recover failed: $e');
    }
  }
}


double? _djBassDuckAmount(DjExecutionPlan plan) {
  for (final step in plan.steps) {
    if (step.action == 'duck_incoming_bass') {
      return (step.parameters['amount'] as num?)?.toDouble();
    }
  }
  return null;
}

int? _djSfxTriggerMs(DjExecutionPlan plan) {
  for (final step in plan.steps) {
    if (step.action == 'trigger_sfx') return step.atMs;
  }
  return null;
}

int? _djBassDuckDuration(DjExecutionPlan plan) {
  for (final step in plan.steps) {
    if (step.action == 'duck_incoming_bass') {
      return (step.parameters['durationMs'] as num?)?.toInt();
    }
  }
  return null;
}

/// Immutable output of DJ planning for a Media3 active/standby pair.
class Media3DjTransitionPreparation {
  const Media3DjTransitionPreparation({
    this.incomingStartPosition = Duration.zero,
    this.activeSpeed = 1.0,
    this.standbySpeed = 1.0,
    this.outgoingProfile,
    this.transitionKind,
    this.outgoingStartPosition,
    this.transitionDurationMs,
    this.incomingBassDuckAmount,
    this.incomingBassDuckDurationMs,
    this.transitionSfxTriggerMs,
  });

  final Duration incomingStartPosition;
  final double activeSpeed;
  final double standbySpeed;
  final DjTrackProfile? outgoingProfile;
  final DjTransitionKind? transitionKind;
  /// Selected outgoing mix point from a reviewed cue or live DJ analysis.
  final Duration? outgoingStartPosition;
  /// Validated duration for the selected outgoing mix point.
  final int? transitionDurationMs;
  /// Temporary low-frequency attenuation requested by the execution plan.
  final double? incomingBassDuckAmount;
  final int? incomingBassDuckDurationMs;
  /// Phrase-snapped SFX trigger offset within the validated fade timeline.
  final int? transitionSfxTriggerMs;
}
