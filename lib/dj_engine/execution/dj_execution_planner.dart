import '../core/dj_types.dart';
import '../core/dj_policy.dart';
import '../intelligence/dj_risk_engine.dart';

/// Converts a musical decision into an engine-neutral timeline.
///
/// The Resonate adapter maps these actions to Audio Engine A/B.
/// No actual playback is performed here.
class DjExecutionPlanner {
  final DjRiskEngine riskEngine;

  const DjExecutionPlanner({this.riskEngine = const DjRiskEngine()});

  DjExecutionPlan plan({
    required DjTrackProfile outgoing,
    required DjTrackProfile incoming,
    required DjTransitionCandidate candidate,
    DjPolicy policy = DjPolicy.balanced,
  }) {
    if (!_profileMetricsValid(outgoing) || !_profileMetricsValid(incoming)) {
      return DjExecutionPlan(
        candidate: candidate,
        fallback: true,
        reason: 'invalid_track_profile',
        steps: const [],
      );
    }

    final candidateMetricsValid =
        candidate.score.isFinite &&
        candidate.confidence.isFinite &&
        candidate.score >= 0 &&
        candidate.score <= 1 &&
        candidate.confidence >= 0 &&
        candidate.confidence <= 1 &&
        candidate.scores.values.every(
          (value) => value.isFinite && value >= 0 && value <= 1,
        );
    if (!candidateMetricsValid) {
      return DjExecutionPlan(
        candidate: candidate,
        fallback: true,
        reason: 'invalid_candidate_metrics',
        steps: const [],
      );
    }

    final outgoingAvailable = outgoing.durationMs == null
        ? null
        : outgoing.durationMs! - candidate.outgoingStartMs;
    final incomingAvailable = incoming.durationMs == null
        ? null
        : incoming.durationMs! - candidate.incomingStartMs;
    if (candidate.outgoingStartMs < 0 ||
        candidate.incomingStartMs < 0 ||
        candidate.durationMs < 2000 ||
        (outgoingAvailable != null &&
            (outgoingAvailable < 2000 || candidate.durationMs > outgoingAvailable)) ||
        (incomingAvailable != null &&
            (incomingAvailable < 2000 || candidate.durationMs > incomingAvailable))) {
      return DjExecutionPlan(
        candidate: candidate,
        fallback: true,
        reason: 'insufficient_playable_duration',
        steps: const [],
      );
    }

    final risks = riskEngine.evaluate(
      outgoing: outgoing,
      incoming: incoming,
      candidate: candidate,
    );
    final severity = riskEngine.severity(risks);

    if (severity >= policy.riskSeverityLimit) {
      return DjExecutionPlan(
        candidate: candidate,
        fallback: true,
        reason: 'risk_too_high',
        steps: const [],
      );
    }

    final bassDuck = risks.contains(DjRiskType.bassCollision);
    final longerFade = risks.contains(DjRiskType.energyShock);
    var durationLimit = 20000;
    if (outgoingAvailable != null && outgoingAvailable < durationLimit) {
      durationLimit = outgoingAvailable;
    }
    if (incomingAvailable != null && incomingAvailable < durationLimit) {
      durationLimit = incomingAvailable;
    }
    final requestedDuration = longerFade
        ? (candidate.durationMs * 1.25).round()
        : candidate.durationMs;
    // The planner owns a 20-second execution ceiling. A candidate may
    // request a longer blend, but execution must cap it rather than passing
    // an inverted clamp range (candidate duration > durationLimit).
    final effectiveDurationMs =
        requestedDuration.clamp(2000, durationLimit).toInt();
    final sfxTriggerMs = _phraseSnappedSfxMs(
      durationMs: effectiveDurationMs,
      kind: candidate.kind,
      outgoing: outgoing,
      outgoingStartMs: candidate.outgoingStartMs,
    );
    final steps = <DjExecutionStep>[
      DjExecutionStep(action: 'prepare_incoming', atMs: 0, parameters: {
        'seekMs': candidate.incomingStartMs,
      }),
      DjExecutionStep(action: 'start_incoming', atMs: 0),
      if (longerFade)
        DjExecutionStep(action: 'extend_crossfade', atMs: 0, parameters: {
          'durationMs': effectiveDurationMs,
        }),
      if (bassDuck)
        DjExecutionStep(action: 'duck_incoming_bass', atMs: 0, parameters: {
          'amount': 0.35,
          'durationMs': effectiveDurationMs ~/ 2,
        }),
      DjExecutionStep(action: 'phrase_align', atMs: 0, parameters: {
        'kind': candidate.kind.name,
      }),
      DjExecutionStep(action: 'trigger_sfx', atMs: sfxTriggerMs, parameters: {
        'kind': candidate.kind.name,
        'snapped': true,
      }),
      DjExecutionStep(action: 'complete_transition', atMs: effectiveDurationMs),
    ];

    if (!_executionStepsValid(
      steps: steps,
      durationMs: effectiveDurationMs,
      incoming: incoming,
      candidate: candidate,
    )) {
      return DjExecutionPlan(
        candidate: candidate,
        fallback: true,
        reason: 'invalid_execution_timeline',
        steps: const [],
      );
    }

    return DjExecutionPlan(
      candidate: candidate,
      steps: steps,
      reason: 'planned',
    );
  }


