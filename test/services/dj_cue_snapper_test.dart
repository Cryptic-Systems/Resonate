import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/services/dj_cue_snapper.dart';

void main() {
  group('DjCueSnapper', () {
    const profile = DjTrackProfile(
      songId: 'track', durationMs: 120000,
      beatGrid: DjBeatGrid(bpm: 120, confidence: 0.9, beatMs: [0, 500, 1000, 1500, 2000, 2500, 3000],
        downbeatMs: [0, 2000], downbeatConfidence: 0.9, phraseConfidence: 0.8, beatsPerPhrase: 4),
      transitions: DjTransitionMarkers(
        safeMixIns: [DjTimePoint(3100, confidence: 0.9)],
        safeMixOuts: [DjTimePoint(1900, confidence: 0.9)],
      ),
      sections: [DjSection(type: DjSectionType.drop, startMs: 4000, endMs: 8000, confidence: 0.9)],
    );

    test('snaps a nearby cue to a trusted beat', () {
      expect(DjCueSnapper.snap(profile, 1040, 120000, outgoing: true), 1000);
    });
    test('uses direction-specific safe markers', () {
      expect(DjCueSnapper.snap(profile, 1980, 120000, outgoing: true), 1900);
      expect(DjCueSnapper.snap(profile, 3080, 120000, outgoing: false), 3100);
    });
    test('does not snap when the nearest marker is too far away', () {
      expect(DjCueSnapper.snap(profile, 12000, 120000, outgoing: true), 12000);
    });
    test('falls back to the requested cue when analysis is untrusted', () {
      const weak = DjTrackProfile(songId: 'weak', beatGrid: DjBeatGrid(bpm: 120, confidence: 0.2, beatMs: [1000]));
      expect(DjCueSnapper.snap(weak, 1040, 120000, outgoing: false), 1040);
    });
  });
}
