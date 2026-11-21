import 'song.dart';

enum QueuePlanStatus { ready, partial, insufficientAnalysis, noEligibleTracks }

/// Explainable result from the shared DJ-aware queue planner.
class QueuePlan {
  const QueuePlan({
    required this.intentId, required this.songs, required this.status,
    required this.analysisCoverage, required this.analyzedTrackCount,
    required this.eligibleTrackCount, this.excludedSongIds = const [],
    this.reason,
  });
  final String intentId;
  final List<Song> songs;
  final QueuePlanStatus status;
  final double analysisCoverage;
  final int analyzedTrackCount, eligibleTrackCount;
  final List<String> excludedSongIds;
  final String? reason;
  bool get isUsable => songs.isNotEmpty;
  bool get isComplete => status == QueuePlanStatus.ready;
}
