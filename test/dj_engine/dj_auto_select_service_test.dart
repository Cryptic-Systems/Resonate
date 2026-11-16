import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/models/dj_analysis.dart';
import 'package:resonate/models/listening_event.dart';
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
  int? beatOffsetMs,
  int? introHintMs,
  int? outroHintMs,
  String? bpmSource,
}) {
  return DjAnalysis(
    songId: id,
    bpm: bpm,
    bpmConfidence: 0.92,
    bpmSource: bpmSource,
    beatOffsetMs: beatOffsetMs,
    introHintMs: introHintMs,
    outroHintMs: outroHintMs,
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

    test('listening history rewards completed plays and favorites', () {
      final now = DateTime(2026, 11, 16);
      final events = [
        ListeningEvent(
          id: 'complete-1',
          songId: 'liked',
          startedAt: now.subtract(const Duration(days: 2)),
          endedAt: now.subtract(const Duration(days: 2)),
          durationPlayedMs: 180000,
          songDurationMs: 180000,
          completionRatio: 1,
          completed: true,
          skipped: false,
        ),
        ListeningEvent(
          id: 'skip-1',
          songId: 'skipped',
          startedAt: now.subtract(const Duration(days: 1)),
          endedAt: now.subtract(const Duration(days: 1)),
          durationPlayedMs: 12000,
          songDurationMs: 180000,
          completionRatio: 0.07,
          completed: false,
          skipped: true,
          skipPositionMs: 12000,
        ),
      ];

      final signals = DjListeningSignal.fromHistory(
        events,
        favorites: {'liked'},
      );

      expect(signals['liked']!.preferenceScore, greaterThan(0));
      expect(signals['skipped']!.preferenceScore, lessThan(0));
      expect(signals['liked']!.favorite, isTrue);
    });

    test('favorite-only tracks receive a positive preference signal', () {
      final signals = DjListeningSignal.fromHistory(
        const [],
        favorites: {'favorite-track'},
      );

      expect(signals['favorite-track']!.preferenceScore, greaterThan(0));
    });

    test('energy progression opens gently, builds, and resolves after the peak', () {
      final songs = [
        _song('low', artist: 'One'),
        _song('warm', artist: 'Two'),
        _song('mid', artist: 'Three'),
        _song('drive', artist: 'Four'),
        _song('peak', artist: 'Five'),
        _song('peak-two', artist: 'Six'),
        _song('close', artist: 'Seven'),
      ];
      final analyses = {
        'low': _analysis('low', energy: 0.10),
        'warm': _analysis('warm', energy: 0.25),
        'mid': _analysis('mid', energy: 0.40),
        'drive': _analysis('drive', energy: 0.60),
        'peak': _analysis('peak', energy: 0.80),
        'peak-two': _analysis('peak-two', energy: 1.00),
        'close': _analysis('close', energy: 0.55),
      };

      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        analyses,
        random: math.Random(19),
      );
      final orderedEnergy = result.songs
          .map((song) => analyses[song.id]!.energy!)
          .toList();
      final peakIndex = orderedEnergy.indexOf(orderedEnergy.reduce(math.max));

      expect(result.usedDjArrangement, isTrue);
      expect(orderedEnergy.first, 0.10);
      expect(peakIndex, inInclusiveRange(3, 5));
      expect(orderedEnergy.last, lessThan(orderedEnergy[peakIndex]));
      expect(result.songs.map((song) => song.id).toSet(),
          songs.map((song) => song.id).toSet());
    });

    test('beat phase favors tracks with aligned PCM beat grids', () {
      final songs = [
        _song('opening', artist: 'One'),
        _song('aligned', artist: 'Two'),
        _song('offset', artist: 'Three'),
      ];
      final analyses = {
        'opening': _analysis(
          'opening',
          energy: 0.10,
          beatOffsetMs: 100,
          bpmSource: 'pcm_profile_v2',
        ),
        'aligned': _analysis(
          'aligned',
          energy: 0.50,
          beatOffsetMs: 110,
          bpmSource: 'pcm_profile_v2',
        ),
        'offset': _analysis(
          'offset',
          energy: 0.50,
          beatOffsetMs: 350,
          bpmSource: 'pcm_profile_v2',
        ),
      };

      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        analyses,
        random: math.Random(23),
      );

      expect(result.songs.first.id, 'opening');
      expect(result.songs[1].id, 'aligned');
    });

    test('beat phase ignores ID3-only default offsets', () {
      final songs = [
        _song('opening', artist: 'One'),
        _song('other', artist: 'Two'),
        _song('candidate', artist: 'Three'),
      ];
      final analyses = {
        'opening': _analysis('opening', energy: 0.10, beatOffsetMs: 0),
        'other': _analysis(
          'other',
          energy: 0.50,
          beatOffsetMs: 0,
          bpmSource: 'id3_tbpm',
        ),
        'candidate': _analysis(
          'candidate',
          energy: 0.50,
          beatOffsetMs: 250,
          bpmSource: 'id3_tbpm',
        ),
      };

      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        analyses,
        random: math.Random(29),
      );

      expect(result.songs.first.id, 'opening');
      expect(result.songs[1].id, isNotEmpty);
      expect(result.usedDjArrangement, isTrue);
    });

    test('compatible intro and outro hints modestly favor a longer blend window', () {
      final songs = [
        _song('outgoing', artist: 'One'),
        _song('with-intro', artist: 'Two'),
        _song('without-intro', artist: 'Three'),
      ];
      final analyses = {
        'outgoing': _analysis(
          'outgoing',
          energy: 0.10,
          outroHintMs: 12000,
        ),
        'with-intro': _analysis(
          'with-intro',
          energy: 0.50,
          introHintMs: 10000,
        ),
        'without-intro': _analysis(
          'without-intro',
          energy: 0.50,
        ),
      };

      final result = DjAutoSelectService().arrangeWithAnalysis(
        songs,
        analyses,
        random: math.Random(31),
      );

      expect(result.songs.first.id, 'outgoing');
      expect(result.songs[1].id, 'with-intro');
    });

    test('missing intro and outro hints remain neutral', () {
      final a = _analysis('a', energy: 0.10);
      final b = _analysis('b', energy: 0.50);
      final c = _analysis('c', energy: 0.50);
      expect(a.introHintMs, isNull);
      expect(b.outroHintMs, isNull);
      expect(DjAutoSelectService().arrangeWithAnalysis(
        [_song('a'), _song('b'), _song('c')],
        {'a': a, 'b': b, 'c': c},
        random: math.Random(37),
      ).usedDjArrangement, isTrue);
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
