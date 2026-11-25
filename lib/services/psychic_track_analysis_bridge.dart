import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../dj_engine/analysis/dj_pcm_profile_analyzer.dart';
import '../models/song.dart';

/// Background-only bridge to Psychic's native sampled-window track analyzer/cache.
/// It consumes the same distributed PCM windows already decoded for DJ
/// profiling; it never touches the live Media3 audio callback.
class PsychicTrackAnalysisBridge {
  static const MethodChannel _channel =
      MethodChannel('com.aetherion.resonate/media_store');

  static Future<Map<String, dynamic>?> analyze(
    Song song,
    List<DjDecodedPcmWindow> windows,
  ) async {
    if (!Platform.isAndroid || windows.isEmpty) return null;
    final rms = <double>[];
    final peak = <double>[];
    final bass = <double>[];
    final durations = <double>[];

    for (final window in windows) {
      if (window.sampleRate < 8000 ||
          window.channels < 1 ||
          window.channels > 8) {
        continue;
      }
      final frameBytes = window.channels * 2;
      final frames = window.pcm.length ~/ frameBytes;
      if (frames < 4) continue;
      final data = ByteData.sublistView(window.pcm);
      final filterState = List<double>.filled(window.channels, 0);
      final alpha = math.exp(
        -2 * math.pi * 120 / window.sampleRate,
      );
      var squareSum = 0.0;
      var bassSquareSum = 0.0;
      var samplePeak = 0.0;
      var sampleCount = 0;

      for (var frame = 0; frame < frames; frame++) {
        for (var channel = 0; channel < window.channels; channel++) {
          final sample = data.getInt16(
                frame * frameBytes + channel * 2,
                Endian.little,
              ) /
              32768.0;
          squareSum += sample * sample;
          samplePeak = math.max(samplePeak, sample.abs());
          final low = (1 - alpha) * sample +
              alpha * filterState[channel];
          filterState[channel] = low;
          bassSquareSum += low * low;
          sampleCount++;
        }
      }
      if (sampleCount == 0) continue;
      double toDb(double power) =>
          power > 1e-24 ? 10 * math.log(power) / math.ln10 : -120;
      rms.add(toDb(squareSum / sampleCount));
      peak.add(samplePeak > 1e-12
          ? 20 * math.log(samplePeak) / math.ln10
          : -120);
      bass.add(toDb(bassSquareSum / sampleCount));
      durations.add(frames / window.sampleRate);
    }
    if (rms.isEmpty) return null;

    var fileSizeBytes = 0;
    var modifiedTimeNs = 0;
    try {
      if (!song.filePath.startsWith('content://') &&
          !song.filePath.startsWith('file://')) {
        final stat = await File(song.filePath).stat();
        fileSizeBytes = stat.size;
        modifiedTimeNs = stat.modified.microsecondsSinceEpoch * 1000;
      }
    } catch (_) {
      // MediaStore content URIs retain a stable song id; revision metadata is
      // optional when Android does not expose a filesystem stat.
    }

    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'psychicAnalyzeTrackMetrics',
        {
          'stableId': song.id,
          'fileSizeBytes': fileSizeBytes,
          'modifiedTimeNs': modifiedTimeNs,
          'rmsValues': rms,
          'peakValues': peak,
          'bassValues': bass,
          'durations': durations,
        },
      );
      if (raw == null || raw.length < 26) return null;
      final values = raw.map((value) => (value as num).toDouble()).toList();
      final findings = <Map<String, dynamic>>[];
      final findingCount = values[13].round().clamp(0, 6);
      for (var i = 0; i < findingCount; i++) {
        findings.add({
          'trait': values[14 + i * 2].round(),
          'confidence': values[15 + i * 2],
        });
      }
      return {
        'engine': 'Psychic',
        'version': '0.6.1',
        'cacheHit': values[0] >= 0.5,
        'sampledDurationSeconds': values[1],
        'activeSeconds': values[2],
        'silenceSeconds': values[3],
        'integratedRmsDb': values[4],
        'bassRmsDb': values[5],
        'bassProminenceDb': values[6],
        'samplePeakDb': values[7],
        'meanCrestDb': values[8],
        'crestP90Db': values[9],
        'loudnessRangeDb': values[10],
        'highCrestSecondsRatio': values[11],
        'sufficientData': values[12] >= 0.5,
        'findings': findings,
        'windowCount': rms.length,
      };
    } on PlatformException catch (error) {
      debugPrint('Psychic background analysis bridge failed: ${error.code} ${error.message}');
      return null;
    } catch (error) {
      debugPrint('Psychic background analysis bridge failed: $error');
      return null;
    }
  }

  static Future<Map<String, int>> cacheStats() async {
    if (!Platform.isAndroid) return const {};
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'psychicTrackCacheStats',
      );
      if (raw == null || raw.length < 5) return const {};
      return {
        'entries': (raw[0] as num).toInt(),
        'capacity': (raw[1] as num).toInt(),
        'hits': (raw[2] as num).toInt(),
        'misses': (raw[3] as num).toInt(),
        'invalidationsAndEvictions': (raw[4] as num).toInt(),
      };
    } catch (error) {
      debugPrint('Psychic cache stats unavailable: $error');
      return const {};
    }
  }
}
