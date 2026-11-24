import '../models/song.dart';

/// Pure UI eligibility and identity rules for the manual Deck B controls.
class DjConsoleManualControlsPolicy {
  const DjConsoleManualControlsPolicy._();

  /// Returns playable queue occurrences other than the current occurrence.
  /// Indices are preserved because duplicate song IDs may occur in a queue.
  static List<int> incomingCandidates(
    List<Song> queue, {
    required int currentQueueIndex,
  }) => [
    for (var index = 0; index < queue.length; index++)
      if (index != currentQueueIndex &&
          queue[index].filePath.trim().isNotEmpty)
        index,
  ];

  /// The native crossfader only accepts writes while both physical decks are
  /// loaded and audibly playing. Mirror those preconditions in the UI so an
  /// unavailable fader is disabled rather than repeatedly sending rejected
  /// MethodChannel commands.
  static bool canAdjustCrossfader({
    required bool djModeEnabled,
    required bool transitionInProgress,
    required bool deckAHasMedia,
    required bool deckBHasMedia,
    required bool deckAIsPlaying,
    required bool deckBIsPlaying,
  }) =>
      djModeEnabled &&
      !transitionInProgress &&
      deckAHasMedia &&
      deckBHasMedia &&
      deckAIsPlaying &&
      deckBIsPlaying;

  /// Cue preview belongs to a queue occurrence, not just a media ID.
  static bool matchesCuePreview({
    required String? previewSongId,
    required int? previewQueueIndex,
    required String preparedSongId,
    required int preparedQueueIndex,
  }) =>
      previewSongId == preparedSongId &&
      previewQueueIndex == preparedQueueIndex;
}
