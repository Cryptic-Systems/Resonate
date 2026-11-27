import 'dj_types.dart';

/// Selects only high-confidence, sustained PCM silence close to the true tail.
/// A quiet breakdown or long mid-track gap is never a transition trigger.
class DjSilenceTransitionPolicy {
  const DjSilenceTransitionPolicy._();

  static int? nextSafeTailCue({
    required DjTrackProfile profile,
    required int currentPositionMs,
    int lookAheadMs = 45000,
    int maximumTailDistanceMs = 20000,
  }) {
    final duration = profile.durationMs;
    if (duration == null ||
        duration <= 0 ||
        currentPositionMs < 0 ||
        currentPositionMs >= duration ||
        lookAheadMs < 0 ||
        maximumTailDistanceMs < 2000) {
      return null;
    }

    final candidates = profile.silenceRegions.where((region) {
      final tailDistance = duration - region.startMs;
      return region.startMs >= currentPositionMs &&
          region.startMs - currentPositionMs <= lookAheadMs &&
          tailDistance <= maximumTailDistanceMs &&
          region.startMs >= duration * 0.85 &&
          region.endMs >= duration - 1500 &&
          region.endMs <= duration + 250 &&
          region.durationMs >= 2000 &&
          region.minimumDbfs.isFinite &&
          region.minimumDbfs <= -48.0 &&
          region.confidence.isFinite &&
          region.confidence >= 0.78;
    }).toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    return candidates.isEmpty ? null : candidates.first.startMs;
  }
}
