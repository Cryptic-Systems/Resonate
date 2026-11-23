import 'dart:io';

import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../dj_engine/analysis/dj_waveform_storage_policy.dart';
import '../models/dj_analysis.dart';
import '../models/song.dart';
import 'database_helper.dart';
import 'dj_waveform_chunk_lru.dart';

/// Read-only Phase C adapter. It never schedules or starts PCM analysis.
class DjWaveformRangeReader {
  DjWaveformRangeReader({DatabaseHelper? database})
      : _database = database ?? DatabaseHelper();

  final DatabaseHelper _database;
  final DjWaveformChunkLru _cache = DjWaveformChunkLru();

  Future<List<DjWaveformChunk>> loadVisibleRange(
    Song song, {
    required int startMs,
    required int endMs,
    int overscanChunks = DjWaveformStoragePolicy.maxOverscanChunks,
  }) async {
    final durationMs = song.duration.inMilliseconds;
    if (song.id.trim().isEmpty ||
        durationMs <= 0 ||
        startMs < 0 ||
        endMs <= startMs ||
        startMs >= durationMs) {
      return const <DjWaveformChunk>[];
    }
    // Use the same persisted analysis version and source fingerprint as the
    // chunk producer. A different identity must fail closed, not look empty.
    final analysis = await _database.getDjAnalysis(song.id);
    final fingerprint = await _sourceFingerprint(song.filePath, analysis);
    if (fingerprint == null) return const <DjWaveformChunk>[];
    final identity = DjWaveformIdentity(
      songId: song.id,
      analysisVersion: (analysis?.analysisVersion ?? 0) > 0
          ? analysis!.analysisVersion
          : DjAnalysis.currentVersion,
      sourceFingerprint: fingerprint,
      durationMs: durationMs,
      schemaVersion: DjWaveformStoragePolicy.schemaVersion,
    );
    final boundedStartMs = startMs.clamp(0, durationMs).toInt();
    final boundedEndMs = endMs.clamp(0, durationMs).toInt();
    if (boundedEndMs <= boundedStartMs) return const <DjWaveformChunk>[];
    const chunkDurationMs = 8000;
    final boundedOverscan =
        DjWaveformStoragePolicy().boundedOverscan(overscanChunks);
    final firstIndex =
        (boundedStartMs ~/ chunkDurationMs - boundedOverscan).clamp(0, DjWaveformStoragePolicy.maxChunksPerTrack - 1).toInt();
    final lastIndex =
        (((boundedEndMs - 1) ~/ chunkDurationMs) + boundedOverscan)
            .clamp(firstIndex, DjWaveformStoragePolicy.maxChunksPerTrack - 1).toInt();
    final cached = <DjWaveformChunk>[];
    var fullyCached = true;
    for (var index = firstIndex; index <= lastIndex; index++) {
      final chunk = _cache.get(identity, index);
      if (chunk == null) {
        fullyCached = false;
        break;
      }
      cached.add(chunk);
    }
    if (fullyCached) return List<DjWaveformChunk>.unmodifiable(cached);

    final loaded = await _database.getDjWaveformChunksInRange(
      identity: identity,
      startMs: startMs,
      endMs: endMs,
      overscanChunks: boundedOverscan,
    );
    for (final chunk in loaded) {
      _cache.put(identity, chunk);
    }
    return loaded;
  }

  Future<String?> _sourceFingerprint(
    String path,
    DjAnalysis? analysis,
  ) async {
    if (!path.startsWith('content://')) {
      try {
        final localPath =
            path.startsWith('file://') ? Uri.parse(path).toFilePath() : path;
        final file = File(localPath);
        if (await file.exists()) {
          final stat = await file.stat();
          return 'local:${file.absolute.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
        }
      } catch (_) {}
    }
    // Match the producer's MediaStore identity exactly. Without indexed size,
    // the stored chunk cannot be safely associated with this source.
    final size = analysis?.fileSizeBytes;
    return size == null || size <= 0 ? null : 'mediastore:$path:$size';
  }
}
