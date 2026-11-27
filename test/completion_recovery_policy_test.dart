import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/completion_recovery_policy.dart';

void main() {
  group('CompletionRecoveryPolicy', () {
    test('recovers a completion observed during a transition', () {
      expect(
        CompletionRecoveryPolicy.shouldAdvance(
          atEnd: false,
          canAdvance: true,
          completionObservedDuringTransition: true,
        ),
        isTrue,
      );
    });

    test('does not advance before end without a completion observation', () {
      expect(
        CompletionRecoveryPolicy.shouldAdvance(
          atEnd: false,
          canAdvance: true,
          completionObservedDuringTransition: false,
        ),
        isFalse,
      );
    });

    test('does not advance when the queue is exhausted', () {
      expect(
        CompletionRecoveryPolicy.shouldAdvance(
          atEnd: true,
          canAdvance: false,
          completionObservedDuringTransition: true,
        ),
        isFalse,
      );
    });

    test('retains ordinary end-of-track watchdog recovery', () {
      expect(
        CompletionRecoveryPolicy.shouldAdvance(
          atEnd: true,
          canAdvance: true,
          completionObservedDuringTransition: false,
        ),
        isTrue,
      );
    });
  });
}
