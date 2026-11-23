import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/screens/dj_waveform_viewport_policy.dart';

void main() {
  const policy = DjWaveformViewportPolicy();

  test('initial viewport loads only its visible chunk interval', () {
    final range = policy.visibleRange(
      durationMs: 240000,
      viewportWidth: 320,
      scrollOffset: 0,
    )!;
    expect(range.startMs, 0);
    expect(range.endMs, lessThan(240000));
    expect(range.contentWidth, 720);
  });

  test('scrolled viewport maps to aligned bounded chunk indices', () {
    final range = policy.visibleRange(
      durationMs: 240000,
      viewportWidth: 320,
      scrollOffset: 160,
    )!;
    expect(range.startMs % 8000, 0);
    expect(range.endMs % 8000, 0);
    expect(range.startMs, greaterThan(0));
    expect(range.endMs, lessThan(240000));
  });

  test('short tracks fit viewport and request the complete track', () {
    final range = policy.visibleRange(
      durationMs: 5000,
      viewportWidth: 320,
      scrollOffset: 0,
    )!;
    expect(range.startMs, 0);
    expect(range.endMs, 5000);
    expect(range.contentWidth, 320);
  });

  test('overscroll is clamped to the final visible interval', () {
    final range = policy.visibleRange(
      durationMs: 240000,
      viewportWidth: 320,
      scrollOffset: 999999,
    )!;
    expect(range.endMs, 240000);
    expect(range.startMs, lessThan(range.endMs));
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
