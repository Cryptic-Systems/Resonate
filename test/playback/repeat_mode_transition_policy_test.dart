import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/repeat_mode_transition_policy.dart';

void main() {
  group('RepeatModeTransitionPolicy', () {
    test('does not cancel an already promoted Media3 crossfade', () {
      final promoted = RepeatModeTransitionPolicy.isMedia3HandoffPromoted(
        media3SessionActive: true,
        crossfadeStatus: 'completed',
        preloadedSongId: 'track-b',
        media3CurrentSongId: 'track-b',
      );

      expect(promoted, isTrue);
      expect(
        RepeatModeTransitionPolicy.shouldCancelAutomaticWork(
          transitionActive: true,
          repeatSelfFadeInProgress: false,
          media3HandoffPromoted: promoted,
        ),
        isFalse,
      );
    });

    test('recognizes promotion when the incoming media item arrives first', () {
      expect(
        RepeatModeTransitionPolicy.isMedia3HandoffPromoted(
          media3SessionActive: true,
          crossfadeStatus: 'fading',
          preloadedSongId: 'track-b',
          media3CurrentSongId: 'track-b',
        ),
        isTrue,
      );
    });

    test('still cancels a preload that has not promoted', () {
      final promoted = RepeatModeTransitionPolicy.isMedia3HandoffPromoted(
        media3SessionActive: true,
        crossfadeStatus: 'preparing',
        preloadedSongId: 'track-b',
        media3CurrentSongId: 'track-a',
      );

      expect(promoted, isFalse);
      expect(
        RepeatModeTransitionPolicy.shouldCancelAutomaticWork(
          transitionActive: true,
          repeatSelfFadeInProgress: false,
          media3HandoffPromoted: promoted,
        ),
        isTrue,
      );
    });

    test('preserves an already audible Repeat One self-fade', () {
      expect(
        RepeatModeTransitionPolicy.shouldCancelAutomaticWork(
          transitionActive: true,
          repeatSelfFadeInProgress: true,
          media3HandoffPromoted: false,
        ),
        isFalse,
      );
    });

    test('does nothing when no automatic transition is active', () {
      expect(
        RepeatModeTransitionPolicy.shouldCancelAutomaticWork(
          transitionActive: false,
          repeatSelfFadeInProgress: false,
          media3HandoffPromoted: false,
        ),
        isFalse,
      );
    });
  });
}
