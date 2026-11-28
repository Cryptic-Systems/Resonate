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
