import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/intelligence_recommendation.dart';
import '../models/song.dart';
import '../models/queue_plan.dart';
import '../models/queue_intent.dart';
import '../services/intelligence_decision_engine.dart';
import '../services/intelligence_settings_store.dart';
import '../services/resonate_diagnostics.dart';
import '../services/companion_decision_log.dart';
import '../services/playback_authority.dart';
import 'intelligence_provider.dart';
import 'music_provider.dart';
import '../modes/providers/mode_provider.dart';
import '../modes/models/motivation_intent.dart';
import '../modes/models/resonate_mode.dart';
import '../modes/services/mode_content_resolver.dart';
import '../services/autopilot_mode_policy.dart';
import '../services/mode_aware_queue_planner.dart';

/// Bridges Intelligence decisions into the existing MusicProvider playback
/// engine. MusicProvider remains authoritative for playback and queue state.
/// PlaybackAuthority events wake this controller for command-sensitive work;
/// the provider listener remains only as a state-boundary fallback.
class AutopilotController extends ChangeNotifier {
  final MusicProvider music;
  final IntelligenceProvider intelligence;
  final ModeProvider? modes;
  final IntelligenceDecisionEngine _decisionEngine = const IntelligenceDecisionEngine();
  final ModeContentResolver _modeContentResolver = const ModeContentResolver();
  final ModeAwareQueuePlanner _modeQueuePlanner = ModeAwareQueuePlanner();
  final PlaybackAuthority _authority = PlaybackAuthority.instance;
  bool _queueDecisionInFlight = false;
  bool _transitionInFlight = false;
  String? _transitionSongId;
  String? _pendingSongId;
  Song? _pendingSong;
  String? _pendingSourceSongId;
  String? _declinedForSongId;
  String? _declinedForSourceSongId;
  bool _pendingTakeover = false;
  bool _consentLoaded = false;
  bool _consentGranted = false;
  DateTime? _lastEvaluation;
  DateTime? _lastMotivationFollowupAt;
  bool _evaluationScheduled = false;
  double _lastConfidenceThreshold = .65;
  String? _modeQueueBlockedReason;
  ResonateMode? _lastObservedMode;

  AutopilotController({
    required this.music,
    required this.intelligence,
    this.modes,
  }) {
    _lastObservedMode = modes?.mode;
    music.addListener(_onPlaybackChanged);
    intelligence.addListener(_onIntelligenceChanged);
    modes?.addListener(_onModesChanged);
    _authority.addListener(_onAuthorityEvent);
    unawaited(_loadConsentAndEvaluate());
  }

  bool get hasPendingTakeover => _pendingTakeover && _pendingSongId != null;
  String? get pendingSongId => _pendingSongId;
  Song? get pendingSong => _pendingSong;
  bool get consentGranted => _consentGranted;

  /// Live explanation of the gates currently preventing or enabling takeover.
  String get readinessMessage {
    if (!_consentLoaded) return 'Loading saved Autopilot permission…';
    if (intelligence.isAutopilot && _consentGranted &&
        _modeQueueBlockedReason != null) {
      return _modeQueueBlockedReason!;
    }
    final current = music.currentSong;
    final duration = music.currentDuration;
    final remaining = duration == null ? null : duration - music.currentPosition;
    final hasCandidate = _activeRecommendationPool.any((recommendation) =>
        recommendation.song.id != current?.id &&
        recommendation.confidence >= _lastConfidenceThreshold);
    return AutopilotModePolicy.readinessMessage(
      intelligenceEnabled: intelligence.isEnabled,
      autopilotSelected: intelligence.isAutopilot,
      consentGranted: _consentGranted,
      hasPendingTakeover: hasPendingTakeover,
      transitionInFlight: _transitionInFlight,
      hasCurrentSong: current != null,
      isPlaying: music.isPlaying,
      automaticNextAllowed: AutopilotModePolicy.allowsAutomaticNext(modes?.policy),
      hasConfidentCandidate: hasCandidate,
      remaining: remaining,
    );
  }

  List<IntelligenceRecommendation> get _activeRecommendationPool {
    final mode = modes?.mode;
    return mode != null && QueueIntent.forMode(mode) != null
        ? intelligence.candidatePool
        : intelligence.recommendations;
  }

