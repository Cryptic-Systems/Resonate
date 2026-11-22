/// Identity and bounded metadata for one persisted DJ waveform chunk.
/// PCM bytes are deliberately absent from this model.
class DjWaveformChunk {
  static const int maxPeakCount = 256;
  final String songId;
  final int analysisVersion;
  final int chunkIndex;
  final int requestedStartMs;
  final int requestedEndMs;
  final int actualStartMs;
  final int actualEndMs;
  final String? sourceFingerprint;
  final int durationMs;
  final int schemaVersion;
  final int sampleRate;
  final int channels;
  final List<double> peaks;
  final DateTime completedAt;

  const DjWaveformChunk({
    required this.songId,
    required this.analysisVersion,
    required this.chunkIndex,
    required this.requestedStartMs,
    required this.requestedEndMs,
    required this.actualStartMs,
    required this.actualEndMs,
    required this.sourceFingerprint,
    required this.durationMs,
    required this.schemaVersion,
    required this.sampleRate,
    required this.channels,
    required this.peaks,
    required this.completedAt,
  });

  /// Stable idempotency key mirrored by the SQLite composite primary key.
  String get storageKey => '$songId:$analysisVersion:$chunkIndex';

  int get estimatedPayloadBytes => peaks.length * 8;
}

class DjWaveformIdentity {
  final String songId;
  final int analysisVersion;
  final String? sourceFingerprint;
  final int durationMs;
  final int schemaVersion;

  const DjWaveformIdentity({
    required this.songId,
    required this.analysisVersion,
    required this.sourceFingerprint,
    required this.durationMs,
    required this.schemaVersion,
  });

  bool matches(DjWaveformChunk chunk, {required int expectedSchemaVersion}) =>
      songId.isNotEmpty &&
      songId == chunk.songId &&
      analysisVersion == chunk.analysisVersion &&
      durationMs == chunk.durationMs &&
      schemaVersion == expectedSchemaVersion &&
      (sourceFingerprint == null ||
          sourceFingerprint == chunk.sourceFingerprint);
}

class DjWaveformManifest {
  final DjWaveformIdentity identity;
  final int expectedChunkCount;
  final Set<int> completedChunkIndices;

  const DjWaveformManifest({
    required this.identity,
    required this.expectedChunkCount,
    required this.completedChunkIndices,
  });

  bool get isComplete =>
      expectedChunkCount > 0 &&
      completedChunkIndices.length == expectedChunkCount &&
      completedChunkIndices.every(
        (index) => index >= 0 && index < expectedChunkCount,
      );

  int get remainingChunkCount =>
      expectedChunkCount <= 0
          ? 0
          : expectedChunkCount - completedChunkIndices
              .where((index) => index >= 0 && index < expectedChunkCount)
              .toSet()
              .length;
}
