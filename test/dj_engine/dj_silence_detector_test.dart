import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/analysis/dj_silence_detector.dart';

List<DjRmsSample> _samples({
  required int startMs,
  required int count,
  required double rms,
  int stepMs = 100,
}) {
  return List.generate(
    count,
    (index) => DjRmsSample(
      timeMs: startMs + index * stepMs,
      rms: rms,
      windowMs: stepMs,
    ),
  );
}

void main() {
  group('DjSilenceDetector', () {
    const detector = DjSilenceDetector();

    test('finds sustained near-silence in the monitored outro region', () {
      final samples = [
        ..._samples(startMs: 0, count: 1200, rms: 0.10),
        ..._samples(startMs: 120000, count: 35, rms: 0.0001),
      ];

      final result = detector.detect(samples, durationMs: 180000);

      expect(result, hasLength(1));
      expect(result.single.startMs, 120000);
      expect(result.single.durationMs, greaterThanOrEqualTo(2000));
      expect(result.single.confidence, greaterThanOrEqualTo(0.65));
      expect(result.single.minimumDbfs, lessThan(-70));
    });

    test('does not classify a quiet musical breakdown as silence', () {
      final samples = [
        ..._samples(startMs: 0, count: 1200, rms: 0.10),
        ..._samples(startMs: 120000, count: 80, rms: 0.01),
      ];

      expect(
        detector.detect(samples, durationMs: 180000),
        isEmpty,
      );
    });

    test('ignores brief digital gaps shorter than the minimum hold', () {
      final samples = [
        ..._samples(startMs: 0, count: 1200, rms: 0.10),
        ..._samples(startMs: 120000, count: 8, rms: 0.00001),
        ..._samples(startMs: 120800, count: 20, rms: 0.10),
      ];

      expect(
        detector.detect(samples, durationMs: 180000),
        isEmpty,
      );
    });

    test('hysteresis closes a silence candidate when level recovers', () {
      final samples = [
        ..._samples(startMs: 0, count: 1200, rms: 0.10),
        ..._samples(startMs: 120000, count: 30, rms: 0.0001),
        ..._samples(startMs: 123000, count: 10, rms: 0.02),
      ];

      final result = detector.detect(samples, durationMs: 180000);

      expect(result, hasLength(1));
      expect(result.single.endMs, 123000);
    });

    test('does not flag a globally quiet or low-level recording', () {
      final samples = _samples(
        startMs: 0,
        count: 1800,
        rms: 0.001,
      );

      expect(
        detector.detect(samples, durationMs: 180000),
        isEmpty,
      );
    });

    test('ignores silence before the configured outro monitoring point', () {
      final samples = [
        ..._samples(startMs: 0, count: 30, rms: 0.00001),
        ..._samples(startMs: 3000, count: 1770, rms: 0.10),
      ];

      expect(
        detector.detect(samples, durationMs: 180000),
        isEmpty,
      );
    });

    test('rejects malformed samples and insufficient evidence safely', () {
      final result = detector.detect(
        const [
          DjRmsSample(timeMs: -1, rms: 0.0),
          DjRmsSample(timeMs: 1000, rms: double.nan),
          DjRmsSample(timeMs: 2000, rms: -1.0),
        ],
        durationMs: 180000,
      );

      expect(result, isEmpty);
      expect(detector.detect(const [], durationMs: 0), isEmpty);
    });
  });
}
