import '../models/queue_intent.dart';
import '../models/queue_plan.dart';
import '../models/song.dart';
import '../modes/models/media_type.dart';
import '../modes/models/mode_media_item.dart';
import '../modes/providers/mode_provider.dart';
import 'intelligent_queue_planner.dart';

class ModeQueuePlanResult {
  const ModeQueuePlanResult({
    required this.songs,
    required this.usedDjPlanner,
    this.plan,
    this.message,
  });

  final List<Song> songs;
  final bool usedDjPlanner;
  final QueuePlan? plan;
  final String? message;
  bool get isUsable => songs.isNotEmpty;
}

/// Applies the active music mode's DJ constraints to mode-owned queues.
/// Mixed-media modes deliberately retain their existing content policy.
class ModeAwareQueuePlanner {
  ModeAwareQueuePlanner({IntelligentQueuePlanner? planner})
      : _planner = planner ?? IntelligentQueuePlanner();

  final IntelligentQueuePlanner _planner;

  Future<ModeQueuePlanResult> arrange({
    required ModeProvider modes,
    required List<Song> tracks,
    String? requiredSongId,
  }) async {
    final intent = QueueIntent.forMode(modes.mode);
    if (intent == null) {
      return ModeQueuePlanResult(
        songs: List.unmodifiable(tracks),
        usedDjPlanner: false,
      );
    }

    final musicTracks = tracks.where((song) {
      final item = ModeMediaItem(
        id: song.id,
        filePath: song.filePath,
        title: song.title,
        album: song.album,
        artist: song.artist,
      );
      return modes.mediaTypeFor(item) == MediaType.music;
    }).toList(growable: false);

    if (musicTracks.isEmpty) {
      return const ModeQueuePlanResult(
        songs: [],
        usedDjPlanner: true,
        message: 'This mode needs music tracks, but the current shelf has none classified as music.',
      );
    }

    final plan = await _planner.plan(musicTracks, intent: intent);
    if (!plan.isUsable) {
      return ModeQueuePlanResult(
        songs: const [],
        usedDjPlanner: true,
        plan: plan,
        message: plan.reason ?? 'DJ analysis has not produced a usable queue yet.',
      );
    }

    if (requiredSongId != null &&
        !plan.songs.any((song) => song.id == requiredSongId)) {
      return ModeQueuePlanResult(
        songs: const [],
        usedDjPlanner: true,
        plan: plan,
        message: 'That track does not meet the active ${intent.label} tempo and energy profile.',
      );
    }

    final message = plan.status == QueuePlanStatus.partial
        ? 'DJ arranged ${plan.eligibleTrackCount} of ${musicTracks.length} tracks for ${intent.label}; the remaining tracks lacked suitable analysis or fell outside the profile.'
        : 'DJ arranged this queue for ${intent.label}.';
    return ModeQueuePlanResult(
      songs: plan.songs,
      usedDjPlanner: true,
      plan: plan,
      message: message,
    );
  }
}
