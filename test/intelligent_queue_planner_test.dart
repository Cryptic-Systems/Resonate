import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/models/queue_intent.dart';
import 'package:resonate/models/queue_plan.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/modes/models/resonate_mode.dart';
import 'package:resonate/services/intelligent_queue_planner.dart';

Song _song(String id) => Song(
  id: id, title: 'Track $id', artist: 'Artist', album: 'Album',
  filePath: '/music/$id.mp3', duration: const Duration(minutes: 3),
  dateAdded: DateTime(2026),
);

DjTrackProfile _profile(String id, {required double bpm,
    required double energy, int key = 0, double confidence = 0.9,
    bool includeEnergy = true}) =>
  DjTrackProfile(
    songId: id, durationMs: 180000,
    beatGrid: DjBeatGrid(bpm: bpm, confidence: confidence,
      firstBeatMs: 120, beatMs: const [120, 620, 1120],
      downbeatMs: const [120], downbeatConfidence: confidence,
      barConfidence: confidence, phraseConfidence: confidence),
    keyRoot: key, keyMode: 'minor', keyConfidence: confidence,
    energyCurve: includeEnergy ? [
      DjEnergyPoint(timeMs: 0, value: energy),
      DjEnergyPoint(timeMs: 90000, value: energy),
      DjEnergyPoint(timeMs: 175000, value: energy),
    ] : const [],
    analysisConfidence: confidence, analysisVersion: 7,
  );

