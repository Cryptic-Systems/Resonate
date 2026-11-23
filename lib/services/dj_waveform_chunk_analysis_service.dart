import 'dart:async';
import 'dart:io';

import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../dj_engine/analysis/dj_waveform_chunk_analyzer.dart';
import '../dj_engine/analysis/dj_waveform_storage_policy.dart';
import '../models/dj_analysis.dart';
import '../models/song.dart';
import 'database_helper.dart';
import 'dj_bpm_estimator.dart';
import 'resonate_diagnostics.dart';

/// Serial, bounded Phase B producer for persistent measured waveform chunks.
///
/// The caller must invoke this only from an approved idle-analysis context.
/// It does not schedule itself, touch playback, or run when the Console opens.
class DjWaveformChunkAnalysisService {
  DjWaveformChunkAnalysisService({
    DatabaseHelper? database,
    DjBpmEstimator? estimator,
    DjWaveformChunkPeakAnalyzer peakAnalyzer =
        const DjWaveformChunkPeakAnalyzer(),
  })  : _db = database ?? DatabaseHelper(),
        _estimator = estimator ?? DjBpmEstimator(),
        _peakAnalyzer = peakAnalyzer;

  static const int chunkDurationMs = 8000;
  static const int _maxChunksPerRun = 4;

  final DatabaseHelper _db;
  final DjBpmEstimator _estimator;
  final DjWaveformChunkPeakAnalyzer _peakAnalyzer;
  final DjWaveformStoragePolicy _policy = const DjWaveformStoragePolicy();

  bool _running = false;
  int _generation = 0;

  bool get isRunning => _running;

  /// Processes at most [maxChunks] missing chunks, one decoder request at a
  /// time. A failed chunk stops this batch and remains eligible for retry.
  Future<int> processMissingChunks(
    Song song, {
    int maxChunks = 2,
    required bool Function() isStillIdle,
  }) async {
    if (_running || song.filePath.trim().isEmpty) return 0;
    final durationMs = song.duration.inMilliseconds;
    if (durationMs <= 0) return 0;

    final expected = (durationMs + chunkDurationMs - 1) ~/ chunkDurationMs;
    if (expected <= 0 || expected > DjWaveformStoragePolicy.maxChunksPerTrack) {
      return 0;
    }

    _running = true;
    final generation = _generation;
    bool cancelled() => generation != _generation || !isStillIdle();

    try {
      final analysis = await _db.getDjAnalysis(song.id);
      if (cancelled()) return 0;
      final fingerprint = await _sourceFingerprint(song.filePath, analysis);
      if (cancelled()) return 0;

      final identity = DjWaveformIdentity(
        songId: song.id,
        analysisVersion: analysis?.analysisVersion ?? DjAnalysis.currentVersion,
        sourceFingerprint: fingerprint,
        durationMs: durationMs,
        schemaVersion: DjWaveformStoragePolicy.schemaVersion,
      );
      await _db.prepareDjWaveformManifest(
        identity: identity,
        expectedChunkCount: expected,
      );
      final completed = await _db.getDjWaveformCompletedIndices(
        identity: identity,
        expectedChunkCount: expected,
      );

      final budget = maxChunks.clamp(1, _maxChunksPerRun);
      var processed = 0;
      for (var index = 0; index < expected && processed < budget; index++) {
        if (cancelled()) break;
        if (completed.contains(index)) continue;

        final requestedStart = index * chunkDurationMs;
        final requestedEnd = (requestedStart + chunkDurationMs)
            .clamp(0, durationMs)
            .toInt();
        final seconds = (requestedEnd - requestedStart) / 1000.0;
        if (seconds <= 0) continue;

        final decoded = await _estimator.extractDecodedPcmWindow(
          song.filePath,
          maxSeconds: seconds,
          startMs: requestedStart,
        );
        if (cancelled()) break;
        if (decoded == null) {
          await ResonateDiagnostics.recordDj(
            stage: 'waveform_chunk',
            songId: song.id,
            outcome: 'retryable_decode_failure',
            extra: {'chunkIndex': index, 'requestedStartMs': requestedStart},
          );
          break;
        }

        final peaks = _peakAnalyzer.analyze(
          pcm: decoded.pcm,
          sampleRate: decoded.sampleRate,
          channels: decoded.channels,
        );
        final actualStart = decoded.startMs;
        final actualEnd = DjWaveformChunkPeakAnalyzer.measuredEndMs(
          startMs: actualStart,
          pcmByteLength: decoded.pcm.length,
          sampleRate: decoded.sampleRate,
          channels: decoded.channels,
          durationMs: durationMs,
        );
        // Drop the only decoded PCM reference before any subsequent decode.
        final pcmLength = decoded.pcm.length;
        if (cancelled()) break;
        if (peaks == null ||
            actualStart < 0 ||
            actualEnd <= actualStart ||
            actualEnd <= requestedStart ||
            actualStart >= requestedEnd) {
          await ResonateDiagnostics.recordDj(
            stage: 'waveform_chunk',
            songId: song.id,
            outcome: 'retryable_invalid_window',
            extra: {'chunkIndex': index, 'pcmBytes': pcmLength},
          );
          break;
        }

        final chunk = DjWaveformChunk(
          songId: song.id,
          analysisVersion: identity.analysisVersion,
          chunkIndex: index,
          requestedStartMs: requestedStart,
          requestedEndMs: requestedEnd,
          actualStartMs: actualStart,
          actualEndMs: actualEnd,
          sourceFingerprint: fingerprint,
          durationMs: durationMs,
          schemaVersion: identity.schemaVersion,
          sampleRate: decoded.sampleRate,
          channels: decoded.channels,
          peaks: peaks,
          completedAt: DateTime.now(),
        );
        if (!_policy.canReuseChunk(identity: identity, chunk: chunk) ||
            cancelled()) {
          break;
        }
        await _db.upsertDjWaveformChunk(
          chunk: chunk,
          expectedChunkCount: expected,
        );
        processed++;
        await ResonateDiagnostics.recordDj(
          stage: 'waveform_chunk',
          songId: song.id,
          outcome: 'persisted',
          extra: {
            'chunkIndex': index,
            'actualStartMs': actualStart,
            'actualEndMs': actualEnd,
            'peakCount': peaks.length,
            'pcmBytesDiscarded': pcmLength,
            'expectedChunkCount': expected,
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      return processed;
    } catch (error) {
      await ResonateDiagnostics.recordDj(
        stage: 'waveform_chunk_error',
        songId: song.id,
        outcome: 'failed',
        reason: error.toString(),
      );
      return 0;
    } finally {
      _running = false;
    }
  }

  /// Invalidates the current job. In-flight MediaCodec work settles
  /// cooperatively; stale output is discarded before persistence.
  void cancel() {
    _generation++;
    // ignore: unawaited_futures
    _estimator.cancelNativePcmAnalysis();
  }

  Future<String?> _sourceFingerprint(
    String path,
    DjAnalysis? analysis,
  ) async {
    if (!path.startsWith('content://') && !path.startsWith('file://')) {
      try {
        final file = File(path);
        if (await file.exists()) return 'bytes:${await file.length()}';
      } catch (_) {}
    }
    // Content URIs may not expose a filesystem stat. Use the last verified
    // MediaStore size when available; null remains a conservative identity.
    final size = analysis?.fileSizeBytes;
    return size == null ? null : 'bytes:$size';
  }
}
