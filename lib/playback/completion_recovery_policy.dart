/// Decides whether the end-of-track watchdog may recover a completion
/// observed while a crossfade was in flight.
///
/// A completed event is durable evidence for the expected queue occurrence:
/// a later player-state snapshot can be stale or no longer report completed
/// after transition cleanup. Queue exhaustion remains authoritative.
class CompletionRecoveryPolicy {
  const CompletionRecoveryPolicy._();

  static bool shouldAdvance({
    required bool atEnd,
    required bool canAdvance,
    required bool completionObservedDuringTransition,
  }) {
    return canAdvance && (atEnd || completionObservedDuringTransition);
  }
}
