/// Compares the exact upcoming sequence captured before asynchronous
/// planning with the live queue immediately before a planned append.
class QueueSnapshotGuard {
  const QueueSnapshotGuard._();

  static bool matches({
    required List<String> expected,
    required List<String> actual,
  }) {
    if (expected.length != actual.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (expected[index] != actual[index]) return false;
    }
    return true;
  }
}
