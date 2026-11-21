import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/queue_snapshot_guard.dart';

void main() {
  group('QueueSnapshotGuard', () {
    test('accepts an unchanged upcoming sequence', () {
      expect(
        QueueSnapshotGuard.matches(
          expected: const ['b', 'c'],
          actual: const ['b', 'c'],
        ),
        isTrue,
      );
    });

    test('rejects a cleared, shortened, or reordered upcoming sequence', () {
      expect(
        QueueSnapshotGuard.matches(
          expected: const ['b', 'c'],
          actual: const [],
        ),
        isFalse,
      );
      expect(
        QueueSnapshotGuard.matches(
          expected: const ['b', 'c'],
          actual: const ['b'],
        ),
        isFalse,
      );
      expect(
        QueueSnapshotGuard.matches(
          expected: const ['b', 'c'],
          actual: const ['c', 'b'],
        ),
        isFalse,
      );
    });

    test('rejects a newly inserted upcoming track', () {
      expect(
        QueueSnapshotGuard.matches(
          expected: const ['b'],
          actual: const ['x', 'b'],
        ),
        isFalse,
      );
    });
  });
}