  bool get _mayMutatePlayback => AutopilotModePolicy.mayMutatePlayback(
        consentGranted: _consentGranted,
        intelligenceEnabled: intelligence.isEnabled,
        autopilotEnabled: intelligence.isAutopilot,
      );

  /// Re-check authority after every asynchronous boundary before a playback
  /// mutation. A setting change can happen while a decision is awaiting I/O.
  bool _requirePlaybackMutationPermission(String stage) {
    if (_mayMutatePlayback) return true;
    unawaited(ResonateDiagnostics.record('intelligence_playback_mutation_blocked', {
      'stage': stage,
      'consentGranted': _consentGranted,
      'intelligenceEnabled': intelligence.isEnabled,
      'autopilotEnabled': intelligence.isAutopilot,
    }));
    return false;
  }

  /// Home card / settings — user explicitly allows or revokes track control.
  Future<void> setConsent(bool value) async {
    _consentGranted = value;
    await IntelligenceSettingsStore.setAutopilotConsent(value);
    if (!value) {
      _pendingTakeover = false;
      _pendingSongId = null;
      _pendingSong = null;
      _pendingSourceSongId = null;
    }
    notifyListeners();
    await ResonateDiagnostics.record('intelligence_notification_action', {
      'action': value ? 'consent_granted' : 'consent_revoked',
      'mode': intelligence.autonomyLabel,
    });
    unawaited(CompanionDecisionLog.record(
      source: 'autopilot',
      action: value ? 'consent_granted' : 'consent_revoked',
      detail: value
          ? 'You allowed Autopilot to change tracks.'
          : 'Autopilot is advisory only until you consent again.',
    ));
    if (value) await _evaluate();
  }

  void _onPlaybackChanged() {
    final currentSongId = music.currentSong?.id;
    var changed = false;
    if (_pendingTakeover && _pendingSourceSongId != currentSongId) {
      _pendingTakeover = false;
      _pendingSongId = null;
      _pendingSong = null;
      _pendingSourceSongId = null;
      changed = true;
    }
    // A decline is scoped to the track whose transition was being proposed.
    // Reconsider the same candidate when a new source track starts.
    if (_declinedForSourceSongId != null &&
        _declinedForSourceSongId != currentSongId) {
      _declinedForSongId = null;
      _declinedForSourceSongId = null;
    }
    if (changed) notifyListeners();
    _scheduleEvaluate();
  }
  void _onIntelligenceChanged() => _scheduleEvaluate();

  void _onModesChanged() {
    final m = modes;
    if (m == null) return;
    if (m.mode != _lastObservedMode) {
      _lastObservedMode = m.mode;
      _modeQueueBlockedReason = null;
      _pendingTakeover = false;
      _pendingSongId = null;
      _pendingSong = null;
      _pendingSourceSongId = null;
      _declinedForSongId = null;
      _declinedForSourceSongId = null;
      // The pending prompt and mode-readiness explanation are both visible
      // state; refresh the UI immediately even if playback is outside the
      // transition window and the scheduled evaluation returns early.
      notifyListeners();
      _scheduleEvaluate();
    }
    if (m.lastMotivationIntents.isEmpty) return;
    final intent = m.lastMotivationIntents.last;
    if (intent.type != MotivationIntentType.musicFollowupSuggested) return;
    if (_lastMotivationFollowupAt == intent.at) return;
    _lastMotivationFollowupAt = intent.at;
    _scheduleEvaluate();
  }

  void _onAuthorityEvent() {
    final event = _authority.lastEvent;
    if (event == null) return;
    if (event.kind == PlaybackEventKind.userCommand || event.kind == PlaybackEventKind.automaticCommand) {
      _scheduleEvaluate();
    }
  }

  void _scheduleEvaluate() {
    if (_evaluationScheduled) return;
    _evaluationScheduled = true;
    scheduleMicrotask(() async {
      _evaluationScheduled = false;
      await _evaluate();
    });
  }

  Future<void> _loadConsentAndEvaluate() async {
    _consentGranted = await IntelligenceSettingsStore.autopilotConsent();
    _consentLoaded = true;
    await _evaluate();
  }

