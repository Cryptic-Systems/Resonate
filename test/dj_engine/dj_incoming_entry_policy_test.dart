import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/core/dj_incoming_entry_policy.dart';

void main() {
  group('DjIncomingEntryPolicy', () {
    test('bounds automatic entry to 15 percent and caps long tracks', () {
      expect(
        DjIncomingEntryPolicy.maximumAutomaticEntryMs(240000),
        36000,
      );
      expect(
        DjIncomingEntryPolicy.maximumAutomaticEntryMs(600000),
        45000,
      );
      expect(
        DjIncomingEntryPolicy.maximumAutomaticEntryMs(120000),
        18000,
      );
      expect(
        DjIncomingEntryPolicy.maximumAutomaticEntryMs(null),
        45000,
      );
    });

    test('rejects late automatic cues to the start of the incoming track', () {
      expect(
        DjIncomingEntryPolicy.normalizeAutomaticEntryMs(
          requestedMs: 90000,
          durationMs: 240000,
        ),
        0,
      );
      expect(
        DjIncomingEntryPolicy.normalizeAutomaticEntryMs(
          requestedMs: -1,
          durationMs: 240000,
        ),
        0,
      );
      expect(
        DjIncomingEntryPolicy.normalizeAutomaticEntryMs(
          requestedMs: 30000,
          durationMs: 240000,
        ),
        30000,
      );
    });

    test('allows a reviewed late cue but still bounds it to track duration', () {
      expect(
        DjIncomingEntryPolicy.normalizeAutomaticEntryMs(
          requestedMs: 90000,
          durationMs: 240000,
          allowReviewedLateCue: true,
        ),
        90000,
      );
      expect(
        DjIncomingEntryPolicy.normalizeAutomaticEntryMs(
          requestedMs: 300000,
          durationMs: 240000,
          allowReviewedLateCue: true,
        ),
        239999,
      );
    });
  });
}
