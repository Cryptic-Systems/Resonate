/// Decides whether a repeat-mode change may invalidate automatic playback work.
///
/// A completed Media3 crossfade has already transferred audible ownership to
/// the incoming deck. Its provider finalizer must be allowed to finish; cancelling
/// it in the brief native-to-Flutter state propagation window can disturb the
/// newly promoted item.
class RepeatModeTransitionPolicy {
  const RepeatModeTransitionPolicy._();

  static bool isMedia3HandoffPromoted({
    required bool media3SessionActive,
    required String? crossfadeStatus,
    required String? preloadedSongId,
    required String? media3CurrentSongId,
  }) {
    if (!media3SessionActive) return false;
    return crossfadeStatus == 'completed' ||
        (preloadedSongId != null && media3CurrentSongId == preloadedSongId);
  }

  static bool shouldCancelAutomaticWork({
    required bool transitionActive,
    required bool repeatSelfFadeInProgress,
    required bool media3HandoffPromoted,
  }) =>
      transitionActive && !repeatSelfFadeInProgress && !media3HandoffPromoted;
}
