import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/dj_engine.dart';
import 'package:resonate/dj_engine/core/dj_policy.dart';

void main() {
  const planner = DjExecutionPlanner();

  const outgoing = DjTrackProfile(
    songId: 'out',
    durationMs: 240000,
    beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
    spectrum: DjSpectralProfile(bassDensity: 0.5),
    analysisConfidence: 0.92,
  );

  const incoming = DjTrackProfile(
    songId: 'in',
    durationMs: 220000,
    beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
    spectrum: DjSpectralProfile(bassDensity: 0.5),
    analysisConfidence: 0.92,
  );

  test('falls back when multiple severe risks conflict with a high score', () {
    const candidate = DjTransitionCandidate(
      kind: DjTransitionKind.phraseBlend,
      outgoingStartMs: 220000,
      incomingStartMs: 0,
      durationMs: 8000,
      score: 0.99,
      confidence: 0.96,
      risks: [
        DjRiskType.harmonicConflict,
        DjRiskType.energyShock,
      ],
    );

    final plan = planner.plan(
      outgoing: outgoing,
      incoming: incoming,
      candidate: candidate,
      policy: DjPolicy.balanced,
    );

    expect(plan.fallback, isTrue);
    expect(plan.reason, 'risk_too_high');
    expect(plan.steps, isEmpty);
  });

  test('does not force fallback for one contained musical conflict', () {
    const candidate = DjTransitionCandidate(
      kind: DjTransitionKind.phraseBlend,
      outgoingStartMs: 220000,
      incomingStartMs: 0,
      durationMs: 8000,
      score: 0.82,
      confidence: 0.88,
      risks: [DjRiskType.harmonicConflict],
    );

    final plan = planner.plan(
      outgoing: outgoing,
      incoming: incoming,
      candidate: candidate,
      policy: DjPolicy.balanced,
    );

    expect(plan.fallback, isFalse);
    expect(plan.steps, isNotEmpty);
  });

  test('safe policy applies stricter risk threshold than musical policy', () {
    const candidate = DjTransitionCandidate(
      kind: DjTransitionKind.phraseBlend,
      outgoingStartMs: 220000,
      incomingStartMs: 0,
      durationMs: 8000,
      score: 0.90,
      confidence: 0.92,
      risks: [DjRiskType.harmonicConflict],
    );

    final safe = planner.plan(
      outgoing: outgoing,
      incoming: incoming,
      candidate: candidate,
      policy: const DjPolicy(aggressiveness: DjAggressiveness.safe),
    );
    final musical = planner.plan(
      outgoing: outgoing,
      incoming: incoming,
      candidate: candidate,
      policy: const DjPolicy(aggressiveness: DjAggressiveness.musical),
    );

    expect(safe.fallback, isTrue);
    expect(musical.fallback, isFalse);
  });
}