  static bool _executionStepsValid({
    required List<DjExecutionStep> steps,
    required int durationMs,
    required DjTrackProfile incoming,
    required DjTransitionCandidate candidate,
  }) {
    const allowedActions = {
      'prepare_incoming',
      'start_incoming',
      'extend_crossfade',
      'duck_incoming_bass',
      'phrase_align',
      'trigger_sfx',
      'complete_transition',
    };
    final counts = <String, int>{};
    var previousAtMs = -1;
    for (final step in steps) {
      if (!allowedActions.contains(step.action) ||
          step.atMs < 0 ||
          step.atMs > durationMs ||
          step.atMs < previousAtMs) {
        return false;
      }
      previousAtMs = step.atMs;
      counts.update(step.action, (count) => count + 1, ifAbsent: () => 1);
      final parameters = step.parameters;
      switch (step.action) {
        case 'prepare_incoming':
          final seekMs = parameters['seekMs'];
          if (seekMs is! int ||
              seekMs != candidate.incomingStartMs ||
              seekMs < 0 ||
              (incoming.durationMs != null && seekMs >= incoming.durationMs!)) {
            return false;
          }
          break;
        case 'start_incoming':
          if (step.atMs != 0 || parameters.isNotEmpty) return false;
          break;
        case 'extend_crossfade':
          if (step.atMs != 0 || parameters['durationMs'] != durationMs) {
            return false;
          }
        case 'duck_incoming_bass':
          final amount = parameters['amount'];
          final duckDuration = parameters['durationMs'];
          if (step.atMs != 0 ||
              amount is! num ||
              !amount.isFinite ||
              amount <= 0 ||
              amount > 1 ||
              duckDuration is! int ||
              duckDuration <= 0 ||
              duckDuration > durationMs) {
            return false;
          }
          break;
        case 'phrase_align':
          if (step.atMs != 0 || parameters['kind'] != candidate.kind.name) {
            return false;
          }
          break;
        case 'trigger_sfx':
          if (step.atMs <= 0 ||
              step.atMs >= durationMs ||
              parameters['kind'] != candidate.kind.name ||
              parameters['snapped'] != true) {
            return false;
          }
          break;
        case 'complete_transition':
          if (step.atMs != durationMs || parameters.isNotEmpty) return false;
          break;
      }
    }

    const requiredActions = [
      'prepare_incoming',
      'start_incoming',
      'phrase_align',
      'trigger_sfx',
      'complete_transition',
    ];
    if (requiredActions.any((action) => counts[action] != 1) ||
        counts.values.any((count) => count != 1)) {
      return false;
    }
    if (steps.first.action != 'prepare_incoming' ||
        steps.last.action != 'complete_transition') {
      return false;
    }
    final prepareIndex = steps.indexWhere((s) => s.action == 'prepare_incoming');
    final startIndex = steps.indexWhere((s) => s.action == 'start_incoming');
    if (prepareIndex >= startIndex) return false;
    return true;
  }

