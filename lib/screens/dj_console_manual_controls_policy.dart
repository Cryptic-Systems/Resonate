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

  /// The crossfader remains active with either physical deck loaded. This is
  /// essential for cutting a playing deck to silence while the opposite deck
  /// is empty or paused; transitions retain exclusive gain ownership.
  static bool canAdjustCrossfader({
    required bool djModeEnabled,
    required bool transitionInProgress,
    required bool deckAHasMedia,
    required bool deckBHasMedia,
  }) =>
      djModeEnabled &&
      !transitionInProgress &&
      (deckAHasMedia || deckBHasMedia);

  /// Explain why the manual crossfader is unavailable. Keep the operator
  /// informed of the next actionable prerequisite instead of using one
  /// generic disabled-state message.
  static String crossfaderStatusText({
    required bool djModeEnabled,
    required bool media3SessionActive,
    required bool transitionInProgress,
    required bool deckAHasMedia,
    required bool deckBHasMedia,
    required bool deckAIsPlaying,
    required bool deckBIsPlaying,
  }) {
    if (!djModeEnabled) return 'START DJ SESSION';
    if (!media3SessionActive) return 'MEDIA3 SESSION INACTIVE';
    if (transitionInProgress) return 'TRANSITION IN PROGRESS';
    if (!deckAHasMedia && !deckBHasMedia) return 'LOAD A DECK';

    // A transport flag on an empty deck is stale/invalid state. Only count a
    // deck as playing when it owns loaded media.
    final deckAActive = deckAHasMedia && deckAIsPlaying;
    final deckBActive = deckBHasMedia && deckBIsPlaying;
    if (!deckAActive && !deckBActive) return 'DECKS STOPPED';
    if (!deckAActive || !deckBActive) {
      return 'ONE DECK PLAYING · FADER ACTIVE';
    }
    return 'MANUAL MIX READY';
  }

  /// Whether a physical deck is actually audible through the manual
  /// crossfader. Position 0 routes to A, position 1 routes to B; at the
  /// midpoint both playing decks are on air. A tiny residual contribution
  /// at an endpoint is treated as effectively silent for status display.
  static bool isDeckOnAir({
    required String deckId,
    required bool deckHasMedia,
    required bool isPlaying,
    required double crossfaderPosition,
    double audibleThreshold = 0.01,
  }) {
    if (!deckHasMedia || !isPlaying || !crossfaderPosition.isFinite) {
      return false;
    }
    final position = crossfaderPosition.clamp(0.0, 1.0);
    final contribution = switch (deckId) {
      'A' => 1.0 - position,
      'B' => position,
      _ => 0.0,
    };
    return contribution > audibleThreshold;
  }

  /// Keep selection, transport and audible routing as separate concepts.
  /// On-air takes precedence; a selected paused deck remains visibly selected.
  static String deckStatusLabel({
    required bool selected,
    required bool isPlaying,
    required bool onAir,
    required bool deckHasMedia,
  }) {
    if (!deckHasMedia) return 'EMPTY';
    if (onAir) return 'ON AIR';
    if (isPlaying) return 'PLAYING';
    if (selected) return 'SELECTED';
    return 'STANDBY';
  }

  /// Channel gain can be adjusted on a loaded deck, including while paused,
  /// but never while the native transition controller owns deck gain.
  static bool canAdjustChannelGain({
    required bool djModeEnabled,
    required bool media3SessionActive,
    required bool transitionInProgress,
    required bool deckHasMedia,
  }) =>
      djModeEnabled &&
      media3SessionActive &&
      !transitionInProgress &&
      deckHasMedia;

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
