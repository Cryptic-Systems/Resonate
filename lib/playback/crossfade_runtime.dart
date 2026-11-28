/// In-flight A/B crossfade / repeat-self state (not user preferences).
///
/// User-facing prefs (enabled, duration, fade curve) stay on [MusicProvider]
/// or [CrossfadeSettings]. This type owns generation tokens and flags so
/// transport cancel can invalidate stale automatic work without touching
/// engines.
class CrossfadeRuntime {
  bool inProgress = false;
  bool automaticInFlight = false;
  bool completionAdvanceInProgress = false;
  bool completionObservedDuringCrossfade = false;
  String? completionObservedSongId;

  /// Monotonic identity for the currently-owned automatic A/B transition.
  /// User transport invalidates the previous identity so stale async work
  /// cannot clear flags or commit an engine swap after a newer command.
  int automaticTransitionGeneration = 0;

  String? preloadedNextSongId;

  /// Queue-occurrence identity for the normal Media3 automatic preload.
  /// Media IDs alone are insufficient when the same recording occurs twice.
  int? preloadedNextQueueIndex;
  String? preloadedNextPath;
  String? preloadedOutgoingSongId;
  int? preloadedOutgoingQueueIndex;
  String? preloadedOutgoingPath;

  /// A failed normal crossfade is not retried on every position tick. Keep the
  /// exact outgoing/incoming occurrence pair deferred until the queue, track,
  /// or user transport changes.
  String? deferredOutgoingSongId;
  int? deferredOutgoingQueueIndex;
  String? deferredOutgoingPath;
  String? deferredIncomingSongId;
  int? deferredIncomingQueueIndex;
  String? deferredIncomingPath;

  bool preloadInFlight = false;

  /// Repeat-one + crossfade: seamless loop via idle engine (no queue advance).
  bool repeatSelfHandoffArmed = false;
  bool repeatSelfHandoffInFlight = false;
  int repeatSelfGeneration = 0;
  String? repeatSelfTargetSongId;

  DateTime? transitionArmedAt;
  String? lastDurationUnavailableSongId;

  bool get isLive => inProgress || automaticInFlight;

  bool get hasRepeatSelfHandoff =>
      repeatSelfHandoffArmed || repeatSelfHandoffInFlight;

  bool get hasPreload =>
      preloadInFlight || preloadedNextSongId != null;

  /// Any automatic A/B work that user transport must invalidate.
  bool get hasAutomaticWork =>
      isLive || hasPreload || hasRepeatSelfHandoff;

  bool get hasDeferredTransition =>
      deferredOutgoingSongId != null ||
      deferredOutgoingQueueIndex != null ||
      deferredIncomingSongId != null ||
      deferredIncomingQueueIndex != null;

  bool defersTransition({
    required String outgoingSongId,
    required int outgoingQueueIndex,
    required String outgoingPath,
    required String incomingSongId,
    required int incomingQueueIndex,
    required String incomingPath,
  }) =>
      deferredOutgoingSongId == outgoingSongId &&
      deferredOutgoingQueueIndex == outgoingQueueIndex &&
      deferredOutgoingPath == outgoingPath &&
      deferredIncomingSongId == incomingSongId &&
      deferredIncomingQueueIndex == incomingQueueIndex &&
      deferredIncomingPath == incomingPath;

  void deferTransition({
    required String outgoingSongId,
    required int outgoingQueueIndex,
    required String outgoingPath,
    required String incomingSongId,
    required int incomingQueueIndex,
    required String incomingPath,
  }) {
    deferredOutgoingSongId = outgoingSongId;
    deferredOutgoingQueueIndex = outgoingQueueIndex;
    deferredOutgoingPath = outgoingPath;
    deferredIncomingSongId = incomingSongId;
    deferredIncomingQueueIndex = incomingQueueIndex;
    deferredIncomingPath = incomingPath;
  }

  void clearDeferredTransition() {
    deferredOutgoingSongId = null;
    deferredOutgoingQueueIndex = null;
    deferredOutgoingPath = null;
    deferredIncomingSongId = null;
    deferredIncomingQueueIndex = null;
    deferredIncomingPath = null;
  }

  /// Native promotion is committed only when Media3 reports its terminal
  /// completion state, the canonical physical deck has changed, and the exact
  /// incoming queue occurrence is now active. A media ID alone is not enough:
  /// duplicate playlist entries can share an ID or URI.
  bool acknowledgesNativePromotion({
    required String crossfadeStatus,
    required String activeDeckId,
    required String outgoingDeckId,
    required String? currentSongId,
    required String? currentPath,
    required int currentQueueIndex,
    required String incomingSongId,
    required String incomingPath,
    required int incomingQueueIndex,
  }) =>
      crossfadeStatus == 'completed' &&
      activeDeckId != outgoingDeckId &&
      currentSongId == incomingSongId &&
      currentPath?.trim() == incomingPath.trim() &&
      currentQueueIndex == incomingQueueIndex;

  /// Convert the native Media3 envelope position into the shared
  /// transition-effects timeline. Native progress pauses with the actual audio
  /// ramp, unlike wall-clock elapsed time in Flutter.
  /// Media3 position is media time, but the native fade clock runs in
  /// wall time. Convert the remaining media window using the active deck rate.
  int wallTimeRemainingMilliseconds({
    required int mediaTimeRemainingMs,
    required double playbackSpeed,
  }) {
    if (mediaTimeRemainingMs <= 0) return 0;
    final speed = playbackSpeed.isFinite
        ? playbackSpeed.clamp(0.5, 2.0).toDouble()
        : 1.0;
    return (mediaTimeRemainingMs / speed).floor();
  }

  int elapsedMillisecondsForNativeProgress({
    required double progress,
    required int durationMs,
  }) {
    if (durationMs <= 0) return 0;
    final normalized = progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    return (normalized * durationMs).round().clamp(0, durationMs).toInt();
  }

  int bumpAutomaticGeneration() => ++automaticTransitionGeneration;

  int bumpRepeatSelfGeneration() => ++repeatSelfGeneration;

  bool ownsAutomaticGeneration(int generation) =>
      automaticTransitionGeneration == generation;

  bool ownsRepeatSelfGeneration(int generation) =>
      repeatSelfGeneration == generation;

  void clearFlags({bool clearRepeatSelf = true}) {
    automaticInFlight = false;
    inProgress = false;
    completionAdvanceInProgress = false;
    completionObservedDuringCrossfade = false;
    completionObservedSongId = null;
    preloadedNextSongId = null;
    preloadedNextQueueIndex = null;
    preloadedNextPath = null;
    preloadedOutgoingSongId = null;
    preloadedOutgoingQueueIndex = null;
    preloadedOutgoingPath = null;
    deferredOutgoingSongId = null;
    deferredOutgoingQueueIndex = null;
    deferredOutgoingPath = null;
    deferredIncomingSongId = null;
    deferredIncomingQueueIndex = null;
    deferredIncomingPath = null;
    preloadInFlight = false;
    if (clearRepeatSelf) {
      repeatSelfHandoffArmed = false;
      repeatSelfHandoffInFlight = false;
      repeatSelfTargetSongId = null;
    }
    transitionArmedAt = null;
  }

  void clearRepeatSelf() {
    repeatSelfHandoffArmed = false;
    repeatSelfHandoffInFlight = false;
    repeatSelfTargetSongId = null;
  }

  void markDurationUnavailable(String songId) {
    lastDurationUnavailableSongId = songId;
  }

  void clearDurationUnavailable() {
    lastDurationUnavailableSongId = null;
  }
}
