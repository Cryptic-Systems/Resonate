import 'dart:io';

import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../dj_engine/analysis/dj_waveform_storage_policy.dart';
import '../models/dj_analysis.dart';
import '../models/song.dart';
import 'database_helper.dart';

/// Read-only Phase C adapter. It never schedules or starts PCM analysis.
class DjWaveformRangeReader {
  DjWaveformRangeReader({DatabaseHelper? database})
      : _database = database ?? DatabaseHelper();

  final DatabaseHelper _database;

  Future<List<DjWaveformChunk>> loadVisibleRange(
    Song song, {
    required int startMs,
    required int endMs,
    int overscanChunks = DjWaveformStoragePolicy.maxOverscanChunks,
  }) async {
    final durationMs = song.duration.inMilliseconds;
    if (song.id.trim().isEmpty || durationMs <= 0) {
      return const <DjWaveformChunk>[];
    }
    final fingerprint = await _sourceFingerprint(song, durationMs);
    final identity = DjWaveformIdentity(
      songId: song.id,
      analysisVersion: DjAnalysis.currentVersion,
      sourceFingerprint: fingerprint,
      durationMs: durationMs,
      schemaVersion: DjWaveformStoragePolicy.schemaVersion,
    );
    return _database.getDjWaveformChunksInRange(
      identity: identity,
      startMs: startMs,
      endMs: endMs,
      overscanChunks: overscanChunks,
    );
  }

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
      // Some content providers do not expose filesystem metadata.
    }
    final source = '${song.filePath}|$size|$durationMs';
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