void main() {
  group('IntelligentQueuePlanner', () {
    final planner = IntelligentQueuePlanner();

    test('calmer mix selects low-energy tracks in its analyzed tempo range', () {
      final songs = [_song('calm'), _song('fast'), _song('loud')];
      final plan = planner.planWithProfiles(songs, intent: QueueIntent.calmerMix,
        profiles: {
          'calm': _profile('calm', bpm: 88, energy: 0.22),
          'fast': _profile('fast', bpm: 142, energy: 0.25),
          'loud': _profile('loud', bpm: 94, energy: 0.82),
        });
      expect(plan.status, QueuePlanStatus.partial);
      expect(plan.songs.map((song) => song.id), ['calm']);
      expect(plan.excludedSongIds, containsAll(['fast', 'loud']));
    });

    test('high energy modes use DJ beat-grid and energy constraints', () {
      final songs = [_song('workout'), _song('slow'), _song('soft')];
      final plan = planner.planWithProfiles(songs, intent: QueueIntent.highEnergy,
        profiles: {
          'workout': _profile('workout', bpm: 150, energy: 0.82),
          'slow': _profile('slow', bpm: 90, energy: 0.85),
          'soft': _profile('soft', bpm: 150, energy: 0.22),
        });
      expect(plan.songs.map((song) => song.id), ['workout']);
      expect(plan.status, QueuePlanStatus.partial);
    });

    test('missing analysis is explicit and never becomes ordinary shuffle', () {
      final plan = planner.planWithProfiles([_song('a'), _song('b')],
        intent: QueueIntent.workout, profiles: const {});
      expect(plan.songs, isEmpty);
      expect(plan.status, QueuePlanStatus.insufficientAnalysis);
      expect(plan.reason, contains('not replaced with ordinary shuffle'));
    });


    test('coverage requires every analysis signal demanded by the intent', () {
      final plan = planner.planWithProfiles([_song('bpm-only')],
        intent: QueueIntent.calmerMix,
        profiles: {
          'bpm-only': _profile('bpm-only', bpm: 88, energy: 0.2,
            includeEnergy: false),
        });
      expect(plan.songs, isEmpty);
      expect(plan.status, QueuePlanStatus.insufficientAnalysis);
      expect(plan.analysisCoverage, 0);
    });

    test('analyzed tracks outside the requested profile are rejected', () {
      final plan = planner.planWithProfiles([_song('slow'), _song('quiet')],
        intent: QueueIntent.workout, profiles: {
          'slow': _profile('slow', bpm: 90, energy: 0.80),
          'quiet': _profile('quiet', bpm: 145, energy: 0.20),
        });
      expect(plan.songs, isEmpty);
      expect(plan.status, QueuePlanStatus.noEligibleTracks);
    });


    test('keeps scanning when analyzed tracks fail but scope remains unanalyzed', () {
      final plan = planner.planWithProfiles(
        [_song('slow-a'), _song('slow-b'), _song('unknown')],
        intent: QueueIntent.workout,
        profiles: {
          'slow-a': _profile('slow-a', bpm: 90, energy: 0.8),
          'slow-b': _profile('slow-b', bpm: 95, energy: 0.75),
        },
      );
      expect(plan.songs, isEmpty);
      expect(plan.status, QueuePlanStatus.insufficientAnalysis);
      expect(plan.analysisCoverage, closeTo(2 / 3, 0.0001));
      expect(plan.reason, contains('still incomplete'));
    });

    test('rejects a profile for a different track identity', () {
      final plan = planner.planWithProfiles([_song('track-a')],
        intent: QueueIntent.calmerMix,
        profiles: {'track-a': _profile('other-id', bpm: 85, energy: 0.2)});
      expect(plan.songs, isEmpty);
      expect(plan.status, QueuePlanStatus.insufficientAnalysis);
    });

    test('maps music modes to shared queue intents', () {
      expect(QueueIntent.forMode(ResonateMode.workout), QueueIntent.workout);
      expect(QueueIntent.forMode(ResonateMode.running), QueueIntent.workout);
      expect(QueueIntent.forMode(ResonateMode.work), QueueIntent.focus);
      expect(QueueIntent.forMode(ResonateMode.running), QueueIntent.workout);
      expect(QueueIntent.forMode(ResonateMode.sleep), QueueIntent.sleep);
      expect(QueueIntent.forMode(ResonateMode.motivation), QueueIntent.motivation);
      expect(QueueIntent.forMode(ResonateMode.driving), QueueIntent.driving);
      expect(QueueIntent.forMode(ResonateMode.podcast), isNull);
      expect(QueueIntent.forMode(ResonateMode.audiobook), isNull);
    });

    test('sleep, focus, driving and motivation modes enforce their own DJ profiles', () {
      final cases = <(ResonateMode, double, double)>[
        (ResonateMode.sleep, 82, 0.20),
        (ResonateMode.work, 108, 0.38),
        (ResonateMode.driving, 112, 0.52),
        (ResonateMode.motivation, 132, 0.82),
      ];
      for (final (mode, bpm, energy) in cases) {
        final intent = QueueIntent.forMode(mode)!;
        final suitable = _song('${mode.name}-suitable');
        final unsuitable = _song('${mode.name}-unsuitable');
        final plan = planner.planWithProfiles(
          [suitable, unsuitable],
          intent: intent,
          profiles: {
            suitable.id: _profile(suitable.id, bpm: bpm, energy: energy),
            unsuitable.id: _profile(unsuitable.id, bpm: 176, energy: 0.96),
          },
        );
        expect(
          plan.songs.map((song) => song.id),
          [suitable.id],
          reason: '${mode.name} must use its own BPM/energy constraints',
        );
        expect(plan.excludedSongIds, contains(unsuitable.id));
        expect(plan.intentId, intent.id);
      }
    });

    test('mode queue intents always require beat-grid and energy evidence', () {
      for (final mode in [
        ResonateMode.sleep,
        ResonateMode.work,
        ResonateMode.driving,
        ResonateMode.motivation,
        ResonateMode.workout,
        ResonateMode.running,
      ]) {
        final intent = QueueIntent.forMode(mode)!;
        expect(intent.requireBeatGrid, isTrue, reason: mode.name);
        expect(intent.requireEnergy, isTrue, reason: mode.name);
      }
    });

  });
}
