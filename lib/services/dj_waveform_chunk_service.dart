import 'dart:io';

import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../dj_engine/analysis/dj_waveform_pcm_encoder.dart';
import '../dj_engine/analysis/dj_waveform_storage_policy.dart';
import '../models/dj_analysis.dart';
import '../models/song.dart';
import 'database_helper.dart';
import 'dj_bpm_estimator.dart';

enum DjWaveformBuildStatus { completed, partial, paused, busy, unsupported }

class DjWaveformBuildResult {
  final DjWaveformBuildStatus status;
  final int attemptedChunks;
  final int savedChunks;
  final int failedChunks;
  final int remainingChunks;

  const DjWaveformBuildResult({
    required this.status,
    required this.attemptedChunks,
    required this.savedChunks,
    required this.failedChunks,
    required this.remainingChunks,
  });
}

/// Phase B: serial, resumable waveform chunk extraction.
///
/// This service deliberately has no playback or UI dependencies. Callers must
/// supply an idle-eligibility predicate; it is checked before every decode,
/// after every decode, and immediately before persistence. Phase D owns
/// automatic scheduling and lifecycle integration.
class DjWaveformChunkService {
  DjWaveformChunkService({
    DatabaseHelper? database,
    DjBpmEstimator? estimator,
    DjWaveformPcmEncoder encoder = const DjWaveformPcmEncoder(),
  })  : _db = database ?? DatabaseHelper(),
        _estimator = estimator ?? DjBpmEstimator(),
        _encoder = encoder;

  static const int chunkDurationMs = 8000;
  static const int maxChunksPerRun = 4;
  static bool _workerActive = false;

  final DatabaseHelper _db;
  final DjBpmEstimator _estimator;
  final DjWaveformPcmEncoder _encoder;
  final DjWaveformStoragePolicy _policy = const DjWaveformStoragePolicy();
  int _generation = 0;

  /// Invalidates this service's current run. An in-flight MediaCodec operation
  /// is cooperative-cancelled and still must settle before another decode.
  void cancel() {
    _generation++;
    _estimator.cancelNativePcmAnalysis();
  }

