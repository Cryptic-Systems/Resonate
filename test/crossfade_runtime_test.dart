import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/crossfade_runtime.dart';

void main() {
  group('CrossfadeRuntime ownership contract', () {
    test('automatic generations only advance when explicitly invalidated', () {
      final runtime = CrossfadeRuntime();

      expect(runtime.automaticTransitionGeneration, 0);
      expect(runtime.bumpAutomaticGeneration(), 1);
      expect(runtime.ownsAutomaticGeneration(1), isTrue);

      expect(runtime.bumpAutomaticGeneration(), 2);
      expect(runtime.ownsAutomaticGeneration(1), isFalse);
      expect(runtime.ownsAutomaticGeneration(2), isTrue);
    });

    test('clearing flags does not revive an older automatic transition', () {
      final runtime = CrossfadeRuntime();
      final oldGeneration = runtime.bumpAutomaticGeneration();
      runtime.inProgress = true;
      runtime.automaticInFlight = true;
      runtime.preloadInFlight = true;
      runtime.preloadedNextSongId = 'next';
      runtime.preloadedNextQueueIndex = 4;
      runtime.preloadedNextPath = '/music/next.mp3';
      runtime.preloadedOutgoingSongId = 'current';
      runtime.preloadedOutgoingQueueIndex = 3;
      runtime.preloadedOutgoingPath = '/music/current.mp3';
      runtime.deferTransition(
        outgoingSongId: 'failed-outgoing',
        outgoingQueueIndex: 1,
        outgoingPath: '/music/failed-outgoing.mp3',
        incomingSongId: 'failed-incoming',
        incomingQueueIndex: 2,
        incomingPath: '/music/failed-incoming.mp3',
      );
      runtime.repeatSelfHandoffArmed = true;
      runtime.repeatSelfHandoffInFlight = true;
      runtime.repeatSelfTargetSongId = 'current';

      runtime.clearFlags();

      expect(runtime.ownsAutomaticGeneration(oldGeneration), isTrue);
      expect(runtime.isLive, isFalse);
      expect(runtime.hasPreload, isFalse);
      expect(runtime.hasRepeatSelfHandoff, isFalse);
      expect(runtime.hasAutomaticWork, isFalse);
      expect(runtime.preloadedNextSongId, isNull);
      expect(runtime.preloadedNextQueueIndex, isNull);
      expect(runtime.preloadedNextPath, isNull);
      expect(runtime.preloadedOutgoingSongId, isNull);
      expect(runtime.preloadedOutgoingQueueIndex, isNull);
      expect(runtime.preloadedOutgoingPath, isNull);
      expect(runtime.hasDeferredTransition, isFalse);
      expect(runtime.repeatSelfTargetSongId, isNull);
    });

    test('defers only the exact failed queue occurrence until cleared', () {
      final runtime = CrossfadeRuntime();
      runtime.deferTransition(
        outgoingSongId: 'outgoing',
        outgoingQueueIndex: 2,
        outgoingPath: '/music/outgoing.mp3',
        incomingSongId: 'incoming',
        incomingQueueIndex: 3,
        incomingPath: '/music/incoming.mp3',
      );

      expect(runtime.hasDeferredTransition, isTrue);
      expect(
        runtime.defersTransition(
          outgoingSongId: 'outgoing',
          outgoingQueueIndex: 2,
          outgoingPath: '/music/outgoing.mp3',
          incomingSongId: 'incoming',
          incomingQueueIndex: 3,
          incomingPath: '/music/incoming.mp3',
        ),
        isTrue,
      );
      expect(
        runtime.defersTransition(
          outgoingSongId: 'outgoing',
          outgoingQueueIndex: 2,
          outgoingPath: '/music/outgoing.mp3',
          incomingSongId: 'incoming',
          incomingQueueIndex: 4,
          incomingPath: '/music/incoming.mp3',
        ),
        isFalse,
      );

      runtime.clearDeferredTransition();
      expect(runtime.hasDeferredTransition, isFalse);
    });

    test('native promotion requires terminal acknowledgement and exact deck occurrence', () {
      final runtime = CrossfadeRuntime();
      final base = <String, Object?>{
        'crossfadeStatus': 'completed',
        'activeDeckId': 'B',
        'outgoingDeckId': 'A',
        'currentSongId': 'incoming',
        'currentPath': '/music/incoming.mp3',
        'currentQueueIndex': 4,
        'incomingSongId': 'incoming',
        'incomingPath': '/music/incoming.mp3',
        'incomingQueueIndex': 4,
      };

      bool acknowledged(Map<String, Object?> values) =>
          runtime.acknowledgesNativePromotion(
            crossfadeStatus: values['crossfadeStatus']! as String,
            activeDeckId: values['activeDeckId']! as String,
            outgoingDeckId: values['outgoingDeckId']! as String,
            currentSongId: values['currentSongId'] as String?,
            currentPath: values['currentPath'] as String?,
            currentQueueIndex: values['currentQueueIndex']! as int,
            incomingSongId: values['incomingSongId']! as String,
            incomingPath: values['incomingPath']! as String,
            incomingQueueIndex: values['incomingQueueIndex']! as int,
          );

      expect(acknowledged(base), isTrue);
      expect(acknowledged({...base, 'crossfadeStatus': 'fading'}), isFalse);
      expect(acknowledged({...base, 'activeDeckId': 'A'}), isFalse);
      expect(acknowledged({...base, 'currentQueueIndex': 3}), isFalse);
      expect(acknowledged({...base, 'currentPath': '/music/other.mp3'}), isFalse);
    });

    test('reports every automatic-work category until each is cleared', () {
      final runtime = CrossfadeRuntime();

      runtime.inProgress = true;
      expect(runtime.hasAutomaticWork, isTrue);
      runtime.inProgress = false;

      runtime.preloadInFlight = true;
      expect(runtime.hasAutomaticWork, isTrue);
      runtime.preloadInFlight = false;

      runtime.repeatSelfHandoffArmed = true;
      expect(runtime.hasAutomaticWork, isTrue);
      runtime.clearRepeatSelf();

      expect(runtime.hasAutomaticWork, isFalse);
    });

    test('can clear active flags while preserving a repeat-self generation', () {
      final runtime = CrossfadeRuntime();
      final repeatGeneration = runtime.bumpRepeatSelfGeneration();
      runtime.repeatSelfHandoffArmed = true;
      runtime.repeatSelfTargetSongId = 'track-a';
      runtime.inProgress = true;

      runtime.clearFlags(clearRepeatSelf: false);

      expect(runtime.ownsRepeatSelfGeneration(repeatGeneration), isTrue);
      expect(runtime.repeatSelfHandoffArmed, isTrue);
      expect(runtime.repeatSelfTargetSongId, 'track-a');
      expect(runtime.inProgress, isFalse);
    });
  });
}