  Future<void> allowPendingTakeover() async {
    if (!hasPendingTakeover) return;
    final pending = _pendingSongId;
    _consentGranted = true;
    _pendingTakeover = false;
    _pendingSongId = null;
    _pendingSong = null;
    _pendingSourceSongId = null;
    await CompanionDecisionLog.record(
      source: 'autopilot',
      action: 'takeover_allowed',
      detail: 'You allowed the pending Autopilot takeover.',
      songId: pending,
    );
    await ResonateDiagnostics.record('intelligence_notification_action', {
      'action': 'accepted', 'songId': pending, 'mode': intelligence.autonomyLabel,
    });
    await IntelligenceSettingsStore.setAutopilotConsent(true);
    notifyListeners();
    await _evaluate(forceTransition: true);
  }

  Future<void> denyPendingTakeover() async {
    final pending = _pendingSongId;
    final sourceSongId = _pendingSourceSongId;
    _pendingTakeover = false;
    _pendingSongId = null;
    _pendingSong = null;
    _pendingSourceSongId = null;
    if (pending != null) {
      _declinedForSongId = pending;
      _declinedForSourceSongId = sourceSongId;
    }
    await ResonateDiagnostics.record('intelligence_notification_action', {
      'action': 'rejected', 'songId': pending, 'mode': intelligence.autonomyLabel,
    });
    notifyListeners();
  }

