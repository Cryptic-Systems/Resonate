import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/dj_engine.dart';

void main() {
  const riskEngine = DjRiskEngine();

  DjTrackProfile profile({
    List<DjSilenceRegion> silenceRegions = const [],
  }) {
    return DjTrackProfile(
      songId: 'outgoing',
      durationMs: 240000,
      beatGrid: const DjBeatGrid(bpm: 128, confidence: 0.92),
      spectrum: const DjSpectralProfile(
        bassDensity: 0.5,
        centroid: 0.5,
        spectralFlux: 0.5,
      ),
      silenceRegions: silenceRegions,
      analysisConfidence: 0.92,
    );
  }

  const incoming = DjTrackProfile(
    songId: 'incoming',
    durationMs: 220000,
    beatGrid: DjBeatGrid(bpm: 128, confidence: 0.92),
    spectrum: DjSpectralProfile(
      bassDensity: 0.5,
      centroid: 0.5,
      spectralFlux: 0.5,
    ),
    analysisConfidence: 0.92,
  );

  const silenceScoredCandidate = DjTransitionCandidate(
    kind: DjTransitionKind.safeCrossfade,
    outgoingStartMs: 220000,
    incomingStartMs: 0,
    durationMs: 8000,
    score: 0.82,
    confidence: 0.92,
    scores: {'silence': 0.94},
  );

  test('rejects a silence score without matching measured evidence', () {
    final risks = riskEngine.evaluate(
      outgoing: profile(),
      incoming: incoming,
      candidate: silenceScoredCandidate,
    );

    expect(risks, contains(DjRiskType.silenceEvidenceMismatch));
  });

  test('accepts a silence score only with trusted late-track evidence nearby', () {
    final risks = riskEngine.evaluate(
      outgoing: profile(
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
      candidate: silenceScoredCandidate,
    );

    expect(risks, isNot(contains(DjRiskType.silenceEvidenceMismatch)));
  });

  test('does not flag a quiet mid-track passage as valid silence evidence', () {
    final risks = riskEngine.evaluate(
      outgoing: profile(
        silenceRegions: const [
          DjSilenceRegion(
            startMs: 118000,
            endMs: 132000,
            minimumDbfs: -60,
            confidence: 0.98,
          ),
        ],
      ),
      incoming: incoming,
      candidate: silenceScoredCandidate,
    );

    expect(risks, contains(DjRiskType.silenceEvidenceMismatch));
  });
}
