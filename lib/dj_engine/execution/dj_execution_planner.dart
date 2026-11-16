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
    final effectiveDurationMs =
        requestedDuration.clamp(candidate.durationMs, durationLimit).toInt();
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

    return DjExecutionPlan(
      candidate: candidate,
      steps: steps,
      reason: 'planned',
    );
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
