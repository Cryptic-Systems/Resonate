import 'dart:math' as math;

import '../dj_engine/core/dj_types.dart';
import '../models/dj_analysis.dart';
import '../models/queue_intent.dart';
import '../models/queue_plan.dart';
import '../models/song.dart';
import 'dj_analysis_service.dart';

/// Shared mode-aware queue planner. It consumes persisted DJ beat-grid,
/// energy-curve and harmonic analysis, but never owns playback. A constrained
/// intent is never silently replaced with ordinary/random shuffle.
class IntelligentQueuePlanner {
  static final DjAnalysisService _sharedAnalysis = DjAnalysisService();
  static const int _maxConcurrentAnalysisWarmupsPerPlan = 6;

  IntelligentQueuePlanner({DjAnalysisService? analysis})
      : _analysis = analysis ?? _sharedAnalysis;
  final DjAnalysisService _analysis;

  Future<QueuePlan> plan(List<Song> scope, {required QueueIntent intent}) async {
    final profiles = <String, DjTrackProfile>{};
    var scheduledWarmups = 0;
    for (final song in scope) {
      final profile = await _analysis.getProfile(song.id);
      if (profile != null) {
        profiles[song.id] = profile;
      } else if (scheduledWarmups < _maxConcurrentAnalysisWarmupsPerPlan) {
        // Warm only a small batch: a large library mix must not launch dozens
        // of concurrent PCM decodes and drain battery or contend with playback.
        _analysis.scheduleAnalyze(song);
        scheduledWarmups++;
      }
    }
    return planWithProfiles(scope, intent: intent, profiles: profiles);
  }

