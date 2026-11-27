import '../dj_engine/core/dj_types.dart';

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
  const DjWaveformViewportPolicy();

  static const int chunkDurationMs = 8000;

  DjWaveformViewportRange? visibleRange({
    required int durationMs,
    required double viewportWidth,
    required double scrollOffset,
  }) {
    if (durationMs <= 0 ||
        viewportWidth <= 0 ||
        !viewportWidth.isFinite ||
        !scrollOffset.isFinite ||
        chunkDurationMs <= 0) {
      return null;
    }
    // The deck overview always represents the complete track at once.
    // All persisted 8-second chunks are fetched and compressed into the
    // available width, just like a DJ overview waveform. Zoomed scrolling
    // waveforms can be added as a separate mode without hiding track sections.
    return DjWaveformViewportRange(
      startMs: 0,
      endMs: durationMs,
      contentWidth: viewportWidth,
    );
  }
  /// Compresses measured peaks to viewport resolution without inventing audio
  /// in missing intervals. This keeps very long tracks inexpensive to paint.
  List<DjWaveformSegment> overviewSegments({
    required List<DjWaveformSegment> segments,
    required int durationMs,
    required double viewportWidth,
  }) {
    if (durationMs <= 0 ||
        viewportWidth <= 0 ||
        !viewportWidth.isFinite ||
        segments.isEmpty) {
      return const <DjWaveformSegment>[];
    }
    final binCount = (viewportWidth * 1.25).ceil().clamp(1, 2048).toInt();
    final peaksByBin = List<double>.filled(binCount, 0.0);
    final covered = List<bool>.filled(binCount, false);

    for (final segment in segments) {
      final start = segment.startMs.clamp(0, durationMs).toInt();
      final end = segment.endMs.clamp(0, durationMs).toInt();
      if (end <= start || segment.peaks.isEmpty) continue;
      final span = end - start;
      for (var peakIndex = 0; peakIndex < segment.peaks.length; peakIndex++) {
        final peak = segment.peaks[peakIndex];
        if (!peak.isFinite || peak < 0) continue;
        final peakStart = start + span * peakIndex / segment.peaks.length;
        final peakEnd = start + span * (peakIndex + 1) / segment.peaks.length;
        final firstBin = (peakStart / durationMs * binCount)
            .floor()
            .clamp(0, binCount - 1)
            .toInt();
        final lastBin = ((peakEnd / durationMs * binCount).ceil() - 1)
            .clamp(firstBin, binCount - 1)
            .toInt();
        final boundedPeak = peak.clamp(0.0, 1.0).toDouble();
        for (var bin = firstBin; bin <= lastBin; bin++) {
          covered[bin] = true;
          if (boundedPeak > peaksByBin[bin]) {
            peaksByBin[bin] = boundedPeak;
          }
        }
      }
    }

    final result = <DjWaveformSegment>[];
    var index = 0;
    while (index < binCount) {
      while (index < binCount && !covered[index]) {
        index++;
      }
      if (index >= binCount) break;
      final runStart = index;
      while (index + 1 < binCount && covered[index + 1]) {
        index++;
      }
      final runEnd = index;
      result.add(DjWaveformSegment(
        startMs: (runStart * durationMs / binCount).round(),
        endMs: ((runEnd + 1) * durationMs / binCount).round(),
        peaks: List<double>.unmodifiable(
          peaksByBin.sublist(runStart, runEnd + 1),
        ),
      ));
      index++;
    }
    return List<DjWaveformSegment>.unmodifiable(result);
  }

}
