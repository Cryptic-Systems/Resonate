import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/crossfade_orchestrator.dart';

void main() {
  group('approved DJ cue timing', () {
    test('preloads the standby deck inside the ten-second lead window', () {
      expect(
        CrossfadeOrchestrator.shouldPreloadForApprovedCue(
          positionMs: 14999,
          cueMs: 25000,
        ),
        isFalse,
      );
      expect(
        CrossfadeOrchestrator.shouldPreloadForApprovedCue(
          positionMs: 15000,
          cueMs: 25000,
        ),
        isTrue,
      );
      expect(
        CrossfadeOrchestrator.shouldPreloadForApprovedCue(
          positionMs: 24999,
          cueMs: 25000,
        ),
        isTrue,
      );
      expect(
        CrossfadeOrchestrator.shouldPreloadForApprovedCue(
          positionMs: 25000,
          cueMs: 25000,
        ),
        isFalse,
      );
    });

    test('preloads immediately when the cue is within the initial lead window', () {
      expect(
        CrossfadeOrchestrator.shouldPreloadForApprovedCue(
          positionMs: 0,
          cueMs: 6000,
        ),
        isTrue,
      );
    });

    test('starts only once the approved outgoing cue is reached', () {
      expect(
        CrossfadeOrchestrator.shouldStartAtApprovedCue(
          positionMs: 24999,
          cueMs: 25000,
        ),
        isFalse,
      );
      expect(
        CrossfadeOrchestrator.shouldStartAtApprovedCue(
          positionMs: 25000,
          cueMs: 25000,
        ),
        isTrue,
      );
      expect(
        CrossfadeOrchestrator.shouldStartAtApprovedCue(
          positionMs: 25200,
          cueMs: 25000,
        ),
        isTrue,
      );
    });

    test('rejects malformed negative cue timing', () {
      expect(
        CrossfadeOrchestrator.shouldPreloadForApprovedCue(
          positionMs: 0,
          cueMs: -1,
        ),
        isFalse,
      );
      expect(
        CrossfadeOrchestrator.shouldStartAtApprovedCue(
          positionMs: 1000,
          cueMs: -1,
        ),
        isFalse,
      );
    });
  });
}
