import 'package:flutter_test/flutter_test.dart';
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