  Future<DjWaveformBuildResult> buildMissingChunks(
    Song song, {
    required bool Function() isEligible,
    int chunkBudget = maxChunksPerRun,
  }) async {
    if (_workerActive) {
      return const DjWaveformBuildResult(
        status: DjWaveformBuildStatus.busy,
        attemptedChunks: 0,
        savedChunks: 0,
        failedChunks: 0,
        remainingChunks: 0,
      );
    }
    if (!isEligible()) {
      return const DjWaveformBuildResult(
        status: DjWaveformBuildStatus.paused,
        attemptedChunks: 0,
        savedChunks: 0,
        failedChunks: 0,
        remainingChunks: 0,
      );
    }

    final durationMs = song.duration.inMilliseconds;
    if (song.id.trim().isEmpty || durationMs <= 0) {
      return const DjWaveformBuildResult(
        status: DjWaveformBuildStatus.unsupported,
        attemptedChunks: 0,
        savedChunks: 0,
        failedChunks: 0,
        remainingChunks: 0,
      );
    }

    final expectedCount = (durationMs + chunkDurationMs - 1) ~/ chunkDurationMs;
    if (expectedCount <= 0 ||
        expectedCount > DjWaveformStoragePolicy.maxChunksPerTrack) {
      return const DjWaveformBuildResult(
        status: DjWaveformBuildStatus.unsupported,
        attemptedChunks: 0,
        savedChunks: 0,
        failedChunks: 0,
        remainingChunks: 0,
      );
    }

    _workerActive = true;
    final generation = _generation;
    var attempted = 0;
    var saved = 0;
    var failed = 0;
    try {
      final fingerprint = await _sourceFingerprint(song, durationMs);
      final identity = DjWaveformIdentity(
        songId: song.id,
        analysisVersion: DjAnalysis.currentVersion,
        sourceFingerprint: fingerprint,
        durationMs: durationMs,
        schemaVersion: DjWaveformStoragePolicy.schemaVersion,
      );
      if (_cancelled(generation) || !isEligible()) {
        return _result(DjWaveformBuildStatus.paused, attempted, saved, failed, expectedCount);
      }

      await _db.prepareDjWaveformManifest(
        identity: identity,
        expectedChunkCount: expectedCount,
      );
      final completed = await _db.getDjWaveformCompletedIndices(
        identity: identity,
        expectedChunkCount: expectedCount,
      );
      final budget = chunkBudget.clamp(1, 8).toInt();

      for (var index = 0; index < expectedCount && attempted < budget; index++) {
        if (completed.contains(index)) continue;
        if (_cancelled(generation) || !isEligible()) {
          return _result(
            DjWaveformBuildStatus.paused,
            attempted,
            saved,
            failed,
            expectedCount - completed.length - saved,
          );
        }

        final requestedStartMs = index * chunkDurationMs;
        final requestedEndMs =
            (requestedStartMs + chunkDurationMs).clamp(0, durationMs).toInt();
        attempted++;

        // The native handler owns a single-thread decoder. Await this exact
        // operation; never timeout and start a second decode beside it.
        final decoded = await _estimator.extractDecodedPcmWindow(
          song.filePath,
          maxSeconds: (requestedEndMs - requestedStartMs) / 1000.0,
          startMs: requestedStartMs,
        );

        if (_cancelled(generation) || !isEligible()) {
          // The returned PCM is intentionally discarded on a stop/foreground
          // transition; no stale chunk or manifest completion is written.
          return _result(
            DjWaveformBuildStatus.paused,
            attempted,
            saved,
            failed,
            expectedCount - completed.length - saved,
          );
        }
        if (decoded == null) {
          failed++;
          continue;
        }

        final encoded = _encoder.encode(
          pcm: decoded.pcm,
          sampleRate: decoded.sampleRate,
          channels: decoded.channels,
          decodedStartMs: decoded.startMs,
          requestedStartMs: requestedStartMs,
          requestedEndMs: requestedEndMs,
          durationMs: durationMs,
        );
        if (encoded == null) {
          failed++;
          continue;
        }

        final chunk = DjWaveformChunk(
          songId: song.id,
          analysisVersion: DjAnalysis.currentVersion,
          chunkIndex: index,
          requestedStartMs: requestedStartMs,
          requestedEndMs: requestedEndMs,
          actualStartMs: encoded.actualStartMs,
          actualEndMs: encoded.actualEndMs,
          sourceFingerprint: fingerprint,
          durationMs: durationMs,
          schemaVersion: DjWaveformStoragePolicy.schemaVersion,
          sampleRate: decoded.sampleRate,
          channels: decoded.channels,
          peaks: encoded.peaks,
          completedAt: DateTime.now(),
        );
        if (!_policy.isValidChunk(chunk) ||
            _cancelled(generation) ||
            !isEligible()) {
          failed++;
          continue;
        }

        // Fence the write against a file replacement that happened while
        // MediaCodec was decoding this window.
        final currentFingerprint = await _sourceFingerprint(song, durationMs);
        if (currentFingerprint != fingerprint ||
            _cancelled(generation) ||
            !isEligible()) {
          return _result(
            DjWaveformBuildStatus.paused,
            attempted,
            saved,
            failed,
            expectedCount - completed.length - saved,
          );
        }

        await _db.upsertDjWaveformChunk(
          chunk: chunk,
          expectedChunkCount: expectedCount,
        );
        completed.add(index);
        saved++;
        // Give the event loop a chance to service UI and lifecycle work.
        await Future<void>.delayed(Duration.zero);
      }

      final remaining = expectedCount - completed.length;
      return _result(
        remaining == 0 && failed == 0
            ? DjWaveformBuildStatus.completed
            : DjWaveformBuildStatus.partial,
        attempted,
        saved,
        failed,
        remaining,
      );
    } finally {
      _workerActive = false;
    }
  }

  bool _cancelled(int generation) => generation != _generation;

  DjWaveformBuildResult _result(
    DjWaveformBuildStatus status,
    int attempted,
    int saved,
    int failed,
    int remaining,
  ) =>
      DjWaveformBuildResult(
        status: status,
        attemptedChunks: attempted,
        savedChunks: saved,
        failedChunks: failed,
        remainingChunks: remaining < 0 ? 0 : remaining,
      );

  Future<String> _sourceFingerprint(Song song, int durationMs) async {
    int? size;
    try {
      final path = song.filePath;
      if (!path.contains('://')) {
        final file = File(path);
        if (await file.exists()) size = await file.length();
      } else if (path.startsWith('file://')) {
        final file = File(Uri.parse(path).toFilePath());
        if (await file.exists()) size = await file.length();
      }
    } catch (_) {
      // Content URIs may not expose a filesystem size. The stable song URI
      // and duration remain part of the fingerprint in that case.
    }

    final source = '${song.filePath}|$size|$durationMs';
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
