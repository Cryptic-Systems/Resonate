import 'dart:math' as math;
import 'dart:typed_data';

/// A compact envelope produced from one validated PCM16 decoder window.
class DjWaveformEncodedWindow {
  final int actualStartMs;
  final int actualEndMs;
  final List<double> peaks;

  const DjWaveformEncodedWindow({
    required this.actualStartMs,
    required this.actualEndMs,
    required this.peaks,
  });
}

/// Converts exactly one bounded PCM16 window into measured peak bins.
/// It crops decoder preroll and never fills samples outside the requested range.
class DjWaveformPcmEncoder {
  static const int maxPcmBytes = 8 * 1024 * 1024;
  static const int maxBins = 192;

  const DjWaveformPcmEncoder();

  DjWaveformEncodedWindow? encode({
    required Uint8List pcm,
    required int sampleRate,
    required int channels,
    required int decodedStartMs,
    required int requestedStartMs,
    required int requestedEndMs,
    required int durationMs,
  }) {
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        channels < 1 ||
        channels > 8 ||
        decodedStartMs < 0 ||
        requestedStartMs < 0 ||
        requestedEndMs <= requestedStartMs ||
        requestedEndMs > durationMs ||
        durationMs <= 0 ||
        pcm.isEmpty ||
        pcm.length > maxPcmBytes) {
      return null;
    }

    final bytesPerFrame = channels * 2;
    if (pcm.length % bytesPerFrame != 0) return null;
    final frameCount = pcm.length ~/ bytesPerFrame;
    if (frameCount < 2) return null;

    final decodedEndMs =
        decodedStartMs + (frameCount * 1000 ~/ sampleRate);
    final overlapStartMs = math.max(decodedStartMs, requestedStartMs);
    final overlapEndMs = math.min(decodedEndMs, requestedEndMs);
    if (overlapEndMs <= overlapStartMs) return null;

    // Round the first frame up so preroll before the requested range is excluded.
    final firstFrame = math.max(
      0,
      ((overlapStartMs - decodedStartMs) * sampleRate + 999) ~/ 1000,
    );
    // Round the exclusive end down; never include samples past requestedEndMs.
    final endFrame = math.min(
      frameCount,
      ((overlapEndMs - decodedStartMs) * sampleRate) ~/ 1000,
    );
    final selectedFrames = endFrame - firstFrame;
    if (selectedFrames < 2) return null;

    final actualStartMs =
        decodedStartMs + (firstFrame * 1000 + sampleRate - 1) ~/ sampleRate;
    final actualEndMs =
        decodedStartMs + (endFrame * 1000) ~/ sampleRate;
    if (actualEndMs <= actualStartMs ||
        actualStartMs < requestedStartMs ||
        actualEndMs > requestedEndMs ||
        actualEndMs > durationMs) {
      return null;
    }

    final binCount = math.min(maxBins, selectedFrames);
    final peaks = List<double>.filled(binCount, 0);
    final data = ByteData.sublistView(pcm);
    for (var frame = 0; frame < selectedFrames; frame++) {
      final bin = math.min(
        binCount - 1,
        frame * binCount ~/ selectedFrames,
      );
      final sourceFrame = firstFrame + frame;
      for (var channel = 0; channel < channels; channel++) {
        final sample = data.getInt16(
          sourceFrame * bytesPerFrame + channel * 2,
          Endian.little,
        );
        final magnitude = (sample / 32768.0).abs();
        if (magnitude > peaks[bin]) peaks[bin] = magnitude;
      }
    }

    if (peaks.any((peak) => !peak.isFinite || peak < 0 || peak > 1)) {
      return null;
    }
    return DjWaveformEncodedWindow(
      actualStartMs: actualStartMs,
      actualEndMs: actualEndMs,
      peaks: List<double>.unmodifiable(peaks),
    );
  }
}
