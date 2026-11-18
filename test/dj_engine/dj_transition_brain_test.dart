import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/dj_engine.dart';
import 'package:resonate/dj_engine/core/dj_policy.dart';

void main() {
  const engine = DjEngine();

  DjTrackProfile track({
    required String id,
    double bpm = 128,
    int key = 0,
    double energy = 0.7,
    DjSectionType section = DjSectionType.outro,
    List<DjSilenceRegion> silenceRegions = const [],
    List<DjEnergyPoint>? energyCurve,
  }) {
    return DjTrackProfile(
      songId: id,
      durationMs: 240000,
      beatGrid: DjBeatGrid(
        bpm: bpm,
        confidence: 0.95,
        firstBeatMs: 0,
        beatMs: const [0, 469, 938, 1406, 1875, 2344, 2813, 3281],
      ),
      keyRoot: key,
      keyMode: 'minor',
      keyConfidence: 0.9,
      sections: [
        DjSection(type: section, startMs: 220000, endMs: 240000, confidence: 0.9, energy: energy),
      ],
      energyCurve: energyCurve ?? [
        DjEnergyPoint(timeMs: 220000, value: energy),
      ],
      spectrum: const DjSpectralProfile(bassDensity: 0.65, centroid: 0.5, spectralFlux: 0.5, confidence: 0.9),
      transitions: const DjTransitionMarkers(bestIntroMs: 0, bestOutroMs: 220000),
      silenceRegions: silenceRegions,
      analysisConfidence: 0.9,
    );
  }

  test('chooses a musical candidate instead of only safe crossfade', () {
    final plan = engine.planTransition(
      outgoing: track(id: 'a', energy: 0.65),
      incoming: track(id: 'b', energy: 0.66, section: DjSectionType.intro),
      outgoingPositionMs: 220000,
    );

    expect(plan.candidate.kind, isNot(DjTransitionKind.safeCrossfade));
    expect(plan.steps, isNotEmpty);
    expect(plan.fallback, isFalse);
  });

  test('harmonic mix enables harmonic compatibility scoring', () {
    final outgoing = track(id: 'a', key: 0);
    final incoming = track(id: 'b', key: 0);
    const neutralPolicy = DjPolicy(harmonicMix: false);
    const harmonicPolicy = DjPolicy(harmonicMix: true);

    final neutral = engine.brain.generate(
      outgoing: outgoing,
      incoming: incoming,
      outgoingPositionMs: 220000,
      policy: neutralPolicy,
    );
    final harmonic = engine.brain.generate(
      outgoing: outgoing,
      incoming: incoming,
      outgoingPositionMs: 220000,
      policy: harmonicPolicy,
    );

    final neutralSafe = neutral.firstWhere((c) => c.kind == DjTransitionKind.safeCrossfade);
    final harmonicSafe = harmonic.firstWhere((c) => c.kind == DjTransitionKind.safeCrossfade);

    expect(neutralSafe.scores['harmonic'], 0.5);
    expect(harmonicSafe.scores['harmonic'], 1.0);
    expect(harmonicSafe.score, greaterThan(neutralSafe.score));
  });

  test('plans repeat-one from a safe outro cue into the same track intro', () {
    final self = track(id: 'repeat-self', section: DjSectionType.outro);
    final candidates = engine.brain.generate(
      outgoing: self,
      incoming: self,
      outgoingPositionMs: 200000,
      preferredDurationMs: 6500,
      maxDurationMs: 12000,
    );

    expect(candidates, isNotEmpty);
    expect(candidates.first.outgoingStartMs, 220000);
    expect(candidates.first.incomingStartMs, 0);
    expect(candidates.first.durationMs, greaterThanOrEqualTo(2000));
  });

  test('honours manually saved Mix-Out and Mix-In cue markers', () {
    final outgoing = track(id: 'manual-out');
    final incoming = track(id: 'manual-in');
    final editedOutgoing = DjTrackProfile(
      songId: outgoing.songId,
      durationMs: outgoing.durationMs,
      beatGrid: outgoing.beatGrid,
      keyRoot: outgoing.keyRoot,
      keyMode: outgoing.keyMode,
      keyConfidence: outgoing.keyConfidence,
      sections: outgoing.sections,
      energyCurve: outgoing.energyCurve,
      spectrum: outgoing.spectrum,
      transitions: const DjTransitionMarkers(
        bestOutroMs: 190000,
        safeMixOuts: [DjTimePoint(190000, confidence: 1)],
      ),
      analysisConfidence: outgoing.analysisConfidence,
    );
    final editedIncoming = DjTrackProfile(
      songId: incoming.songId,
      durationMs: incoming.durationMs,
      beatGrid: incoming.beatGrid,
      keyRoot: incoming.keyRoot,
      keyMode: incoming.keyMode,
      keyConfidence: incoming.keyConfidence,
      sections: incoming.sections,
      energyCurve: incoming.energyCurve,
      spectrum: incoming.spectrum,
      transitions: const DjTransitionMarkers(
        bestIntroMs: 10000,
        safeMixIns: [DjTimePoint(10000, confidence: 1)],
      ),
      analysisConfidence: incoming.analysisConfidence,
    );

    final candidates = engine.brain.generate(
      outgoing: editedOutgoing,
      incoming: editedIncoming,
      outgoingPositionMs: 0,
      preferredDurationMs: 6500,
      maxDurationMs: 15000,
    );
    final safe = candidates.firstWhere(
      (candidate) => candidate.kind == DjTransitionKind.safeCrossfade,
    );
    expect(safe.outgoingStartMs, 190000);
    expect(safe.incomingStartMs, 10000);
  });

  test('keeps a usable fallback when analysis is absent', () {
    const unknown = DjTrackProfile(songId: 'unknown');
    final plan = engine.planTransition(
      outgoing: unknown,
      incoming: unknown,
      outgoingPositionMs: 0,
    );

    expect(plan.candidate.kind, DjTransitionKind.safeCrossfade);
    expect(plan.steps, isNotEmpty);
  });
  test('prefers beat-aligned incoming anchors', () {
    final incoming = track(id: 'b', section: DjSectionType.intro);
    final plan = engine.planTransition(
      outgoing: track(id: 'a'),
      incoming: incoming,
      outgoingPositionMs: 220000,
    );
    expect(const <int>[0, 469, 938, 1406, 1875, 2344, 2813, 3281].contains(plan.candidate.incomingStartMs), isTrue);
  });

  test('rewards a high-confidence near-end PCM silence anchor', () {
    final incoming = track(id: 'b', section: DjSectionType.intro);
    final withoutSilence = engine.brain.generate(
      outgoing: track(id: 'a'),
      incoming: incoming,
      outgoingPositionMs: 220000,
    ).firstWhere((candidate) => candidate.kind == DjTransitionKind.safeCrossfade);
    final withSilence = engine.brain.generate(
      outgoing: track(
        id: 'a',
        silenceRegions: const [
          DjSilenceRegion(
            startMs: 218000,
            endMs: 232000,
            minimumDbfs: -58,
            confidence: 0.92,
          ),
        ],
      ),
      incoming: incoming,
      outgoingPositionMs: 220000,
    ).firstWhere((candidate) => candidate.kind == DjTransitionKind.safeCrossfade);

    expect(withSilence.scores['silence'], greaterThan(0.9));
    expect(withSilence.score, greaterThan(withoutSilence.score));
  });

  test('ignores weak silence and quiet mid-track breakdown evidence', () {
    final incoming = track(id: 'b', section: DjSectionType.intro);
    final weak = track(
      id: 'weak',
      silenceRegions: const [
        DjSilenceRegion(
          startMs: 218000,
          endMs: 232000,
          minimumDbfs: -58,
          confidence: 0.62,
        ),
      ],
    );
    final breakdown = track(
      id: 'breakdown',
      silenceRegions: const [
        DjSilenceRegion(
          startMs: 120000,
          endMs: 132000,
          minimumDbfs: -58,
          confidence: 0.96,
        ),
      ],
    );
    for (final outgoing in [weak, breakdown]) {
      final candidate = engine.brain.generate(
        outgoing: outgoing,
        incoming: incoming,
        outgoingPositionMs: 220000,
      ).firstWhere((value) => value.kind == DjTransitionKind.safeCrossfade);
      expect(candidate.scores['silence'], 0.5);
    }
  });

  test('evaluates outgoing risks at the selected transition anchor', () {
    final outgoing = track(
      id: 'a',
      energy: 0.8,
      energyCurve: const [
        DjEnergyPoint(timeMs: 200000, value: 0.1),
        DjEnergyPoint(timeMs: 220000, value: 0.8),
      ],
    );
    final incoming = track(
      id: 'b',
      energy: 0.8,
      section: DjSectionType.intro,
    );

    final candidate = engine.brain.generate(
      outgoing: outgoing,
      incoming: incoming,
      outgoingPositionMs: 200000,
    ).firstWhere((value) => value.kind == DjTransitionKind.safeCrossfade);

    expect(candidate.outgoingStartMs, 220000);
    expect(candidate.scores['energy'], greaterThanOrEqualTo(0.9));
    expect(candidate.risks, isNot(contains(DjRiskType.energyShock)));
  });

  test('caps blend duration to both decks remaining playable material', () {
    final shortOutgoing = DjTrackProfile(
      songId: 'out',
      durationMs: 225000,
      beatGrid: const DjBeatGrid(bpm: 128, confidence: 0.95),
      transitions: const DjTransitionMarkers(bestOutroMs: 220000),
      analysisConfidence: 0.9,
    );
    final shortIncoming = DjTrackProfile(
      songId: 'in',
      durationMs: 4000,
      beatGrid: const DjBeatGrid(bpm: 128, confidence: 0.95),
      analysisConfidence: 0.9,
    );
    final candidates = engine.brain.generate(
      outgoing: shortOutgoing,
      incoming: shortIncoming,
      outgoingPositionMs: 200000,
      preferredDurationMs: 12000,
      maxDurationMs: 16000,
    );

    expect(candidates, isNotEmpty);
    expect(candidates.every((candidate) =>
        candidate.outgoingStartMs == 220000 &&
        candidate.durationMs >= 2000 &&
        candidate.durationMs <= 4000), isTrue);
  });

  test('does not create a blend when either deck has less than two seconds left', () {
    final outgoing = DjTrackProfile(
      songId: 'out',
      durationMs: 221000,
      beatGrid: const DjBeatGrid(bpm: 128, confidence: 0.95),
      transitions: const DjTransitionMarkers(bestOutroMs: 220000),
      analysisConfidence: 0.9,
    );
    final incoming = track(id: 'in', section: DjSectionType.intro);
    final candidates = engine.brain.generate(
      outgoing: outgoing,
      incoming: incoming,
      outgoingPositionMs: 200000,
    );

    expect(candidates, isEmpty);
  });

  test('uses energy slope when ranking candidates', () {
    final outgoing = track(id: 'a', energy: 0.7);
    final incoming = DjTrackProfile(
      songId: 'b',
      durationMs: 240000,
      beatGrid: const DjBeatGrid(
        bpm: 128,
        confidence: 0.95,
        firstBeatMs: 0,
        beatMs: [0, 469, 938, 1406, 1875, 2344, 2813, 3281],
        downbeatMs: [0, 1875],
        downbeatConfidence: 0.85,
        barConfidence: 0.85,
        phraseConfidence: 0.8,
      ),
      keyRoot: 0,
      keyMode: 'minor',
      keyConfidence: 0.9,
      sections: const [DjSection(type: DjSectionType.intro, startMs: 0, endMs: 20000, confidence: 0.9)],
      energyCurve: const [
        DjEnergyPoint(timeMs: 0, value: 0.5, slope: 0.5),
        DjEnergyPoint(timeMs: 10000, value: 0.7, slope: 0.5),
      ],
      spectrum: const DjSpectralProfile(bassDensity: 0.65, centroid: 0.5, spectralFlux: 0.5, confidence: 0.9),
      transitions: const DjTransitionMarkers(bestIntroMs: 0, bestOutroMs: 220000),
      analysisConfidence: 0.9,
    );
    final plan = engine.planTransition(
      outgoing: outgoing,
      incoming: incoming,
      outgoingPositionMs: 220000,
    );
    expect(plan.candidate.score, greaterThan(0.0));
  });


  test('keeps fallback non-executable for a negative outgoing position', () {
    const unknown = DjTrackProfile(songId: 'unknown');
    final plan = engine.planTransition(
      outgoing: unknown,
      incoming: unknown,
      outgoingPositionMs: -1,
    );

    expect(plan.fallback, isTrue);
    expect(plan.reason, 'insufficient_playable_duration');
    expect(plan.candidate.durationMs, 0);
    expect(plan.steps, isEmpty);
  });

  test('normalizes a requested maximum below the minimum blend duration', () {
    final candidates = engine.brain.generate(
      outgoing: track(id: 'out'),
      incoming: track(id: 'in', section: DjSectionType.intro),
      outgoingPositionMs: 220000,
      preferredDurationMs: 8000,
      maxDurationMs: 1000,
    );

    expect(candidates, isNotEmpty);
    expect(candidates.every((candidate) => candidate.durationMs == 2000), isTrue);
  });

}
