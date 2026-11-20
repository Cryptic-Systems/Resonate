import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:resonate/dj_engine/dj_engine.dart';

void main() {
  test('PCM profile analyzer is codec-agnostic at the decoded PCM boundary', () {
    final analyzer = const DjPcmProfileAnalyzer();
    final profile = analyzer.analyze(
      songId: 'pcm-test',
      durationMs: 120000,
      windows: [
        DjDecodedPcmWindow(
          pcm: Uint8List(44100 * 2),
          sampleRate: 44100,
          channels: 1,
          startMs: 0,
          role: 'start',
        ),
      ],
    );

    expect(profile.songId, 'pcm-test');
    expect(profile.durationMs, 120000);
    expect(profile.hasTempo, isFalse);
    expect(profile.hasKey, isFalse);
  });

  test('empty PCM windows produce a safe profile instead of throwing', () {
    final profile = const DjPcmProfileAnalyzer().analyze(
      songId: 'empty',
      durationMs: 180000,
      windows: const [],
    );

    expect(profile.hasTempo, isFalse);
    expect(profile.hasKey, isFalse);
    expect(profile.analysisConfidence, 0);
  });

  test('PCM analyzer persists a sustained near-silent outro from measured frames', () {
    const sampleRate = 11025;
    Uint8List pcmWithAmplitude(double amplitude) {
      final bytes = ByteData(sampleRate * 10 * 2);
      final sample = (32767 * amplitude).round();
      for (var i = 0; i < sampleRate * 10; i++) {
        bytes.setInt16(i * 2, sample, Endian.little);
      }
      return bytes.buffer.asUint8List();
    }

    final profile = const DjPcmProfileAnalyzer().analyze(
      songId: 'silence-tail',
      durationMs: 180000,
      windows: [
        DjDecodedPcmWindow(
          pcm: pcmWithAmplitude(0.12),
          sampleRate: sampleRate,
          channels: 1,
          startMs: 0,
          role: 'start',
        ),
        DjDecodedPcmWindow(
          pcm: pcmWithAmplitude(0.12),
          sampleRate: sampleRate,
          channels: 1,
          startMs: 60000,
          role: 'mid',
        ),
        DjDecodedPcmWindow(
          pcm: pcmWithAmplitude(0.00001),
          sampleRate: sampleRate,
          channels: 1,
          startMs: 120000,
          role: 'end',
        ),
      ],
    );

    expect(profile.silenceRegions, hasLength(1));
    expect(profile.silenceRegions.single.startMs, 120000);
    expect(profile.silenceRegions.single.durationMs, greaterThanOrEqualTo(2000));
    expect(profile.silenceRegions.single.confidence, greaterThan(0.6));
  });

  test('PCM analyzer does not bridge sparse windows when building silence evidence', () {
    const sampleRate = 11025;
    Uint8List pcmWithAmplitude(double amplitude) {
      final bytes = ByteData(sampleRate * 10 * 2);
      final sample = (32767 * amplitude).round();
      for (var i = 0; i < sampleRate * 10; i++) {
        bytes.setInt16(i * 2, sample, Endian.little);
      }
      return bytes.buffer.asUint8List();
    }

    final profile = const DjPcmProfileAnalyzer().analyze(
      songId: 'sparse-silence',
      durationMs: 180000,
      windows: [
        DjDecodedPcmWindow(
          pcm: pcmWithAmplitude(0.12), sampleRate: sampleRate,
          channels: 1, startMs: 0, role: 'start',
        ),
        DjDecodedPcmWindow(
          pcm: pcmWithAmplitude(0.00001), sampleRate: sampleRate,
          channels: 1, startMs: 120000, role: 'end',
        ),
      ],
    );

    // The measured end window is genuinely silent, but the missing interval
    // before it must not be counted as part of that silence.
    expect(profile.silenceRegions, hasLength(1));
    expect(profile.silenceRegions.single.startMs, 120000);
    expect(profile.silenceRegions.single.endMs, lessThanOrEqualTo(130000));
  });

  test('decoded PCM produces measured peak true-peak RMS crest and bass metrics', () {
    const sampleRate = 48000;
    const amplitude = 0.5;
    final pcm = ByteData(sampleRate * 2);
    for (var i = 0; i < sampleRate; i++) {
      final sample = (math.sin(2 * math.pi * 60 * i / sampleRate) * amplitude * 32767).round();
      pcm.setInt16(i * 2, sample, Endian.little);
    }
    final profile = const DjPcmProfileAnalyzer().analyze(
      songId: 'dsp-levels',
      durationMs: 1000,
      windows: [
        DjDecodedPcmWindow(
          pcm: pcm.buffer.asUint8List(),
          sampleRate: sampleRate,
          channels: 1,
          startMs: 0,
          role: 'mid',
        ),
      ],
    );
    final metrics = profile.dspAnalysis;
    expect(metrics.isMeasured, isTrue);
    expect(metrics.isValid, isTrue);
    expect(metrics.samplePeakDb, closeTo(-6.02, 0.15));
    expect(metrics.truePeakDb, greaterThanOrEqualTo(metrics.samplePeakDb));
    expect(metrics.rmsDb, closeTo(-9.03, 0.2));
    expect(metrics.crestDb, closeTo(3.01, 0.25));
    expect(metrics.bassEnergyDb, greaterThan(-12));
    expect(metrics.bassEnergyDb, lessThan(-5));
  });

  test('digital silence has finite floor metrics and never creates NaN', () {
    const sampleRate = 16000;
    final profile = const DjPcmProfileAnalyzer().analyze(
      songId: 'dsp-silence',
      durationMs: 1000,
      windows: [
        DjDecodedPcmWindow(
          pcm: Uint8List(sampleRate * 2),
          sampleRate: sampleRate,
          channels: 1,
          startMs: 0,
        ),
      ],
    );
    expect(profile.dspAnalysis.isValid, isTrue);
    expect(profile.dspAnalysis.samplePeakDb, -160);
    expect(profile.dspAnalysis.rmsDb, -160);
    expect(profile.dspAnalysis.bassEnergyDb, -160);
  });

  test('decoded PCM contributes real spectral profile data', () {
    const sampleRate = 11025;
    final pcm = ByteData(sampleRate * 2);
    for (var i = 0; i < sampleRate; i++) {
      final sample = (math.sin(2 * math.pi * 440 * i / sampleRate) * 12000).round();
      pcm.setInt16(i * 2, sample, Endian.little);
    }
    final profile = const DjPcmProfileAnalyzer().analyze(
      songId: 'tone',
      durationMs: 1000,
      windows: [
        DjDecodedPcmWindow(
          pcm: pcm.buffer.asUint8List(),
          sampleRate: sampleRate,
          channels: 1,
          startMs: 0,
          role: 'mid',
        ),
      ],
    );
    expect(profile.spectrum.confidence, greaterThan(0));
    expect(profile.spectrum.mids, greaterThan(profile.spectrum.bass));
    expect(profile.spectrum.spectralFlux, greaterThanOrEqualTo(0));
  });

}