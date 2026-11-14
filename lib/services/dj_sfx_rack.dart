import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_effects_bridge.dart';
import 'playback_engine_session.dart';
import 'playback_backend.dart';
import '../dj_engine/core/dj_types.dart';
import '../dj_engine/core/dj_policy.dart';

/// Transition SFX — engine FX + optional one-shot sample packs.
/// Conservative base gain for one-shot DJ samples, before transition ducking.
/// Scores outside the expected range (or non-finite scores) are normalized safely.
@visibleForTesting
double djSfxOneShotVolumeForEnergy(double score) {
  final normalized = score.isFinite ? score.clamp(0.0, 1.0).toDouble() : 0.5;
  if (normalized >= 0.85) return 0.08;
  if (normalized >= 0.70) return 0.10;
  return 0.12;
}

enum DjSfxPreset {
  echo,
  vinylStop,
  rewind,
  filterOpen,
  filterClose,
  tightGlue,
  dryEcho,
  airHorn,
  gunshot,
  vinylScratch,
  repeat,
  repeatRestart,
  scratch,
  stutter,
  beatRepeat,
  retrigger,
  brake,
  whoosh,
  impact,
}

class DjSfxRack {
  DjSfxRack({math.Random? random}) : _rng = random ?? math.Random();

  final math.Random _rng;
  final Map<DjSfxPreset, int> _usageCounts = <DjSfxPreset, int>{};
  DjSfxPreset? activePreset;
  bool engaged = false;
  List<double>? _savedEqGainsA;
  List<double>? _savedEqGainsB;
  bool _eqTouched = false;
  PlaybackEngineSession? _playbackSession;
  int _oneshotGen = 0;
  double _oneshotBaseVolume = 0.0;
  bool _auxiliaryOneShotActive = false;
  int _delayedSfxGen = 0;
  int _trackFxGen = 0;
  int _engageGen = 0;
  bool _trackActionRunning = false;
  PlaybackEngineSession? _trackAutomationSession;
  double _trackAutomationOriginalSpeed = 1.0;
  List<int> _beatMs = const <int>[];
  List<int> _phraseAnchors = const <int>[];

  static const presets = DjSfxPreset.values;

  /// Asset paths for sample-based presets.
  static const sampleAssets = <DjSfxPreset, String>{
    DjSfxPreset.airHorn: 'assets/sfx/airhorn.wav',
    DjSfxPreset.gunshot: 'assets/sfx/gunshot.wav',
    DjSfxPreset.vinylScratch: 'assets/sfx/vinyl_scratch.wav',
    DjSfxPreset.rewind: 'assets/sfx/rewind.wav',
    DjSfxPreset.whoosh: 'assets/sfx/whoosh.wav',
    DjSfxPreset.impact: 'assets/sfx/impact.wav',
  };

  bool _isSample(DjSfxPreset p) => sampleAssets.containsKey(p);

  static const _safePresets = <DjSfxPreset>[
    DjSfxPreset.tightGlue,
    DjSfxPreset.dryEcho,
    DjSfxPreset.echo,
    DjSfxPreset.filterOpen,
    DjSfxPreset.filterClose,
  ];

  static const _balancedPresets = <DjSfxPreset>[
    DjSfxPreset.tightGlue,
    DjSfxPreset.dryEcho,
    DjSfxPreset.echo,
    DjSfxPreset.filterOpen,
    DjSfxPreset.filterClose,
    DjSfxPreset.whoosh,
    DjSfxPreset.rewind,
    DjSfxPreset.vinylStop,
  ];

  static const _musicalPresets = <DjSfxPreset>[
    DjSfxPreset.tightGlue,
    DjSfxPreset.echo,
    DjSfxPreset.whoosh,
    DjSfxPreset.impact,
    DjSfxPreset.vinylScratch,
    DjSfxPreset.scratch,
    DjSfxPreset.stutter,
    DjSfxPreset.brake,
    // Repeat SFX seeks the outgoing player during a live fade; keep it out
    // of the automatic candidate pool until that interaction is redesigned.
    DjSfxPreset.airHorn,
    DjSfxPreset.gunshot,
    DjSfxPreset.beatRepeat,
  ];

  List<DjSfxPreset> _bagFor(DjAggressiveness aggressiveness) {
    return switch (aggressiveness) {
      DjAggressiveness.safe => _safePresets,
      DjAggressiveness.balanced => _balancedPresets,
      DjAggressiveness.musical => _musicalPresets,
    };
  }

