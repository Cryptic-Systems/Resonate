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

  test('rejects a fade that would run past the outgoing track end', () {
    const candidate = DjTransitionCandidate(
      kind: DjTransitionKind.phraseBlend,
      outgoingStartMs: 239000,
      incomingStartMs: 0,
      durationMs: 8000,
      score: 0.9,
      confidence: 0.92,
    );
    const almostFinishedOutgoing = DjTrackProfile(
      songId: 'out',
      durationMs: 240000,
      beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
      spectrum: DjSpectralProfile(bassDensity: 0.5),
      analysisConfidence: 0.92,
    );

    final plan = planner.plan(
      outgoing: almostFinishedOutgoing,
      incoming: incoming,
      candidate: candidate,
    );

    expect(plan.fallback, isTrue);
    expect(plan.reason, 'insufficient_playable_duration');
    expect(plan.steps, isEmpty);
  });

  test('rejects a fade that exceeds the incoming track remaining duration', () {
    const candidate = DjTransitionCandidate(
      kind: DjTransitionKind.beatBlend,
      outgoingStartMs: 220000,
      incomingStartMs: 1000,
      durationMs: 8000,
      score: 0.9,
      confidence: 0.92,
    );
    const shortIncoming = DjTrackProfile(
      songId: 'short-in',
      durationMs: 5000,
      beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
      spectrum: DjSpectralProfile(bassDensity: 0.5),
      analysisConfidence: 0.92,
    );

    final plan = planner.plan(
      outgoing: outgoing,
      incoming: shortIncoming,
      candidate: candidate,
    );

    expect(plan.fallback, isTrue);
    expect(plan.reason, 'insufficient_playable_duration');
    expect(plan.steps, isEmpty);
  });

  test('allows a fade that exactly fits both decks remaining material', () {
    const candidate = DjTransitionCandidate(
      kind: DjTransitionKind.safeCrossfade,
      outgoingStartMs: 220000,
      incomingStartMs: 0,
      durationMs: 2000,
      score: 0.8,
      confidence: 0.9,
    );
    const boundaryOutgoing = DjTrackProfile(
      songId: 'out-boundary',
      durationMs: 222000,
      beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
      spectrum: DjSpectralProfile(bassDensity: 0.5),
      analysisConfidence: 0.92,
    );
    const boundaryIncoming = DjTrackProfile(
      songId: 'in-boundary',
      durationMs: 2000,
      beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
      spectrum: DjSpectralProfile(bassDensity: 0.5),
      analysisConfidence: 0.92,
    );

    final plan = planner.plan(
      outgoing: boundaryOutgoing,
      incoming: boundaryIncoming,
      candidate: candidate,
    );

    expect(plan.fallback, isFalse);
    expect(plan.steps.last.atMs, 2000);
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
