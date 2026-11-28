import 'dart:math' as math;

/// Conservative guard for automatic incoming-track entry points.
///
/// Automatic transitions should introduce the incoming track near its opening,
/// not seek to a later breakdown/drop simply because that section scored well.
/// Explicitly reviewed pair presets may opt into a later cue.
class DjIncomingEntryPolicy {
  const DjIncomingEntryPolicy._();

  static const int maximumOpeningEntryMs = 45000;
  static const double maximumOpeningEntryFraction = 0.15;

  static int maximumAutomaticEntryMs(int? durationMs) {
    if (durationMs == null || durationMs <= 0) return maximumOpeningEntryMs;
    return math.min(
      maximumOpeningEntryMs,
      (durationMs * maximumOpeningEntryFraction).round(),
    ).clamp(0, maximumOpeningEntryMs).toInt();
  }

  static bool isAutomaticOpeningEntry(int positionMs, int? durationMs) =>
      positionMs >= 0 &&
      positionMs <= maximumAutomaticEntryMs(durationMs) &&
      (durationMs == null || durationMs <= 0 || positionMs < durationMs);

  /// Invalid or late automatic cues safely fall back to the incoming beginning.
  static int normalizeAutomaticEntryMs({
    required int requestedMs,
    required int? durationMs,
    bool allowReviewedLateCue = false,
  }) {
    if (requestedMs < 0) return 0;
    if (!allowReviewedLateCue &&
        !isAutomaticOpeningEntry(requestedMs, durationMs)) return 0;
    if (durationMs != null && durationMs > 0) {
      return requestedMs.clamp(0, durationMs - 1).toInt();
    }
    return requestedMs;
  }
}
