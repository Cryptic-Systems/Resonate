/// Deterministic viewport-to-chunk mapping for the DJ Console waveform.
class DjWaveformViewportRange {
  const DjWaveformViewportRange({
    required this.startMs,
    required this.endMs,
    required this.contentWidth,
  });

  final int startMs;
  final int endMs;
  final double contentWidth;
}

class DjWaveformViewportPolicy {
  const DjWaveformViewportPolicy({
    this.chunkDurationMs = 8000,
    this.pixelsPerSecond = 3.0,
  });

  final int chunkDurationMs;
  final double pixelsPerSecond;

  DjWaveformViewportRange? visibleRange({
    required int durationMs,
    required double viewportWidth,
    required double scrollOffset,
  }) {
    if (durationMs <= 0 ||
        viewportWidth <= 0 ||
        !viewportWidth.isFinite ||
        !scrollOffset.isFinite ||
        chunkDurationMs <= 0 ||
        pixelsPerSecond <= 0) {
      return null;
    }
    final contentWidth =
        (durationMs / 1000 * pixelsPerSecond).clamp(viewportWidth, double.infinity);
    final offset = scrollOffset.clamp(0.0, contentWidth - viewportWidth);
    final rawStart =
        (offset / contentWidth * durationMs).floor().clamp(0, durationMs);
    final rawEnd = ((offset + viewportWidth) / contentWidth * durationMs)
        .ceil()
        .clamp(0, durationMs);
    final startMs =
        ((rawStart ~/ chunkDurationMs) * chunkDurationMs).clamp(0, durationMs);
    final endMs = (((rawEnd + chunkDurationMs - 1) ~/ chunkDurationMs) *
            chunkDurationMs)
        .clamp(0, durationMs);
    return DjWaveformViewportRange(
      startMs: startMs.toInt(),
      endMs: endMs.toInt(),
      contentWidth: contentWidth.toDouble(),
    );
  }
}
