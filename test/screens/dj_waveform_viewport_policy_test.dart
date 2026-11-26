import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/screens/dj_waveform_viewport_policy.dart';

void main() {
  const policy = DjWaveformViewportPolicy();

  test('overview requests the complete track and fits it to the deck width', () {
    final range = policy.visibleRange(
      durationMs: 240000,
      viewportWidth: 320,
      scrollOffset: 0,
    )!;
    expect(range.startMs, 0);
    expect(range.endMs, 240000);
    expect(range.contentWidth, 320);
  });

  test('full-track range is stable regardless of scroll offset', () {
    final range = policy.visibleRange(
      durationMs: 240000,
      viewportWidth: 320,
      scrollOffset: 160,
    )!;
    expect(range.startMs, 0);
    expect(range.endMs, 240000);
    expect(range.contentWidth, 320);
  });

  test('short tracks also occupy the full overview width', () {
    final range = policy.visibleRange(
      durationMs: 5000,
      viewportWidth: 320,
      scrollOffset: 0,
    )!;
    expect(range.startMs, 0);
    expect(range.endMs, 5000);
    expect(range.contentWidth, 320);
  });

  test('overview downsamples long tracks to viewport resolution', () {
    final segments = List<DjWaveformSegment>.generate(
      100,
      (index) => DjWaveformSegment(
        startMs: index * 8000,
        endMs: (index + 1) * 8000,
        peaks: List<double>.filled(256, 0.4),
      ),
    );
    final overview = policy.overviewSegments(
      segments: segments,
      durationMs: 800000,
      viewportWidth: 320,
    );
    expect(overview, hasLength(1));
    expect(overview.single.startMs, 0);
    expect(overview.single.endMs, 800000);
    expect(overview.single.peaks.length, lessThanOrEqualTo(400));
  });

  test('overview preserves unanalysed gaps instead of drawing silence', () {
    final overview = policy.overviewSegments(
      segments: const [
        DjWaveformSegment(startMs: 0, endMs: 4000, peaks: [0.2, 0.4]),
        DjWaveformSegment(startMs: 6000, endMs: 10000, peaks: [0.3, 0.5]),
      ],
      durationMs: 10000,
      viewportWidth: 100,
    );
    expect(overview, hasLength(2));
    expect(overview.first.startMs, 0);
    expect(overview.last.endMs, 10000);
  });

  test('invalid geometry returns no query range', () {
    expect(
      policy.visibleRange(
        durationMs: 240000,
        viewportWidth: 0,
        scrollOffset: 0,
      ),
      isNull,
    );
  });
}
