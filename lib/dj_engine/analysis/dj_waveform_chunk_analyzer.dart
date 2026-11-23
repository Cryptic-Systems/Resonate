import 'dart:math' as math;
import 'dart:typed_data';

/// Converts one decoded PCM16 window into a bounded, measured peak envelope.
/// Returns null for malformed or unsupported PCM; it never fabricates silence.
class DjWaveformChunkPeakAnalyzer {
  const DjWaveformChunkPeakAnalyzer();

  List<double>? analyze({
    required Uint8List pcm,
    required int sampleRate,
    required int channels,
    int maxPeaks = 192,
  }) {
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        channels < 1 ||
        channels > 8 ||
        maxPeaks < 1 ||
        maxPeaks > 256) {
      return null;
    }
    final bytesPerFrame = channels * 2;
    if (pcm.length < bytesPerFrame * 2 || pcm.length % bytesPerFrame != 0) {
      return null;
    }
    final frameCount = pcm.length ~/ bytesPerFrame;
    if (frameCount < 2) return null;

    final binCount = math.min(maxPeaks, frameCount);
    final data = ByteData.sublistView(pcm);
    final peaks = <double>[];
    for (var bin = 0; bin < binCount; bin++) {
      final firstFrame = (bin * frameCount) ~/ binCount;
      final endFrame = math.max(
        firstFrame + 1,
        ((bin + 1) * frameCount) ~/ binCount,
      );
      var peak = 0.0;
      for (var frame = firstFrame; frame < endFrame; frame++) {
        final base = frame * bytesPerFrame;
        for (var channel = 0; channel < channels; channel++) {
          final sample = data.getInt16(base + channel * 2, Endian.little);
          final magnitude = sample == -32768 ? 1.0 : sample.abs() / 32767.0;
          if (magnitude > peak) peak = magnitude;
        }
      }
      peaks.add(peak.clamp(0.0, 1.0).toDouble());
    }
    return peaks.isEmpty ? null : List<double>.unmodifiable(peaks);
  }

  static int measuredEndMs({
    required int startMs,
    required int pcmByteLength,
    required int sampleRate,
    required int channels,
    required int durationMs,
  }) {
    if (startMs < 0 ||
        sampleRate <= 0 ||
        channels <= 0 ||
        durationMs <= 0 ||
        pcmByteLength < channels * 4) {
      return startMs;
    }
    final frames = pcmByteLength ~/ (channels * 2);
    // Round the exclusive end boundary upward: a partial final millisecond
    // still contains real decoded PCM and must not leave a false 1 ms gap.
    final durationMs = (frames * 1000 + sampleRate - 1) ~/ sampleRate;
    final end = startMs + durationMs;
    return end.clamp(0, durationMs).toInt();
  }
}