  /// Pure ordering core for deterministic tests and already-loaded snapshots.
  QueuePlan planWithProfiles(
    List<Song> scope, {
    required QueueIntent intent,
    required Map<String, DjTrackProfile> profiles,
  }) {
    final unique = <String, Song>{};
    for (final song in scope) {
      unique.putIfAbsent(song.id, () => song);
    }
    final songs = unique.values.toList(growable: false);
    if (songs.isEmpty) {
      return QueuePlan(intentId: intent.id, songs: const [],
        status: QueuePlanStatus.noEligibleTracks, analysisCoverage: 0,
        analyzedTrackCount: 0, eligibleTrackCount: 0,
        reason: 'The selected scope contains no tracks.');
    }

    final candidates = <_Candidate>[];
    final excluded = <String>[];
    var analyzedCount = 0;
    for (var index = 0; index < songs.length; index++) {
      final song = songs[index];
      final profile = profiles[song.id];
      if (profile == null || !_profileMatchesSong(profile, song) ||
          profile.analysisConfidence < intent.minAnalysisConfidence ||
          profile.analysisVersion < DjAnalysis.currentVersion) {
        excluded.add(song.id);
        continue;
      }
      final bpm = profile.hasTempo ? profile.beatGrid.bpm : null;
      final energy = _averageEnergy(profile);
      final hasKey = profile.hasKey && profile.keyConfidence >= 0.35;
      final hasRequiredAnalysis =
          (!intent.requireBeatGrid || bpm != null) &&
          (!intent.requireEnergy || energy != null);
      if (hasRequiredAnalysis && (bpm != null || energy != null || hasKey)) {
        analyzedCount++;
      }

      if (intent.requireBeatGrid &&
          (bpm == null || (intent.minBpm != null && bpm < intent.minBpm!) ||
           (intent.maxBpm != null && bpm > intent.maxBpm!))) {
        excluded.add(song.id);
        continue;
      }
      if (intent.requireEnergy &&
          (energy == null || (intent.minEnergy != null && energy < intent.minEnergy!) ||
           (intent.maxEnergy != null && energy > intent.maxEnergy!))) {
        excluded.add(song.id);
        continue;
      }
      candidates.add(_Candidate(song, profile, bpm, energy, index));
    }

    final coverage = analyzedCount / songs.length;
    if (candidates.isEmpty) {
      final insufficient = analyzedCount < songs.length;
      return QueuePlan(
        intentId: intent.id, songs: const [],
        status: insufficient ? QueuePlanStatus.insufficientAnalysis
            : QueuePlanStatus.noEligibleTracks,
        analysisCoverage: coverage, analyzedTrackCount: analyzedCount,
        eligibleTrackCount: 0, excludedSongIds: List.unmodifiable(excluded),
        reason: insufficient
            ? 'DJ analysis is still incomplete for this scope. This request was not replaced with ordinary shuffle.'
            : 'No analyzed tracks meet this mix profile.',
      );
    }

    final ordered = <_Candidate>[];
    final remaining = List<_Candidate>.of(candidates);
    while (remaining.isNotEmpty) {
      _Candidate? best;
      var bestScore = double.negativeInfinity;
      for (final candidate in remaining) {
        final fit = _intentFit(candidate, intent);
        final continuity = ordered.isEmpty ? 0.5
            : _transitionFit(ordered.last.profile, candidate.profile);
        final score = fit * 0.78 + continuity * 0.20 -
            candidate.originalIndex * 0.000001;
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      ordered.add(best!);
      remaining.remove(best);
    }

    final complete = candidates.length == songs.length;
    return QueuePlan(
      intentId: intent.id,
      songs: List.unmodifiable(ordered.map((candidate) => candidate.song)),
      status: complete ? QueuePlanStatus.ready : QueuePlanStatus.partial,
      analysisCoverage: coverage, analyzedTrackCount: analyzedCount,
      eligibleTrackCount: candidates.length,
      excludedSongIds: List.unmodifiable(excluded),
      reason: complete ? null
          : 'Some tracks were excluded because DJ analysis was missing, stale, or outside this mix profile.',
    );
  }

  static bool _profileMatchesSong(DjTrackProfile profile, Song song) {
    if (profile.songId != song.id) return false;
    final duration = song.duration.inMilliseconds;
    return profile.durationMs == null || duration <= 0 ||
        (profile.durationMs! - duration).abs() <= 1500;
  }

  static double? _averageEnergy(DjTrackProfile profile) {
    final values = profile.energyCurve.map((point) => point.value)
        .where((value) => value.isFinite && value >= 0 && value <= 1)
        .toList(growable: false);
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _intentFit(_Candidate candidate, QueueIntent intent) {
    var weighted = 0.0;
    var weight = 0.0;
    if (candidate.energy != null) {
      weighted += (1 - (candidate.energy! - intent.targetEnergy).abs()
          .clamp(0.0, 1.0)) * 0.65;
      weight += 0.65;
    }
    if (candidate.bpm != null && intent.minBpm != null && intent.maxBpm != null) {
      final center = (intent.minBpm! + intent.maxBpm!) / 2;
      final halfRange = math.max(1.0, (intent.maxBpm! - intent.minBpm!) / 2);
      weighted += (1 - ((candidate.bpm! - center).abs() / halfRange)
          .clamp(0.0, 1.0)) * 0.35;
      weight += 0.35;
    }
    return weight == 0 ? 0.5 : weighted / weight;
  }

  static double _transitionFit(DjTrackProfile a, DjTrackProfile b) {
    var total = 0.0;
    var weight = 0.0;
    if (a.hasTempo && b.hasTempo) {
      final ratio = b.beatGrid.bpm! / a.beatGrid.bpm!;
      final delta = math.min((ratio - 1).abs(),
          math.min((ratio * 2 - 1).abs(), (ratio / 2 - 1).abs()));
      total += (1 - delta / 0.18).clamp(0.0, 1.0) * 0.55;
      weight += 0.55;
    }
    if (a.hasKey && b.hasKey && a.keyConfidence >= 0.35 &&
        b.keyConfidence >= 0.35) {
      final semitones = (a.keyRoot! - b.keyRoot!).abs();
      final distance = math.min(semitones, 12 - semitones);
      final compatible = distance == 0 || distance == 5 || distance == 7;
      total += ((compatible ? 1.0 : 0.35) +
          (a.keyMode == b.keyMode ? 0.15 : 0.0)).clamp(0.0, 1.0) * 0.25;
      weight += 0.25;
    }
    final energyA = _averageEnergy(a), energyB = _averageEnergy(b);
    if (energyA != null && energyB != null) {
      total += (1 - (energyA - energyB).abs()).clamp(0.0, 1.0) * 0.20;
      weight += 0.20;
    }
    return weight == 0 ? 0.5 : total / weight;
  }
}

class _Candidate {
  const _Candidate(this.song, this.profile, this.bpm, this.energy,
      this.originalIndex);
  final Song song;
  final DjTrackProfile profile;
  final double? bpm, energy;
  final int originalIndex;
}
