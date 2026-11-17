import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/services/intelligence_mix_request_guard.dart';

void main() {
  group('IntelligenceMixRequestGuard', () {
    test('newer request invalidates an older in-flight result', () {
      final guard = IntelligenceMixRequestGuard();
      final first = guard.begin();
      final second = guard.begin();

      expect(guard.owns(
        requestGeneration: first,
        sourceSongId: 'track-a',
        currentSongId: 'track-a',
        intelligenceEnabled: true,
      ), isFalse);
      expect(guard.owns(
        requestGeneration: second,
        sourceSongId: 'track-a',
        currentSongId: 'track-a',
        intelligenceEnabled: true,
      ), isTrue);
    });

    test('playback changes invalidate a result from the previous source', () {
      final guard = IntelligenceMixRequestGuard();
      final request = guard.begin();

      expect(guard.owns(
        requestGeneration: request,
        sourceSongId: 'track-a',
        currentSongId: 'track-b',
        intelligenceEnabled: true,
      ), isFalse);
    });

    test('disabling Intelligence invalidates pending generation', () {
      final guard = IntelligenceMixRequestGuard();
      final request = guard.begin();

      expect(guard.owns(
        requestGeneration: request,
        sourceSongId: 'track-a',
        currentSongId: 'track-a',
        intelligenceEnabled: false,
      ), isFalse);
    });

    test('explicit invalidation rejects an in-flight request', () {
      final guard = IntelligenceMixRequestGuard();
      final request = guard.begin();
      guard.invalidate();

      expect(guard.owns(
        requestGeneration: request,
        sourceSongId: null,
        currentSongId: null,
        intelligenceEnabled: true,
      ), isFalse);
    });
  });
}
