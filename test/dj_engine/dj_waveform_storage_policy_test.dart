import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/analysis/dj_waveform_storage_policy.dart';
import 'package:resonate/dj_engine/analysis/dj_waveform_chunk.dart';

void main() {
  const policy = DjWaveformStoragePolicy();
  DjWaveformChunk chunk({int index = 0, String songId = 'song-a',
    int actualStart = 0, int actualEnd = 8000, List<double>? peaks}) =>
      DjWaveformChunk(
        songId: songId, analysisVersion: 1, chunkIndex: index,
        requestedStartMs: index * 8000, requestedEndMs: (index + 1) * 8000,
        actualStartMs: actualStart, actualEndMs: actualEnd,
        sourceFingerprint: 'fingerprint-a', durationMs: 16000,
        schemaVersion: 1, sampleRate: 44100, channels: 2,
        peaks: peaks ?? const [0.0, 0.25, 1.0],
        completedAt: DateTime.utc(2026),
      );

  test('accepts bounded measured chunk and valid decoder overlap', () {
    expect(policy.isValidChunk(chunk()), isTrue);
    expect(policy.isValidChunk(chunk(actualStart: 9000, actualEnd: 10000)), isFalse);
  });

  test('rejects malformed identity, intervals and peak values', () {
    expect(policy.isValidChunk(chunk(songId: ' ')), isFalse);
    expect(policy.isValidChunk(chunk(actualStart: -1)), isFalse);
    expect(policy.isValidChunk(chunk(peaks: List<double>.filled(257, .5))), isFalse);
    expect(policy.isValidChunk(chunk(peaks: const [double.nan])), isFalse);
    expect(policy.isValidChunk(chunk(peaks: const [-0.1])), isFalse);
    expect(policy.isValidChunk(chunk(peaks: const [1.1])), isFalse);
  });

  test('requires matching song, analysis, duration and source identity', () {
    const identity = DjWaveformIdentity(songId: 'song-a', analysisVersion: 1,
      sourceFingerprint: 'fingerprint-a', durationMs: 16000, schemaVersion: 1);
    expect(policy.canReuseChunk(identity: identity, chunk: chunk()), isTrue);
    expect(policy.canReuseChunk(identity: identity, chunk: chunk(songId: 'song-b')), isFalse);
    const unknownFingerprint = DjWaveformIdentity(songId: 'song-a', analysisVersion: 1,
      sourceFingerprint: null, durationMs: 16000, schemaVersion: 1);
    expect(policy.canReuseChunk(identity: unknownFingerprint, chunk: chunk()), isTrue);
  });

  test('partial manifest never reports complete and invalid indices are rejected', () {
    const identity = DjWaveformIdentity(songId: 'song-a', analysisVersion: 1,
      sourceFingerprint: 'fingerprint-a', durationMs: 16000, schemaVersion: 1);
    expect(policy.isManifestComplete(DjWaveformManifest(identity: identity,
      expectedChunkCount: 2, completedChunkIndices: {0})), isFalse);
    expect(policy.isManifestComplete(DjWaveformManifest(identity: identity,
      expectedChunkCount: 2, completedChunkIndices: {0, 1})), isTrue);
    expect(policy.isManifestComplete(DjWaveformManifest(identity: identity,
      expectedChunkCount: 2, completedChunkIndices: {0, 2})), isFalse);
  });

  test('cache budget is bounded and overscan is clamped', () {
    expect(policy.retainedCacheCount(payloadByteSizes: List.filled(200, 1024),
      incomingPayloadBytes: 1024), lessThanOrEqualTo(DjWaveformStoragePolicy.maxCacheChunks));
    expect(policy.retainedCacheCount(payloadByteSizes: const [], incomingPayloadBytes: 300000), 0);
    expect(policy.boundedOverscan(99), DjWaveformStoragePolicy.maxOverscanChunks);
    expect(policy.boundedOverscan(-1), 0);
  });
}
