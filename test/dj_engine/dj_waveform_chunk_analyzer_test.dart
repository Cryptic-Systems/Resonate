import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/analysis/dj_waveform_chunk_analyzer.dart';

void main() {
  const analyzer = DjWaveformChunkPeakAnalyzer();

  test('measures peak across channels and keeps bounded envelope', () {
    final pcm = Uint8List.fromList([
      0, 0, 0, 0,
      0, 64, 0, 0,
      0, 0, 0, 128,
      0, 0, 0, 0,
    ]);
    final peaks = analyzer.analyze(
      pcm: pcm,
      sampleRate: 44100,
      channels: 2,
      maxPeaks: 2,
    );
    expect(peaks, isNotNull);
    expect(peaks, hasLength(2));
    expect(peaks!.first, greaterThan(0.49));
    expect(peaks.last, 1.0);
  });

  test('rejects malformed PCM and unsupported channel metadata', () {
    expect(
      analyzer.analyze(
        pcm: Uint8List.fromList([1, 2, 3]),
        sampleRate: 44100,
        channels: 2,
      ),
      isNull,
    );
    expect(
      analyzer.analyze(
        pcm: Uint8List(32),
        sampleRate: 44100,
        channels: 9,
      ),
      isNull,
    );
  });

  test('measured end uses actual frame count and clamps to duration', () {
    expect(
      DjWaveformChunkPeakAnalyzer.measuredEndMs(
        startMs: 12000,
        pcmByteLength: 44100 * 2 * 2,
        sampleRate: 44100,
        channels: 2,
        durationMs: 30000,
      ),
      13000,
    );
    expect(
      DjWaveformChunkPeakAnalyzer.measuredEndMs(
        startMs: 29000,
        pcmByteLength: 44100 * 2 * 4,
        sampleRate: 44100,
        channels: 2,
        durationMs: 30000,
      ),
      30000,
    );
  });
}
