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
  });
}
