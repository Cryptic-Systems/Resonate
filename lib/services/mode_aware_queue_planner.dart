import '../models/queue_intent.dart';
import '../models/queue_plan.dart';
import '../models/song.dart';
import '../modes/models/media_type.dart';
import '../modes/models/mode_media_item.dart';
import '../modes/models/resonate_mode.dart';
import '../modes/providers/mode_provider.dart';
import 'intelligent_queue_planner.dart';

class ModeQueuePlanResult {
  const ModeQueuePlanResult({required this.songs, required this.usedDjPlanner, this.plan, this.message});
  final List<Song> songs;
  final bool usedDjPlanner;
  final QueuePlan? plan;
  final String? message;
  bool get isUsable => songs.isNotEmpty;
}

/// DJ ordering integrated with mode content policy. Mixed modes only rearrange
/// music slots, preserving every spoken-content slot and its relative order.
class ModeAwareQueuePlanner {
  ModeAwareQueuePlanner({IntelligentQueuePlanner? planner}) : _planner = planner ?? IntelligentQueuePlanner();
  final IntelligentQueuePlanner _planner;

  Future<ModeQueuePlanResult> arrange({
    required ModeProvider modes,
    required List<Song> tracks,
    String? requiredSongId,
  }) async {
    final acceptedTracks = tracks
        .where((song) => modes.isAcceptableForAutopilot(_asModeItem(song)))
        .toList(growable: false);
    if (requiredSongId != null &&
        !acceptedTracks.any((song) => song.id == requiredSongId)) {
      return const ModeQueuePlanResult(
        songs: [],
        usedDjPlanner: false,
        message: 'The selected item is excluded by the active mode content policy.',
      );
    }

    final intent = QueueIntent.forMode(modes.mode);
    if (intent == null) {
      return ModeQueuePlanResult(
        songs: List.unmodifiable(acceptedTracks),
        usedDjPlanner: false,
      );
    }

    final musicTracks = acceptedTracks
        .where((song) => modes.mediaTypeFor(_asModeItem(song)) == MediaType.music)
        .toList(growable: false);
    final hasNonMusicContent = acceptedTracks.any(
      (song) => modes.mediaTypeFor(_asModeItem(song)) != MediaType.music,
    );
    // Mixed means the mode actually contains spoken/other allowed content.
    // This also protects allowed motivational speech in Driving/Work/Workout.
    final mixedMedia = hasNonMusicContent;

    if (musicTracks.isEmpty) {
      return ModeQueuePlanResult(
        songs: List.unmodifiable(acceptedTracks),
        usedDjPlanner: hasNonMusicContent,
        message: 'No music tracks were present for DJ arrangement; the mode queue order was preserved.',
      );
    }

    final plan = await _planner.plan(musicTracks, intent: intent);
    if (!plan.isUsable) {
      if (mixedMedia) {
        return ModeQueuePlanResult(
          songs: List.unmodifiable(acceptedTracks),
          usedDjPlanner: true,
          plan: plan,
          message: 'DJ could not arrange the music yet (' +
              (plan.reason ?? 'analysis unavailable') +
              '). The original mixed-media order was preserved.',
        );
      }
      return ModeQueuePlanResult(
        songs: const [],
        usedDjPlanner: true,
        plan: plan,
        message: plan.reason ?? 'DJ analysis has not produced a usable queue yet.',
      );
    }

    if (requiredSongId != null &&
        !mixedMedia &&
        !plan.songs.any((song) => song.id == requiredSongId)) {
      return ModeQueuePlanResult(
        songs: const [],
        usedDjPlanner: true,
        plan: plan,
        message: 'That track does not meet the active ' +
            intent.label +
            ' tempo and energy profile.',
      );
    }

    if (mixedMedia) {
      // Keep unqualified tracks playable, but after the DJ-ranked music sequence.
      final plannedIds = plan.songs.map((song) => song.id).toSet();
      final orderedMusic = <Song>[
        ...plan.songs,
        ...musicTracks.where((song) => !plannedIds.contains(song.id)),
      ];
      var musicIndex = 0;
      final output = <Song>[];
      for (final song in acceptedTracks) {
        if (modes.mediaTypeFor(_asModeItem(song)) == MediaType.music) {
          output.add(orderedMusic[musicIndex++]);
        } else {
          output.add(song);
        }
      }
      final message = plan.status == QueuePlanStatus.ready
          ? 'DJ arranged the music while preserving spoken-content order.'
          : 'DJ arranged ' +
              plan.eligibleTrackCount.toString() +
              ' of ' +
              musicTracks.length.toString() +
              ' music tracks for ' +
              intent.label +
              '; unqualified tracks were retained after the analyzed sequence. Spoken-content order was preserved.';
      return ModeQueuePlanResult(
        songs: List.unmodifiable(output),
        usedDjPlanner: true,
        plan: plan,
        message: message,
      );
    }

    final message = plan.status == QueuePlanStatus.partial
        ? 'DJ arranged ' +
            plan.eligibleTrackCount.toString() +
            ' of ' +
            musicTracks.length.toString() +
            ' tracks for ' +
            intent.label +
            '; the remaining tracks lacked suitable analysis or fell outside the profile.'
        : 'DJ arranged this queue for ' + intent.label + '.';
    return ModeQueuePlanResult(
      songs: plan.songs,
      usedDjPlanner: true,
      plan: plan,
      message: message,
    );
  }

  ModeMediaItem _asModeItem(Song song) => ModeMediaItem(id: song.id, filePath: song.filePath, title: song.title, album: song.album, artist: song.artist);
}