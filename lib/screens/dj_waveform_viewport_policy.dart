/// Full-track overview mapping for the DJ Console waveform.
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
    this.pixelsPerSecond = 0.0,
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
    // The deck overview always represents the complete track at once.
    // All persisted 8-second chunks are fetched and compressed into the
    // available width, just like a DJ overview waveform. Zoomed scrolling
    // waveforms can be added as a separate mode without hiding track sections.
    const contentWidth = 0.0;
    return DjWaveformViewportRange(
      startMs: 0,
      endMs: durationMs,
      contentWidth: viewportWidth,
    );
  }
}
