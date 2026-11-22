import 'dj_waveform_chunk.dart';

/// Pure guardrails for Phase A waveform storage and cache policy.
class DjWaveformStoragePolicy {
  static const int schemaVersion = 1;
  static const int maxPeaksPerChunk = 256;
  static const int maxChunksPerTrack = 2250;
  static const int maxCacheChunks = 96;
  static const int maxCacheBytes = 256 * 1024;
  static const int maxOverscanChunks = 2;

  const DjWaveformStoragePolicy();

  bool isValidChunk(DjWaveformChunk chunk) {
    if (chunk.songId.trim().isEmpty ||
        chunk.analysisVersion <= 0 ||
        chunk.chunkIndex < 0 ||
        chunk.chunkIndex >= maxChunksPerTrack ||
        chunk.durationMs <= 0 ||
        chunk.schemaVersion != schemaVersion ||
        chunk.requestedStartMs < 0 ||
        chunk.requestedEndMs <= chunk.requestedStartMs ||
        chunk.requestedEndMs > chunk.durationMs ||
        chunk.actualStartMs < 0 ||
        chunk.actualEndMs <= chunk.actualStartMs ||
        chunk.actualEndMs > chunk.durationMs ||
        chunk.sampleRate <= 0 ||
        chunk.channels <= 0 ||
        chunk.channels > 8 ||
        chunk.peaks.isEmpty ||
        chunk.peaks.length > maxPeaksPerChunk) {
      return false;
    }
    if (chunk.actualEndMs <= chunk.requestedStartMs ||
        chunk.actualStartMs >= chunk.requestedEndMs) {
      return false;
    }
    return chunk.peaks.every(
      (peak) => peak.isFinite && peak >= 0 && peak <= 1,
    );
  }

  bool canReuseChunk({
    required DjWaveformIdentity identity,
    required DjWaveformChunk chunk,
  }) =>
      isValidChunk(chunk) &&
      identity.matches(chunk, expectedSchemaVersion: schemaVersion);

  bool isManifestComplete(DjWaveformManifest manifest) {
    if (manifest.expectedChunkCount <= 0 ||
        manifest.expectedChunkCount > maxChunksPerTrack ||
        manifest.completedChunkIndices.any(
          (index) => index < 0 || index >= manifest.expectedChunkCount,
        )) {
      return false;
    }
    return manifest.isComplete;
  }

  /// Returns the retained cache size after adding a chunk, evicting oldest
  /// entries first. This is a deterministic budget calculation, not storage IO.
  int retainedCacheCount({
    required List<int> payloadByteSizes,
    required int incomingPayloadBytes,
  }) {
    if (incomingPayloadBytes < 0) return payloadByteSizes.length;
    if (incomingPayloadBytes > maxCacheBytes) return 0;
    var count = 1;
    var bytes = incomingPayloadBytes;
    for (final size in payloadByteSizes.reversed) {
      if (size < 0) continue;
      if (count >= maxCacheChunks || bytes + size > maxCacheBytes) break;
      count++;
      bytes += size;
    }
    return count;
  }

  int boundedOverscan(int requested) =>
      requested.clamp(0, maxOverscanChunks).toInt();
}