  /// If the preferred effect has already been used twice, rotate to an
  /// underused effect from the same aggressiveness pool when possible.
  DjSfxPreset _applyUsageFairness(
    DjSfxPreset preferred, {
    required DjAggressiveness aggressiveness,
  }) {
    if ((_usageCounts[preferred] ?? 0) < 2) return preferred;
    final alternatives = _bagFor(aggressiveness)
        .where((preset) =>
            preset != preferred && (_usageCounts[preset] ?? 0) < 2)
        .toList();
    if (alternatives.isEmpty) return preferred;
    final lowestCount = alternatives
        .map((preset) => _usageCounts[preset] ?? 0)
        .reduce((a, b) => a < b ? a : b);
    final leastUsed = alternatives
        .where((preset) => (_usageCounts[preset] ?? 0) == lowestCount)
        .toList();
    return leastUsed[_rng.nextInt(leastUsed.length)];
  }

  DjSfxPreset pickRandom({
    double energyScore = 0.5,
    DjAggressiveness aggressiveness = DjAggressiveness.balanced,
  }) {
    final bag = _bagFor(aggressiveness);
    final high = energyScore >= 0.75;
    final weights = <DjSfxPreset, int>{};
    for (final p in bag) {
      var w = 2;
      if (p == DjSfxPreset.tightGlue || p == DjSfxPreset.dryEcho) w = 4;
      if (p == DjSfxPreset.airHorn || p == DjSfxPreset.gunshot) w = high ? 1 : 0;
      if (p == DjSfxPreset.stutter || p == DjSfxPreset.beatRepeat) w = high ? 2 : 1;
      if (w > 0) weights[p] = w;
    }
    if (weights.isEmpty) return DjSfxPreset.tightGlue;
    final total = weights.values.fold<int>(0, (a, b) => a + b);
    var r = _rng.nextInt(total);
    for (final e in weights.entries) {
      r -= e.value;
      if (r < 0) return e.key;
    }
    return DjSfxPreset.tightGlue;
  }

  Future<void> engage({
    required double energyScore,
    DjSfxPreset? preset,
    dynamic equalizerA,
    dynamic equalizerB,
    String? outgoingUri,
    List<int> beatMs = const <int>[],
    List<DjSection> sections = const <DjSection>[],
    DjTransitionKind? transitionKind,
    DjAggressiveness aggressiveness = DjAggressiveness.balanced,
    PlaybackEngineSession? playbackSession,
  }) async {
    // Do not let two transition effects mutate the same player/EQ at once.
    if (engaged || _eqTouched) {
      await restore(
        equalizerA: equalizerA,
        equalizerB: equalizerB,
        playbackSession: _playbackSession,
      );
    }
    _playbackSession = playbackSession;
    final generation = ++_engageGen;
    final score =
        energyScore.isFinite ? energyScore.clamp(0.0, 1.0).toDouble() : 0.5;
    // Media3 session effects are restricted to capabilities implemented by
    // its canonical service session; track automation uses serialized seek/speed.
    final requested = preset ??
        _pickPhraseAwarePreset(
          energyScore: score,
          transitionKind: transitionKind,
          sections: sections,
          positionMs: playbackSession?.position.inMilliseconds ?? 0,
          aggressiveness: aggressiveness,
        );

    // Legacy repeat/repeat-restart are still kept out of automatic selection
    // until the user has explicitly opted into track automation. Media3's
    // serialized session path now owns and cancels those operations.
    final preferred = playbackSession != null
        ? requested
        : switch (requested) {
            DjSfxPreset.repeat || DjSfxPreset.repeatRestart =>
              aggressiveness == DjAggressiveness.safe
                  ? DjSfxPreset.tightGlue
                  : (score >= 0.75 ? DjSfxPreset.whoosh : DjSfxPreset.echo),
            _ => requested,
          };
    final sessionSafePreset = playbackSession == null
        ? preferred
        : (_usesEq(preferred) || _isSample(preferred) ||
                _usesTrackManipulation(preferred) ||
                preferred == DjSfxPreset.echo || preferred == DjSfxPreset.dryEcho
            ? preferred
            : (transitionKind == DjTransitionKind.outroIntro
                ? DjSfxPreset.filterClose
                : DjSfxPreset.filterOpen));
    activePreset = playbackSession == null
        ? _applyUsageFairness(sessionSafePreset, aggressiveness: aggressiveness)
        : sessionSafePreset;
    _usageCounts[activePreset!] = (_usageCounts[activePreset!] ?? 0) + 1;
    engaged = true;
    _eqTouched = false;
    _beatMs = List<int>.from(beatMs)..sort();
    _phraseAnchors = _buildPhraseAnchors(_beatMs);
    try {
      if (playbackSession == null) {
        _savedEqGainsA = await _snapshotEq(equalizerA);
        if (generation != _engageGen || !engaged) return;
        _savedEqGainsB = await _snapshotEq(equalizerB);
        if (generation != _engageGen || !engaged) return;
      }
      if (playbackSession == null) {
        await AudioEffectsBridge.setBassBoost(0.0);
        if (generation != _engageGen || !engaged) return;
        await _applyFxAt(
          0.0,
          score,
          isCurrent: () => generation == _engageGen && engaged,
        );
        if (generation != _engageGen || !engaged) return;
      }
      if (_usesEq(activePreset!)) {
        // Mark EQ as touched before the first await so restore can recover even
        // if cancellation arrives between applying the two engine equalizers.
        _eqTouched = true;
        if (playbackSession != null) {
          await _applyDeckEqAt(
            playbackSession,
            'active',
            0.0,
            isCurrent: () => generation == _engageGen && engaged,
          );
          if (generation != _engageGen || !engaged) return;
          await _applyDeckEqAt(
            playbackSession,
            'standby',
            0.0,
            isCurrent: () => generation == _engageGen && engaged,
          );
        } else {
          await _applyEqAt(
            equalizerA,
            0.0,
            isCurrent: () => generation == _engageGen && engaged,
          );
          if (generation != _engageGen || !engaged) return;
          await _applyEqAt(
            equalizerB,
            0.0,
            isCurrent: () => generation == _engageGen && engaged,
          );
        }
        if (generation != _engageGen || !engaged) return;
      }
      // Auxiliary samples and track automation are routed only through the
      // canonical Media3 session. No secondary Flutter audio player is created.
      if (playbackSession != null && _isSample(activePreset!)) {
        unawaited(_playOneshot(activePreset!, score));
      }
      if (playbackSession != null &&
          (activePreset == DjSfxPreset.echo || activePreset == DjSfxPreset.dryEcho)) {
        unawaited(_playTrackEchoOnSession(outgoingUri, score));
      }
      if (playbackSession != null && _usesTrackManipulation(activePreset!)) {
        unawaited(_runTrackManipulationOnSession(activePreset!, playbackSession));
      }
    } catch (e) {
      debugPrint('DjSfxRack.engage: $e');
    }
  }

