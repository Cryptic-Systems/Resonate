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
    required double energy, int key = 0, double confidence = 0.9}) =>
  DjTrackProfile(
    songId: id, durationMs: 180000,
    beatGrid: DjBeatGrid(bpm: bpm, confidence: confidence,
      firstBeatMs: 120, beatMs: const [120, 620, 1120],
      downbeatMs: const [120], downbeatConfidence: confidence,
      barConfidence: confidence, phraseConfidence: confidence),
    keyRoot: key, keyMode: 'minor', keyConfidence: confidence,
    energyCurve: [
      DjEnergyPoint(timeMs: 0, value: energy),
      DjEnergyPoint(timeMs: 90000, value: energy),
      DjEnergyPoint(timeMs: 175000, value: energy),
    ],
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

    test('analyzed tracks outside the requested profile are rejected', () {
      final plan = planner.planWithProfiles([_song('slow'), _song('quiet')],
        intent: QueueIntent.workout, profiles: {
          'slow': _profile('slow', bpm: 90, energy: 0.80),
          'quiet': _profile('quiet', bpm: 145, energy: 0.20),
        });
      expect(plan.songs, isEmpty);
      expect(plan.status, QueuePlanStatus.noEligibleTracks);
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
      expect(QueueIntent.forMode(ResonateMode.sleep), isNull);
      expect(QueueIntent.forMode(ResonateMode.motivation), isNull);
      expect(QueueIntent.forMode(ResonateMode.driving), isNull);
      expect(QueueIntent.forMode(ResonateMode.podcast), isNull);
      expect(QueueIntent.forMode(ResonateMode.audiobook), isNull);
    });
  });
}