  static bool _profileMetricsValid(DjTrackProfile profile) {
    bool unit(double value) => value.isFinite && value >= 0 && value <= 1;
    final beat = profile.beatGrid;
    final spectrum = profile.spectrum;
    final bpm = beat.bpm;
    if ((profile.durationMs != null && profile.durationMs! <= 0) ||
        !unit(profile.analysisConfidence) ||
        (bpm != null && (!bpm.isFinite || bpm <= 40 || bpm >= 240)) ||
        !unit(beat.confidence) ||
        !unit(beat.downbeatConfidence) ||
        !unit(beat.barConfidence) ||
        !unit(beat.phraseConfidence) ||
        beat.beatsPerBar < 1 ||
        beat.beatsPerBar > 12 ||
        beat.beatsPerPhrase < 1 ||
        beat.beatsPerPhrase > 64 ||
        (profile.keyRoot != null &&
            (profile.keyRoot! < 0 || profile.keyRoot! > 11)) ||
        !unit(profile.keyConfidence) ||
        !unit(spectrum.bass) ||
        !unit(spectrum.mids) ||
        !unit(spectrum.highs) ||
        !unit(spectrum.centroid) ||
        !unit(spectrum.bassDensity) ||
        !unit(spectrum.spectralFlux) ||
        !unit(spectrum.confidence)) {
      return false;
    }
    bool validTimes(List<int> times) {
      var previous = -1;
      for (final time in times) {
        if (time < 0 ||
            (profile.durationMs != null && time > profile.durationMs!) ||
            time <= previous) {
          return false;
        }
        previous = time;
      }
      return true;
    }
    if (!validTimes(beat.beatMs) || !validTimes(beat.downbeatMs)) {
      return false;
    }
    final firstBeat = beat.firstBeatMs;
    if (firstBeat != null &&
        (firstBeat < 0 ||
            (profile.durationMs != null && firstBeat > profile.durationMs!))) {
      return false;
    }
    for (final point in profile.energyCurve) {
      if (point.timeMs < 0 ||
          (profile.durationMs != null && point.timeMs > profile.durationMs!) ||
          !unit(point.value) ||
          !unit(point.loudness) ||
          !unit(point.bass) ||
          !unit(point.mids) ||
          !unit(point.highs) ||
          !point.slope.isFinite) {
        return false;
      }
    }
    return true;
  }


  /// Prefer a beat/phrase boundary during the crossfade instead of a fixed 35%.
  static int _phraseSnappedSfxMs({
    required int durationMs,
    required DjTransitionKind kind,
    required DjTrackProfile outgoing,
    required int outgoingStartMs,
  }) {
    final dur = durationMs.clamp(500, 20000);
    final fraction = switch (kind) {
      DjTransitionKind.safeCrossfade => 0.22,
      DjTransitionKind.energyBridge => 0.28,
      DjTransitionKind.outroIntro => 0.30,
      DjTransitionKind.phraseBlend => 0.40,
      DjTransitionKind.beatBlend => 0.38,
      DjTransitionKind.breakdownDrop => 0.52,
    };
    final ideal = (dur * fraction).round().clamp(180, dur - 120);

    final beats = outgoing.beatGrid.beatMs;
    if (beats.length < 4) return ideal;

    final windowStart = outgoingStartMs;
    final windowEnd = outgoingStartMs + dur;

    var bestRel = ideal;
    var bestDist = 1 << 30;
    for (final b in beats) {
      if (b < windowStart + 120 || b > windowEnd - 80) continue;
      final rel = b - windowStart;
      final d = (rel - ideal).abs();
      if (d < bestDist) {
        bestDist = d;
        bestRel = rel;
      }
    }

    final downs = outgoing.beatGrid.downbeatMs;
    for (final b in downs) {
      if (b < windowStart + 120 || b > windowEnd - 80) continue;
      final rel = b - windowStart;
      final d = (rel - ideal).abs();
      if (d < bestDist || (d <= bestDist + 180 && d <= 200)) {
        bestDist = d;
        bestRel = rel;
      }
    }

    return bestRel.clamp(150, dur - 100);
  }
}
