import 'dart:collection';

import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../dj_engine/analysis/dj_waveform_storage_policy.dart';

/// Read-through LRU for decoded peak envelopes only; SQLite remains canonical.
class DjWaveformChunkLru {
  DjWaveformChunkLru({
    int maxChunks = DjWaveformStoragePolicy.maxCacheChunks,
    int maxBytes = DjWaveformStoragePolicy.maxCacheBytes,
  })  : _maxChunks = maxChunks.clamp(1, DjWaveformStoragePolicy.maxCacheChunks),
        _maxBytes = maxBytes.clamp(1, DjWaveformStoragePolicy.maxCacheBytes);

  final int _maxChunks;
  final int _maxBytes;
  final LinkedHashMap<String, DjWaveformChunk> _entries =
      LinkedHashMap<String, DjWaveformChunk>();
  int _bytes = 0;

  int get length => _entries.length;
  int get estimatedBytes => _bytes;

  String _key(DjWaveformIdentity identity, int chunkIndex) =>
      '${identity.songId}:${identity.analysisVersion}:${identity.sourceFingerprint}:${identity.durationMs}:${identity.schemaVersion}:$chunkIndex';

  DjWaveformChunk? get(DjWaveformIdentity identity, int chunkIndex) {
    final key = _key(identity, chunkIndex);
    final chunk = _entries.remove(key);
    if (chunk == null) return null;
    _entries[key] = chunk;
    return chunk;
  }

  void put(DjWaveformIdentity identity, DjWaveformChunk chunk) {
    const policy = DjWaveformStoragePolicy();
    if (!policy.canReuseChunk(identity: identity, chunk: chunk)) return;
    final key = _key(identity, chunk.chunkIndex);
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= _sizeOf(previous);
    final size = _sizeOf(chunk);
    if (size > _maxBytes) return;
    while (_entries.isNotEmpty &&
        (_entries.length >= _maxChunks || _bytes + size > _maxBytes)) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey)!;
      _bytes -= _sizeOf(oldest);
    }
    _entries[key] = chunk;
    _bytes += size;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  int _sizeOf(DjWaveformChunk chunk) => 96 + chunk.estimatedPayloadBytes;
}