  Future<void> tick(
    double t, {
    dynamic equalizerA,
    dynamic equalizerB,
    double energyScore = 0.5,
    PlaybackEngineSession? playbackSession,
  }) async {
    if (!engaged || activePreset == null) return;
    final generation = _engageGen;
    bool isCurrent() => generation == _engageGen && engaged;
    final score =
        energyScore.isFinite ? energyScore.clamp(0.0, 1.0).toDouble() : 0.5;
    try {
      final session = playbackSession ?? _playbackSession;
      if (session == null) {
        await _applyFxAt(t, score, isCurrent: isCurrent);
      }
      if (!isCurrent() || activePreset == null) return;
      if (_usesEq(activePreset!)) {
        _eqTouched = true;
        if (session != null) {
          await _applyDeckEqAt(session, 'active', t, isCurrent: isCurrent);
          if (!isCurrent()) return;
          await _applyDeckEqAt(session, 'standby', t, isCurrent: isCurrent);
        } else {
          await _applyEqAt(equalizerA, t, isCurrent: isCurrent);
          if (!isCurrent()) return;
          await _applyEqAt(equalizerB, t, isCurrent: isCurrent);
        }
        if (!isCurrent()) return;
      }
      // Duck the service-owned auxiliary sample under the incoming rise.
      if (_auxiliaryOneShotActive && _oneshotBaseVolume > 0) {
        final progress = t.clamp(0.0, 1.6);
        final duck = progress <= 1.0
            ? (1.0 - progress * 0.85)
            : (0.15 * (1.6 - progress) / 0.6).clamp(0.0, 0.15);
        final volume = (_oneshotBaseVolume * duck).clamp(0.0, 0.14);
        try {
          final candidate = playbackSession ?? _playbackSession;
          if (candidate is PlaybackAuxiliaryEffectsBackend) {
            final auxiliary = candidate as PlaybackAuxiliaryEffectsBackend;
            await auxiliary.setAuxiliarySoundVolume(volume);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Immediately invalidates an in-flight Media3 track automation sequence.
  /// The generation is advanced before the first await, so a manual transport
  /// command queued immediately after this call cannot be followed by a stale
  /// DJ seek/rate step. The captured playback rate is restored on the same
  /// serialized session command lane.
  Future<void> cancelTrackAutomation() async {
    ++_trackFxGen;
    _trackActionRunning = false;
    final session = _trackAutomationSession;
    _trackAutomationSession = null;
    if (session == null) return;
    try {
      await session.setPlaybackSpeed(_trackAutomationOriginalSpeed);
    } catch (_) {}
  }

  Future<void> restore({
    dynamic equalizerA,
    dynamic equalizerB,
    PlaybackEngineSession? playbackSession,
  }) async {
    ++_delayedSfxGen;
    ++_oneshotGen;
    ++_engageGen;
    // Cancel before any effect teardown awaits; stale track automation cannot
    // enqueue another seek/rate command behind a user's transport operation.
    await cancelTrackAutomation();
    final hadActiveEffects = engaged || _eqTouched;
    if (!hadActiveEffects) {
      await _stopOneshot();
      return;
    }
    try {
      final session = playbackSession ?? _playbackSession;
      await _stopOneshot();
      if (session == null) {
        final prefs = await SharedPreferences.getInstance();
        final effectsEnabled = prefs.getBool('effects_enabled') ?? true;
        final reverb = prefs.getDouble('reverb') ?? 0.0;
        final virt = prefs.getDouble('virtualizer') ?? 0.0;
        final bass = prefs.getDouble('bassBoost') ?? 0.0;
        await AudioEffectsBridge.setBassBoost(effectsEnabled ? bass : 0.0);
        await AudioEffectsBridge.setReverb(effectsEnabled ? reverb : 0.0);
        await AudioEffectsBridge.setVirtualizer(effectsEnabled ? virt : 0.0);
      }
      if (_eqTouched) {
        if (session != null) {
          await session.clearDeckEqOverlay(deck: 'active');
          await session.clearDeckEqOverlay(deck: 'standby');
        } else {
          await _restoreEq(equalizerA, _savedEqGainsA);
          await _restoreEq(equalizerB, _savedEqGainsB);
        }
      }
    } catch (e) {
      debugPrint('DjSfxRack.restore: $e');
    } finally {
      engaged = false;
      _eqTouched = false;
      activePreset = null;
      _savedEqGainsA = null;
      _savedEqGainsB = null;
      _playbackSession = null;
      _beatMs = const <int>[];
      _phraseAnchors = const <int>[];
    }
  }

  /// Schedule an actual-track SFX without blocking transition playback.
  Future<void> engageDelayed({
    required Duration delay,
    required double energyScore,
    DjSfxPreset? preset,
    dynamic equalizerA,
    dynamic equalizerB,
    String? outgoingUri,
    List<int> beatMs = const <int>[],
    List<DjSection> sections = const <DjSection>[],
    DjTransitionKind? transitionKind,
    DjAggressiveness aggressiveness = DjAggressiveness.balanced,
    PlaybackEngineSession? playbackSession,
  }) async {
    final gen = ++_delayedSfxGen;
    try {
      await Future<void>.delayed(delay);
      // Cancelled by restore() (gen bump) or a newer schedule — do not engage.
      if (gen != _delayedSfxGen) return;
      await engage(
        energyScore: energyScore,
        preset: preset,
        equalizerA: equalizerA,
        equalizerB: equalizerB,
        outgoingUri: outgoingUri,
        beatMs: beatMs,
        sections: sections,
        transitionKind: transitionKind,
        aggressiveness: aggressiveness,
        playbackSession: playbackSession,
      );
    } catch (e) {
      debugPrint('DjSfxRack.engageDelayed: $e');
    }
  }

  Future<void> _playOneshot(DjSfxPreset preset, double score) async {
    final asset = sampleAssets[preset];
    final candidate = _playbackSession;
    if (asset == null || candidate is! PlaybackAuxiliaryEffectsBackend) return;
    final auxiliary = candidate as PlaybackAuxiliaryEffectsBackend;
    final gen = ++_oneshotGen;
    try {
      await _stopOneshot();
      if (gen != _oneshotGen || !engaged) return;
      _oneshotBaseVolume = djSfxOneShotVolumeForEnergy(score);
      final assetUri = Uri.parse('asset:///flutter_assets/$asset');
      await auxiliary.playAuxiliarySound(assetUri, volume: _oneshotBaseVolume);
      if (gen != _oneshotGen || !engaged) {
        await auxiliary.stopAuxiliarySound();
        return;
      }
      _auxiliaryOneShotActive = true;
      Future<void>.delayed(const Duration(milliseconds: 900), () async {
        if (gen != _oneshotGen) return;
        await _stopOneshot();
      });
    } catch (e) {
      debugPrint('DjSfxRack Media3 oneshot $preset: $e');
    }
  }

  Future<void> _playTrackEchoOnSession(String? rawUri, double score) async {
    final session = _playbackSession;
    if (session == null) return;
    if (session is! PlaybackAuxiliaryEffectsBackend) return;
    if (rawUri == null || rawUri.trim().isEmpty) return;
    final auxiliary = session as PlaybackAuxiliaryEffectsBackend;
    final currentMs = session.position.inMilliseconds;
    final startMs = _musicalEchoStart(currentMs);
    if (startMs < 0) return;
    final durationMs = session.duration?.inMilliseconds;
    final endMs = math.min(durationMs ?? (startMs + 900), startMs + 850);
    if (endMs <= startMs + 80) return;
    final trimmed = rawUri.trim();
    final parsed = Uri.tryParse(trimmed);
    final sourceUri = parsed != null && parsed.hasScheme ? parsed : Uri.file(trimmed);
    final gen = ++_oneshotGen;
    try {
      await _stopOneshot();
      if (gen != _oneshotGen || !engaged) return;
      _oneshotBaseVolume = (score >= 0.85 ? 0.08 : (score >= 0.7 ? 0.10 : 0.12)).clamp(0.05, 0.14);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (gen != _oneshotGen || !engaged) return;
      await auxiliary.playAuxiliarySound(
        sourceUri,
        volume: _oneshotBaseVolume,
        startPosition: Duration(milliseconds: startMs),
        endPosition: Duration(milliseconds: endMs),
      );
      if (gen != _oneshotGen || !engaged) {
        await auxiliary.stopAuxiliarySound();
        return;
      }
      _auxiliaryOneShotActive = true;
      Future<void>.delayed(const Duration(milliseconds: 1100), () async {
        if (gen != _oneshotGen) return;
        await _stopOneshot();
      });
    } catch (e) {
      debugPrint('DjSfxRack Media3 track echo: $e');
    }
  }

  Future<void> _stopOneshot() async {
    _oneshotBaseVolume = 0.0;
    if (_auxiliaryOneShotActive) {
      _auxiliaryOneShotActive = false;
      final candidate = _playbackSession;
      if (candidate is PlaybackAuxiliaryEffectsBackend) {
        final auxiliary = candidate as PlaybackAuxiliaryEffectsBackend;
        try {
          await auxiliary.stopAuxiliarySound();
        } catch (_) {}
      }
    }
  }

  bool _usesTrackManipulation(DjSfxPreset p) =>
      p == DjSfxPreset.repeat ||
      p == DjSfxPreset.repeatRestart ||
      p == DjSfxPreset.vinylStop ||
      p == DjSfxPreset.scratch ||
      p == DjSfxPreset.stutter ||
      p == DjSfxPreset.beatRepeat ||
      p == DjSfxPreset.retrigger ||
      p == DjSfxPreset.brake;

  /// Performs DJ track automation through the canonical session only.
  /// Every seek/rate step is generation-guarded; restore() invalidates the
  /// sequence and restores the session's captured playback rate.
  Future<void> _runTrackManipulationOnSession(
    DjSfxPreset preset,
    PlaybackEngineSession session,
  ) async {
    if (_trackActionRunning) return;
    final gen = ++_trackFxGen;
    final originalSpeed = session.playbackSpeed.clamp(0.5, 2.0).toDouble();
    final current = session.position.inMilliseconds;
    if (current < 120) return;
    _trackActionRunning = true;
    _trackAutomationSession = session;
    _trackAutomationOriginalSpeed = originalSpeed;
    bool currentAction() => gen == _trackFxGen && engaged && identical(_trackAutomationSession, session);
    Future<void> seekTo(int milliseconds) async {
      if (!currentAction()) return;
      await session.seek(Duration(milliseconds: math.max(0, milliseconds)));
    }
    Future<void> setSpeed(double speed) async {
      if (!currentAction()) return;
      await session.setPlaybackSpeed(speed.clamp(0.5, 2.0).toDouble());
    }
    Future<void> pauseFor(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));
    try {
      if (preset == DjSfxPreset.repeat || preset == DjSfxPreset.repeatRestart) {
        final anchor = _musicalPhraseAnchor(current);
        final slice = _musicalSliceMs(anchor);
        final repeatAnchor = math.max(0, anchor - slice);
        for (var i = 0; i < 3; i++) {
          if (!currentAction()) return;
          await seekTo(repeatAnchor);
          await setSpeed(originalSpeed);
          await pauseFor(680);
        }
        if (preset == DjSfxPreset.repeatRestart && currentAction()) {
          await seekTo(0);
          await setSpeed(originalSpeed);
        }
        return;
      }
      if (preset == DjSfxPreset.stutter || preset == DjSfxPreset.beatRepeat) {
        final anchor = _musicalAnchor(current);
        final beat = _musicalSliceMs(anchor);
        final slice = preset == DjSfxPreset.stutter ? (beat ~/ 2).clamp(120, 700) : beat.clamp(250, 1400);
        final start = math.max(0, anchor - slice);
        final count = preset == DjSfxPreset.stutter ? 5 : 4;
        for (var i = 0; i < count; i++) {
          if (!currentAction()) return;
          await seekTo(start);
          await setSpeed(originalSpeed);
          await pauseFor(slice);
        }
        return;
      }
      if (preset == DjSfxPreset.retrigger) {
        final anchor = _musicalAnchor(current);
        final beat = _musicalSliceMs(anchor);
        final start = math.max(0, anchor - beat);
        for (var i = 0; i < 3; i++) {
          if (!currentAction()) return;
          await seekTo(start);
          await setSpeed(originalSpeed);
          await pauseFor(beat.clamp(250, 1400));
        }
        return;
      }
      if (preset == DjSfxPreset.brake || preset == DjSfxPreset.vinylStop) {
        for (final multiplier in <double>[0.94, 0.82, 0.70, 0.58, 0.50]) {
          if (!currentAction()) return;
          await setSpeed(originalSpeed * multiplier);
          await pauseFor(110);
        }
        return;
      }
      final center = _musicalPhraseAnchor(current);
      const strokes = <int>[120, -100, 150, -130, 80];
      for (final delta in strokes) {
        if (!currentAction()) return;
        await seekTo(center + delta);
        await setSpeed(originalSpeed * (delta >= 0 ? 1.55 : 0.62));
        await pauseFor(115);
      }
    } catch (e) {
      debugPrint('DjSfxRack Media3 track manipulation $preset: $e');
    } finally {
      if (gen == _trackFxGen) {
        if (identical(_trackAutomationSession, session)) {
          try {
            await session.setPlaybackSpeed(originalSpeed);
          } catch (_) {}
          _trackAutomationSession = null;
        }
        _trackActionRunning = false;
      }
    }
  }

  int _musicalAnchor(int currentMs) {
    if (_beatMs.isEmpty) return math.max(0, currentMs - 350);
    var best = _beatMs.first;
    var distance = (best - currentMs).abs();
    for (final beat in _beatMs) {
      if (beat > currentMs + 900) break;
      final d = (beat - currentMs).abs();
      if (d < distance) { best = beat; distance = d; }
    }
    return math.max(0, best);
  }

  int _musicalSliceMs(int anchorMs) {
    final i = _beatMs.indexOf(anchorMs);
    if (i < 0 || i + 1 >= _beatMs.length) return 700;
    return (_beatMs[i + 1] - _beatMs[i]).clamp(250, 1400);
  }

  DjSfxPreset _pickPhraseAwarePreset({
    required double energyScore,
    DjTransitionKind? transitionKind,
    List<DjSection> sections = const <DjSection>[],
    int positionMs = 0,
    DjAggressiveness aggressiveness = DjAggressiveness.balanced,
  }) {
    if (aggressiveness == DjAggressiveness.safe) {
      return switch (transitionKind) {
        DjTransitionKind.safeCrossfade => DjSfxPreset.dryEcho,
        DjTransitionKind.outroIntro => DjSfxPreset.filterClose,
        DjTransitionKind.energyBridge => DjSfxPreset.echo,
        _ => DjSfxPreset.tightGlue,
      };
    }

    DjSection? section;
    for (final s in sections) {
      if (positionMs >= s.startMs && positionMs < s.endMs) {
        section = s;
        break;
      }
    }

    DjSfxPreset chosen = switch (transitionKind) {
      DjTransitionKind.breakdownDrop =>
        energyScore >= 0.72 ? DjSfxPreset.impact : DjSfxPreset.whoosh,
      DjTransitionKind.phraseBlend => section?.type == DjSectionType.breakdown
          ? DjSfxPreset.repeatRestart
          : DjSfxPreset.repeat,
      DjTransitionKind.beatBlend => energyScore >= 0.86
          ? DjSfxPreset.stutter
          : (energyScore >= 0.78 ? DjSfxPreset.scratch : DjSfxPreset.repeat),
      DjTransitionKind.energyBridge =>
        energyScore >= 0.75 ? DjSfxPreset.whoosh : DjSfxPreset.echo,
      DjTransitionKind.outroIntro => energyScore >= 0.82
          ? DjSfxPreset.brake
          : (energyScore >= 0.75 ? DjSfxPreset.filterClose : DjSfxPreset.echo),
      DjTransitionKind.safeCrossfade => DjSfxPreset.dryEcho,
      null => pickRandom(
          energyScore: energyScore,
          aggressiveness: aggressiveness,
        ),
    };

    if (aggressiveness == DjAggressiveness.balanced) {
      const banned = {
        DjSfxPreset.airHorn,
        DjSfxPreset.gunshot,
        DjSfxPreset.stutter,
        DjSfxPreset.beatRepeat,
        DjSfxPreset.scratch,
        DjSfxPreset.repeatRestart,
        DjSfxPreset.brake,
      };
      if (banned.contains(chosen)) {
        chosen = energyScore >= 0.75 ? DjSfxPreset.whoosh : DjSfxPreset.tightGlue;
      }
    }

    final bag = _bagFor(aggressiveness);
    if (!bag.contains(chosen)) {
      return pickRandom(
        energyScore: energyScore,
        aggressiveness: aggressiveness,
      );
    }
    return chosen;
  }
  List<int> _buildPhraseAnchors(List<int> beats) {
    if (beats.length < 16) return const <int>[];
    final result = <int>[];
    for (var i = 0; i < beats.length; i += 16) {
      result.add(beats[i]);
    }
    return result;
  }

  int _musicalPhraseAnchor(int currentMs) {
    if (_phraseAnchors.isEmpty) return _musicalAnchor(currentMs);
    var best = _phraseAnchors.first;
    var distance = (best - currentMs).abs();
    for (final anchor in _phraseAnchors) {
      if (anchor > currentMs + 1400) break;
      final d = (anchor - currentMs).abs();
      if (d < distance) {
        best = anchor;
        distance = d;
      }
    }
    return math.max(0, best);
  }

  int _musicalEchoStart(int currentMs) {
    if (_beatMs.length < 2) return math.max(0, currentMs - 850);
    final anchor = _musicalAnchor(currentMs);
    final i = _beatMs.indexOf(anchor);
    if (i <= 0) return math.max(0, anchor - 850);
    final beatDuration = (_beatMs[i] - _beatMs[i - 1]).clamp(250, 1400);
    return math.max(0, anchor - beatDuration);
  }

  bool _usesEq(DjSfxPreset p) =>
      p == DjSfxPreset.filterOpen || p == DjSfxPreset.filterClose;

  double _envelope(double t) {
    if (t <= 0) return 0.0;
    if (t < 0.15) return (t / 0.15).clamp(0.0, 1.0);
    if (t <= 1.0) return 1.0;
    return ((1.55 - t) / 0.55).clamp(0.0, 1.0);
  }

  Future<void> _applyFxAt(
    double t,
    double score, {
    bool Function()? isCurrent,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    if (!current()) return;
    final p = activePreset ?? DjSfxPreset.echo;
    final env = _envelope(t);
    final x = t.clamp(0.0, 1.0);
    await AudioEffectsBridge.setBassBoost(0.0);
    if (!current()) return;

    // Sample presets: light reverb bed only (the WAV is the character).
    double width = 0.0;
    double reverb = 0.0;
    if (_isSample(p)) {
      width = (0.04 * env).clamp(0.0, 0.08);
      reverb = (0.10 * env).clamp(0.0, 0.16);
    } else {
      switch (p) {
        case DjSfxPreset.echo:
          width = (0.04 + 0.10 * x).clamp(0.0, 0.18);
          reverb = (0.22 + 0.28 * math.sin(x * math.pi)).clamp(0.12, 0.48);
          break;
        case DjSfxPreset.vinylStop:
          width = (0.06 * (1.0 - x)).clamp(0.0, 0.10);
          reverb = (0.08 + 0.12 * x).clamp(0.04, 0.22);
          break;
        case DjSfxPreset.rewind:
          width = (0.05 * (1.0 - x)).clamp(0.0, 0.10);
          reverb = (0.08 + 0.10 * x).clamp(0.04, 0.20);
          break;
        case DjSfxPreset.filterOpen:
        case DjSfxPreset.filterClose:
          width = (0.05 + 0.08 * x).clamp(0.0, 0.16);
          reverb = (0.08 + 0.10 * math.sin(x * math.pi)).clamp(0.04, 0.22);
          break;
        case DjSfxPreset.repeat:
        case DjSfxPreset.repeatRestart:
        case DjSfxPreset.scratch:
          width = (0.05 * env).clamp(0.0, 0.10);
          reverb = (0.06 * env).clamp(0.0, 0.12);
          break;
        case DjSfxPreset.tightGlue:
          width = (0.04 + 0.06 * x).clamp(0.0, 0.12);
          reverb = (0.14 + 0.16 * math.sin(x * math.pi)).clamp(0.08, 0.32);
          break;
        case DjSfxPreset.dryEcho:
          width = 0.03;
          reverb = (0.16 * math.sin(x * math.pi)).clamp(0.0, 0.22);
          break;
        default:
          break;
      }
    }
    final energyScale = score >= 0.85 ? 0.7 : (score >= 0.7 ? 0.85 : 1.0);
    width = (width * env * energyScale).clamp(0.0, 0.28);
    reverb = (reverb * env * energyScale).clamp(0.0, 0.48);
    await AudioEffectsBridge.setVirtualizer(width);
    if (!current()) return;
    await AudioEffectsBridge.setReverb(reverb);
    if (!current()) return;

  }

  Future<List<double>?> _snapshotEq(dynamic eq) async {
    if (eq == null) return null;
    try {
      final p = await eq.parameters;
      return [for (final b in p.bands) b.gain];
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyEqAt(
    dynamic eq,
    double t, {
    bool Function()? isCurrent,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    if (!current() || eq == null || activePreset == null) return;
    try {
      final p = await eq.parameters;
      if (!current() || activePreset == null) return;
      final bands = p.bands;
      if (bands.isEmpty) return;
      final n = bands.length;
      final minG = p.minDecibels;
      final maxG = p.maxDecibels;
      final env = _envelope(t);
      final x = t.clamp(0.0, 1.0);
      for (var i = 0; i < n; i++) {
        final frac = n <= 1 ? 0.5 : i / (n - 1);
        double gain = 0.0;
        switch (activePreset!) {
          case DjSfxPreset.filterOpen:
            gain = -6.0 * (1.0 - x) * frac;
            break;
          case DjSfxPreset.filterClose:
            gain = -5.5 * (1.0 - x) * (1.0 - frac);
            break;
          default:
            gain = 0.0;
        }
        gain *= env;
        if (!current() || activePreset == null) return;
        await bands[i].setGain(gain.clamp(minG, maxG).toDouble());
      }
      if (!current() || activePreset == null) return;
      await eq.setEnabled(true);
    } catch (_) {}
  }

  /// Applies the same transition filter to a logical Media3 deck. The
  /// native DSP registry composes this temporary response with the saved EQ,
  /// so this path never snapshots or overwrites persistent equalizer gains.
  Future<void> _applyDeckEqAt(
    PlaybackEngineSession session,
    String deck,
    double t, {
    bool Function()? isCurrent,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    if (!current() || activePreset == null) return;
    final n = 31;
    final x = t.clamp(0.0, 1.0);
    final env = _envelope(t);
    final centers = List<double>.generate(
      n,
      (i) => 20.0 * math.pow(1000.0, i / (n - 1)).toDouble(),
      growable: false,
    );
    final gains = List<double>.generate(n, (i) {
      final fraction = i / (n - 1);
      final gain = switch (activePreset!) {
        DjSfxPreset.filterOpen => -6.0 * (1.0 - x) * fraction,
        DjSfxPreset.filterClose => -5.5 * (1.0 - x) * (1.0 - fraction),
        _ => 0.0,
      };
      return (gain * env).clamp(-12.0, 12.0).toDouble();
    }, growable: false);
    if (!current()) return;
    await session.setDeckEqOverlay(
      deck: deck,
      centersHz: centers,
      gainsDb: gains,
    );
  }

  Future<void> _restoreEq(
    dynamic eq,
    List<double>? savedGains,
  ) async {
    if (eq == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final eqOn = prefs.getBool('equalizer_enabled') ?? true;
      final p = await eq.parameters;
      final bands = p.bands;
      for (var i = 0; i < bands.length; i++) {
        double g = 0.0;
        if (savedGains != null && i < savedGains.length) {
          g = savedGains[i];
        } else {
          g = prefs.getDouble('eq_band_${bands[i].index}') ?? 0.0;
        }
        await bands[i]
            .setGain(g.clamp(p.minDecibels, p.maxDecibels).toDouble());
      }
      await eq.setEnabled(eqOn);
    } catch (_) {}
  }

  String get presetName => activePreset?.name ?? 'none';
}

// Local helper — avoid importing dart:async only for unawaited in some SDK configs.
void unawaited(Future<void> f) {
  f.catchError((_) {});
}
