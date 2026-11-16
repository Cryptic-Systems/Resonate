import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/models/dj_analysis.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/services/dj_auto_select_service.dart';

Song _song(String id, {String artist = 'Artist', String album = 'Album'}) {
  return Song(
    id: id,
    title: 'Track $id',
    artist: artist,
    album: album,
    filePath: '/music/$id.mp3',
    duration: const Duration(minutes: 3),
    dateAdded: DateTime(2025),
  );
}

DjAnalysis _analysis(
  String id, {
  double bpm = 120,
  int key = 0,
  String mode = 'minor',
  double energy = 0.55,
}) {
  return DjAnalysis(
    songId: id,
    bpm: bpm,
    bpmConfidence: 0.92,
    keyRoot: key,
    keyMode: mode,
    energy: energy,
  );
}

void main() {
  group('DjAutoSelectService', () {
    test('arranges a sufficiently analyzed scope and retains every track', () {
      final songs = [
        _song('a', artist: 'One'),
        _song('b', artist: 'Two'),
        _song('c', artist: 'Three'),
        _song('d', artist: 'Four'),
      ];
      final analyses = {
        'a': _analysis('a', bpm: 120, key: 0, energy: 0.45),
        'b': _analysis('b', bpm: 122, key: 7, energy: 0.50),
        'c': _analysis('c', bpm: 90, key: 2, energy: 0.72),
        'd': _analysis('d', bpm: 121, key: 0, energy: 0.52),
      };

      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        analyses,
        random: math.Random(7),
      );

      expect(result.usedDjArrangement, isTrue);
      expect(result.analysisCoverage, 1);
      expect(result.songs.map((song) => song.id).toSet(),
          songs.map((song) => song.id).toSet());
      expect(result.songs, hasLength(songs.length));
    });

    test('falls back to ordinary shuffle when analysis coverage is low', () {
      final songs = [_song('a'), _song('b'), _song('c'), _song('d')];
      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        {'a': _analysis('a')},
        random: math.Random(11),
      );

      expect(result.usedDjArrangement, isFalse);
      expect(result.reason, 'insufficient_analysis_confidence');
      expect(result.analysisCoverage, 0.25);
      expect(result.songs.map((song) => song.id).toSet(),
          songs.map((song) => song.id).toSet());
    });

    test('stale analysis does not count toward DJ confidence', () {
      final songs = [_song('a'), _song('b'), _song('c')];
      final stale = DjAnalysis(
        songId: 'a',
        bpm: 120,
        bpmConfidence: 0.95,
        analysisVersion: DjAnalysis.currentVersion - 1,
      );
      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        {
          'a': stale,
          'b': _analysis('b'),
          'c': _analysis('c'),
        },
        random: math.Random(3),
      );

      expect(result.usedDjArrangement, isFalse);
      expect(result.analysisCoverage, closeTo(2 / 3, 0.0001));
    });

    test('single-track scopes do not invoke a musical reorder', () {
      final song = _song('only');
      final result = DjAutoSelectService().arrangeWithAnalysis(
        [song],
        {'only': _analysis('only')},
      );

      expect(result.usedDjArrangement, isFalse);
      expect(result.songs.single.id, 'only');
      expect(result.reason, 'not_enough_tracks');
    });
  });
}
