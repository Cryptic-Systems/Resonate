import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/screens/dj_console_manual_controls_policy.dart';

Song _song({
  required String id,
  required String path,
}) => Song(
      id: id,
      title: id,
      artist: 'Artist',
      album: 'Album',
      filePath: path,
      duration: const Duration(minutes: 3),
      dateAdded: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('DjConsoleManualControlsPolicy', () {
    test('excludes current occurrence and entries without playable paths', () {
      final queue = [
        _song(id: 'active', path: '/music/active.mp3'),
        _song(id: 'missing', path: '  '),
        _song(id: 'incoming', path: '/music/incoming.mp3'),
      ];

      expect(
        DjConsoleManualControlsPolicy.incomingCandidates(
          queue,
          currentQueueIndex: 0,
        ),
        [2],
      );
    });

    test('preserves duplicate song occurrences as separate queue choices', () {
      final duplicate = _song(id: 'same-id', path: '/music/same.mp3');
      final queue = [
        _song(id: 'active', path: '/music/active.mp3'),
        duplicate,
        duplicate,
      ];

      // When the middle occurrence is active, both the earlier queue item
      // and the later duplicate remain valid choices. Only the active index
      // is excluded; candidate order and occurrence identity are preserved.
      expect(
        DjConsoleManualControlsPolicy.incomingCandidates(
          queue,
          currentQueueIndex: 1,
        ),
        [0, 2],
      );
      expect(
        DjConsoleManualControlsPolicy.incomingCandidates(
          queue,
          currentQueueIndex: 0,
        ),
        [1, 2],
      );
    });

    test('cue preview requires both media ID and queue occurrence', () {
      expect(
        DjConsoleManualControlsPolicy.matchesCuePreview(
          previewSongId: 'same-id',
          previewQueueIndex: 4,
          preparedSongId: 'same-id',
          preparedQueueIndex: 4,
        ),
        isTrue,
      );
      expect(
        DjConsoleManualControlsPolicy.matchesCuePreview(
          previewSongId: 'same-id',
          previewQueueIndex: 4,
          preparedSongId: 'same-id',
          preparedQueueIndex: 5,
        ),
        isFalse,
      );
      expect(
        DjConsoleManualControlsPolicy.matchesCuePreview(
          previewSongId: 'old-id',
          previewQueueIndex: 4,
          preparedSongId: 'new-id',
          preparedQueueIndex: 4,
        ),
        isFalse,
      );
    });

    test('no incoming candidates when all other paths are empty', () {
      final queue = [
        _song(id: 'active', path: '/music/active.mp3'),
        _song(id: 'missing-a', path: ''),
        _song(id: 'missing-b', path: '   '),
      ];

      expect(
        DjConsoleManualControlsPolicy.incomingCandidates(
          queue,
          currentQueueIndex: 0,
        ),
        isEmpty,
      );
    });

    test('crossfader status explains the first unmet operating requirement', () {
      String status({
        bool dj = true,
        bool media3 = true,
        bool transition = false,
        bool aLoaded = true,
        bool bLoaded = true,
        bool aPlaying = true,
        bool bPlaying = true,
      }) =>
          DjConsoleManualControlsPolicy.crossfaderStatusText(
            djModeEnabled: dj,
            media3SessionActive: media3,
            transitionInProgress: transition,
            deckAHasMedia: aLoaded,
            deckBHasMedia: bLoaded,
            deckAIsPlaying: aPlaying,
            deckBIsPlaying: bPlaying,
          );

      expect(status(dj: false), 'START DJ SESSION');
      expect(status(media3: false), 'MEDIA3 SESSION INACTIVE');
      expect(status(transition: true), 'TRANSITION IN PROGRESS');
      expect(status(bLoaded: false), 'LOAD BOTH DECKS');
      expect(status(aPlaying: false), 'FADER PRESET · PLAY BOTH DECKS');
      expect(status(bPlaying: false), 'FADER PRESET · PLAY BOTH DECKS');
      expect(status(), 'MANUAL MIX READY');
    });

    test('channel gain requires a loaded deck and an active safe DJ session', () {
      expect(
        DjConsoleManualControlsPolicy.canAdjustChannelGain(
          djModeEnabled: true,
          media3SessionActive: true,
          transitionInProgress: false,
          deckHasMedia: true,
        ),
        isTrue,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustChannelGain(
          djModeEnabled: true,
          media3SessionActive: true,
          transitionInProgress: true,
          deckHasMedia: true,
        ),
        isFalse,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustChannelGain(
          djModeEnabled: true,
          media3SessionActive: false,
          transitionInProgress: false,
          deckHasMedia: true,
        ),
        isFalse,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustChannelGain(
          djModeEnabled: false,
          media3SessionActive: true,
          transitionInProgress: false,
          deckHasMedia: true,
        ),
        isFalse,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustChannelGain(
          djModeEnabled: true,
          media3SessionActive: true,
          transitionInProgress: false,
          deckHasMedia: false,
        ),
        isFalse,
      );
    });

    test('crossfader can be pre-positioned with two loaded decks in DJ mode', () {
      expect(
        DjConsoleManualControlsPolicy.canAdjustCrossfader(
          djModeEnabled: true,
          transitionInProgress: false,
          deckAHasMedia: true,
          deckBHasMedia: true,
        ),
        isTrue,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustCrossfader(
          djModeEnabled: true,
          transitionInProgress: true,
          deckAHasMedia: true,
          deckBHasMedia: true,
        ),
        isFalse,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustCrossfader(
          djModeEnabled: true,
          transitionInProgress: false,
          deckAHasMedia: true,
          deckBHasMedia: false,
        ),
        isFalse,
      );
      expect(
        DjConsoleManualControlsPolicy.canAdjustCrossfader(
          djModeEnabled: false,
          transitionInProgress: false,
          deckAHasMedia: true,
          deckBHasMedia: true,
        ),
        isFalse,
      );
    });
  });
}