  Future<void> _evaluate({bool forceTransition = false}) async {
    // Phase 5: Intelligence off or not in Autopilot mode → never drive playback.
    if (!_consentLoaded || !intelligence.isEnabled || !intelligence.isAutopilot) return;
    final evaluatedSourceSongId = music.currentSong?.id;
    if (evaluatedSourceSongId == null) return;
    final evaluatedMode = modes?.mode;
    if (!music.isPlaying && !forceTransition) return;

    final now = DateTime.now();
    if (!forceTransition &&
        _lastEvaluation != null &&
        now.difference(_lastEvaluation!) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastEvaluation = now;

    final automaticQueue = await IntelligenceSettingsStore.automaticQueue();
    final threshold = await IntelligenceSettingsStore.confidenceThreshold();
    _lastConfidenceThreshold = threshold;
    if (!intelligence.isEnabled || !intelligence.isAutopilot) return;
    final modePolicy = modes?.policy;
    final useCrossfade = AutopilotModePolicy.shouldUseCrossfade(
      userCrossfadeEnabled: await IntelligenceSettingsStore.autopilotCrossfade(),
      policy: modePolicy,
    );

    // A mode may explicitly opt out of automatic next-track behavior. This is
    // a policy gate only; direct user transport remains unaffected.
    if (!AutopilotModePolicy.allowsAutomaticNext(modePolicy)) return;

    // Keep the queue topped up early — Phase 5: only with explicit consent.
    final duration = music.currentDuration;
    final remaining = duration == null ? null : duration - music.currentPosition;
    if (_consentGranted && automaticQueue && (remaining == null || remaining <= const Duration(seconds: 30))) {
      await _ensurePredictedQueue(threshold);
    }
    if (!intelligence.isEnabled || !intelligence.isAutopilot) return;

    if (_transitionInFlight) return;

    final currentDuration = music.currentDuration;
    if (currentDuration == null) return;
    final currentRemaining = currentDuration - music.currentPosition;

    // Only act when we are close to the end (or forced)
    if (!forceTransition && currentRemaining > const Duration(seconds: 10)) return;
    if (_transitionSongId == music.currentSong?.id) return;

    // Prefer the highest-confidence recommendation that is not the current song
    final candidates = _activeRecommendationPool
        .where((r) => r.song.id != music.currentSong?.id && r.confidence >= threshold)
        .toList();

    Song? nextSong;
    IntelligenceRecommendation? recommendation;

    if (candidates.isNotEmpty) {
      final arranged = await _arrangeForActiveMode(
        candidates.map((item) => item.song).toList(growable: false),
      );
      if (arranged.isNotEmpty) {
        nextSong = arranged.first;
        recommendation = candidates.firstWhere(
          (item) => item.song.id == nextSong!.id,
        );
      }
    } else if (intelligence.isAutopilotGraduated) {
      // Existing queued tracks are also checked against the active mode's
      // DJ constraints before Autopilot is allowed to choose one.
      if (music.queueIndex < music.queue.length - 1) {
        final upcoming = music.queue.skip(music.queueIndex + 1).toList();
        final modeSafe = _applyModeBias(upcoming);
        final arranged = await _arrangeForActiveMode(modeSafe);
        if (arranged.isNotEmpty) nextSong = arranged.first;
      } else if (_mayMutatePlayback) {
        await _ensurePredictedQueue(threshold);
        if (!_requirePlaybackMutationPermission('fallback_enqueue')) return;
        final pool = _activeRecommendationPool;
        final top = pool.isEmpty ? null : pool.first.song;
        if (top != null && top.id != music.currentSong?.id) {
          final arranged = await _arrangeForActiveMode([top]);
          if (evaluatedSourceSongId != music.currentSong?.id ||
              evaluatedMode != modes?.mode) {
            _scheduleEvaluate();
            return;
          }
          if (arranged.isNotEmpty) {
            if (!_requirePlaybackMutationPermission('fallback_enqueue_after_plan')) return;
            await music.enqueueSongs(arranged, preserveOrder: true);
            nextSong = arranged.first;
          }
        }
      }
    }

    if (nextSong == null) return;

    // The planner and diagnostics both await I/O. A manual skip, mode change,
    // or consent update during either await invalidates this decision.
    if (evaluatedSourceSongId != music.currentSong?.id ||
        evaluatedMode != modes?.mode) {
      _scheduleEvaluate();
      return;
    }

    // Phase 5 consent gate: no play APIs without consent (forceTransition only
    // after allowPendingTakeover which sets _consentGranted = true).
    if (!_consentGranted) {
      if (AutopilotModePolicy.shouldSuppressDeclinedCandidate(
        declinedSongId: _declinedForSongId,
        declinedSourceSongId: _declinedForSourceSongId,
        candidateSongId: nextSong.id,
        sourceSongId: evaluatedSourceSongId,
      )) return;
      if (!_pendingTakeover) {
        await ResonateDiagnostics.record('intelligence_notification_action', {
          'action': 'shown',
          'songId': nextSong.id,
          'mode': intelligence.autonomyLabel,
          'confidence': recommendation?.confidence ?? 0,
          'reason': recommendation?.reason ?? 'graduated_autopilot',
          'consentGranted': false,
        });
        // Do not surface an approval prompt for a track/mode that is no
        // longer active, or after the user has granted/revoked control while
        // diagnostics were being persisted.
        if (evaluatedSourceSongId != music.currentSong?.id ||
            evaluatedMode != modes?.mode ||
            _consentGranted ||
            !intelligence.isEnabled ||
            !intelligence.isAutopilot) {
          _scheduleEvaluate();
          return;
        }
        _pendingTakeover = true;
        _pendingSongId = nextSong.id;
        _pendingSong = nextSong;
        _pendingSourceSongId = evaluatedSourceSongId;
        notifyListeners();
      }
      return;
    }

    if (evaluatedSourceSongId != music.currentSong?.id ||
        evaluatedMode != modes?.mode) {
      _scheduleEvaluate();
      return;
    }

    // Consent granted – may call public play APIs only
    _pendingTakeover = false;
    _pendingSongId = null;
    _pendingSong = null;
    _pendingSourceSongId = null;
    _transitionSongId = music.currentSong?.id;
    _transitionInFlight = true;

    // Capture user intent before any diagnostic await. Otherwise a manual
    // command arriving during logging could be mistaken for the current intent.
    final userGeneration = _authority.userGeneration;
    final automaticGeneration = _authority.beginAutomatic('intelligence_transition');

    await ResonateDiagnostics.record('intelligence_transition', {
      'stage': 'started',
      'mode': intelligence.autonomyLabel,
      'fromSongId': music.currentSong?.id,
      'toSongId': nextSong.id,
      'confidence': recommendation?.confidence ?? 0,
      'reason': recommendation?.reason ?? 'graduated_autopilot',
    });

    try {
      bool decisionStillOwnsPlayback() =>
          !_authority.isStale(automaticGeneration) &&
          userGeneration == _authority.userGeneration &&
          evaluatedSourceSongId == music.currentSong?.id &&
          evaluatedMode == modes?.mode &&
          intelligence.isEnabled &&
          intelligence.isAutopilot &&
          _requirePlaybackMutationPermission('transition_context');

      if (!decisionStillOwnsPlayback()) return;

      // Make sure the chosen song is the immediate next item in the queue.
      // Re-check authority after every await: a manual transport command or
      // mode/consent change must win over an older automatic decision.
      final upcoming = music.queue.skip(music.queueIndex + 1).toList();
      final alreadyNext = upcoming.isNotEmpty && upcoming.first.id == nextSong.id;
      if (!alreadyNext) {
        if (!decisionStillOwnsPlayback()) return;
        await music.playNext(nextSong);
        if (!decisionStillOwnsPlayback()) return;
      }
      if (!decisionStillOwnsPlayback()) return;

      if (useCrossfade && music.canCrossfadeNext && music.isPlaying) {
        final ms = await IntelligenceSettingsStore.autopilotCrossfadeMs();
        if (!decisionStillOwnsPlayback()) return;
        final ok = await music.performTrueCrossfade(milliseconds: ms, fadeType: 'ease_in_out');
        // A user command during the crossfade owns the resulting playback;
        // never issue an automatic fallback-next over that newer command.
        if (!decisionStillOwnsPlayback()) return;
        if (!ok) {
          if (!decisionStillOwnsPlayback()) return;
          await music.nextSong(source: 'intelligence');
        }
      } else {
        if (!decisionStillOwnsPlayback()) return;
        await music.nextSong(source: 'intelligence');
      }

      await ResonateDiagnostics.record('intelligence_transition', {
        'stage': 'completed',
        'mode': intelligence.autonomyLabel,
        'fromSongId': music.currentSong?.id,
        'queueIndex': music.queueIndex,
      });
    } catch (e) {
      await ResonateDiagnostics.record('intelligence_transition', {
        'stage': 'failed',
        'mode': intelligence.autonomyLabel,
        'error': e.toString(),
      });
      debugPrint('Autopilot transition failed: $e');
    } finally {
      _transitionInFlight = false;
      _transitionSongId = null;
      unawaited(_ensurePredictedQueue(threshold));
    }
  }


  /// Applies the shared DJ planner after the mode's media-type filter.
  /// A missing/insufficient beat-grid never silently degrades to a random pick.
  Future<List<Song>> _arrangeForActiveMode(List<Song> songs) async {
    final activeModes = modes;
    if (activeModes == null || songs.isEmpty) return songs;
    try {
      final result = await _modeQueuePlanner.arrange(
        modes: activeModes,
        tracks: songs,
      );
      if (!result.usedDjPlanner) {
        _modeQueueBlockedReason = null;
        return result.songs;
      }
      if (!result.isUsable) {
        _modeQueueBlockedReason = result.message ??
            'DJ analysis is not ready for the active music mode.';
        notifyListeners();
        return const [];
      }
      _modeQueueBlockedReason =
          result.plan != null && result.plan!.status != QueuePlanStatus.ready
              ? result.message
              : null;
      return result.songs;
    } catch (error) {
      _modeQueueBlockedReason = 'DJ queue planning could not complete: $error';
      notifyListeners();
      return const [];
    }
  }

  /// Resolves generated Autopilot candidates against the active Mode.
  /// An active Mode is strict for generated content: if nothing matches, we
  /// return an empty set rather than leaking an avoided media type.
  List<Song> _applyModeBias(List<Song> songs) {
    final m = modes;
    if (m == null || songs.isEmpty) return songs;
    return _modeContentResolver.resolve(
      modes: m,
      songs: songs,
      preferPreferredContent: true,
    );
  }

  Future<void> _ensurePredictedQueue(double threshold) async {
    // Queue mutation is a playback API — require consent + Autopilot.
    if (!_requirePlaybackMutationPermission('queue_decision_start')) return;
    if (_queueDecisionInFlight) return;
    _queueDecisionInFlight = true;
    try {
      await intelligence.refreshRecommendations(notify: false);
      if (!_requirePlaybackMutationPermission('queue_after_refresh')) return;
      final planningSourceSongId = music.currentSong?.id;
      if (planningSourceSongId == null) return;
      final planningMode = modes?.mode;
      final futureQueued = music.queue.skip(music.queueIndex + 1).map((song) => song.id).toSet();
      final modePolicy = modes?.policy;
      final sequenceCount = AutopilotModePolicy.predictedSequenceCount(modePolicy);
      final activeModes = modes;
      final intent = activeModes == null ? null : QueueIntent.forMode(activeModes.mode);
      List<Song> arranged;
      List<Song> considered = const [];
      if (activeModes != null && intent != null) {
        // Search the whole mode-aware recommendation pool before selecting the
        // next runway. Choosing only the generic top 2/4 first can miss every
        // BPM-compatible track even when suitable analyzed tracks are available.
        final available = _applyModeBias(_activeRecommendationPool
            .where((item) =>
                item.song.id != music.currentSong?.id &&
                !futureQueued.contains(item.song.id))
            .map((item) => item.song)
            .toList(growable: false));
        considered = available;
        if (available.isEmpty) {
          _modeQueueBlockedReason = null;
          notifyListeners();
          return;
        }
        final result = await _modeQueuePlanner.arrange(
          modes: activeModes,
          tracks: available,
        );
        if (!_requirePlaybackMutationPermission('queue_after_decision')) return;
        if (planningSourceSongId != music.currentSong?.id ||
            planningMode != modes?.mode) return;
        if (!result.isUsable) {
          _modeQueueBlockedReason = result.message ??
              'No analyzed tracks currently meet the active mode profile.';
          notifyListeners();
          await ResonateDiagnostics.record('intelligence_queue_decision', {
            'mode': intelligence.autonomyLabel,
            'candidates': available.map((song) => song.id).toList(),
            'added': false,
            'djIntentBlocked': _modeQueueBlockedReason,
          });
          return;
        }
        _modeQueueBlockedReason =
            result.plan != null && result.plan!.status != QueuePlanStatus.ready
                ? result.message
                : null;
        arranged = result.songs.take(sequenceCount).toList(growable: false);
      } else {
        final candidates = await _decisionEngine.chooseSequence(
          recommendations: _activeRecommendationPool,
          queuedIds: futureQueued,
          currentSong: music.currentSong,
          sessionMode: intelligence.sessionMode,
          sessionSkipStreak: intelligence.sessionSkipStreak,
          sessionCompletionStreak: intelligence.sessionCompletionStreak,
          sessionArtistCounts: intelligence.sessionArtistCounts,
          count: sequenceCount,
        );
        if (!_requirePlaybackMutationPermission('queue_after_decision')) return;
        final biased = _applyModeBias(candidates);
        considered = biased;
        arranged = await _arrangeForActiveMode(biased);
        if (planningSourceSongId != music.currentSong?.id ||
            planningMode != modes?.mode) return;
      }
      if (arranged.isNotEmpty) {
        if (!_requirePlaybackMutationPermission('queue_enqueue')) return;
        final added = await music.enqueueSongs(arranged, preserveOrder: true);
        await ResonateDiagnostics.record('intelligence_queue_decision', {
          'mode': intelligence.autonomyLabel,
          'candidates': arranged.map((song) => song.id).toList(),
          'added': added,
          'queueLength': music.queue.length,
          'queueIndex': music.queueIndex,
          'djIntentBlocked': false,
        });
        if (added) {
          unawaited(CompanionDecisionLog.record(
            source: 'autopilot',
            action: 'enqueue',
            detail: 'Queued predicted track(s) under your consent and active mode constraints.',
            songId: arranged.first.id,
          ));
        }
      } else if (considered.isNotEmpty) {
        await ResonateDiagnostics.record('intelligence_queue_decision', {
          'mode': intelligence.autonomyLabel,
          'candidates': considered.map((song) => song.id).toList(),
          'added': false,
          'djIntentBlocked': _modeQueueBlockedReason,
        });
      }
    } finally {
      _queueDecisionInFlight = false;
    }
  }

  @override
  void dispose() {
    music.removeListener(_onPlaybackChanged);
    intelligence.removeListener(_onIntelligenceChanged);
    modes?.removeListener(_onModesChanged);
    _authority.removeListener(_onAuthorityEvent);
    super.dispose();
  }
}
