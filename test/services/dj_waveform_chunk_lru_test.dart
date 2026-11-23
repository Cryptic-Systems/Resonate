import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/analysis/dj_waveform_chunk.dart';
import 'package:resonate/services/dj_waveform_chunk_lru.dart';

void main() {
  DjWaveformChunk chunk(int index, {String songId = 'song-a'}) =>
      DjWaveformChunk(
        songId: songId,
        analysisVersion: 1,
        chunkIndex: index,
        requestedStartMs: index * 8000,
        requestedEndMs: (index + 1) * 8000,
        actualStartMs: index * 8000,
        actualEndMs: (index + 1) * 8000,
        sourceFingerprint: 'source-a',
        durationMs: 32000,
        schemaVersion: 1,
        sampleRate: 44100,
        channels: 2,
        peaks: List<double>.filled(192, .5),
        completedAt: DateTime.utc(2026),
      );

  const identity = DjWaveformIdentity(
    songId: 'song-a',
    analysisVersion: 1,
    sourceFingerprint: 'source-a',
    durationMs: 32000,
    schemaVersion: 1,
  );

  test('stores and refreshes entries on read', () {
    final cache = DjWaveformChunkLru(maxChunks: 2, maxBytes: 10000);
    cache.put(identity, chunk(0));
    cache.put(identity, chunk(1));
    expect(cache.get(identity, 0)?.chunkIndex, 0);
    cache.put(identity, chunk(2));
    expect(cache.get(identity, 1), isNull);
    expect(cache.get(identity, 0)?.chunkIndex, 0);
    expect(cache.get(identity, 2)?.chunkIndex, 2);
  });

  test('enforces both chunk-count and byte budgets', () {
    final cache = DjWaveformChunkLru(maxChunks: 2, maxBytes: 1800);
    cache.put(identity, chunk(0));
    cache.put(identity, chunk(1));
    expect(cache.length, lessThanOrEqualTo(2));
    expect(cache.estimatedBytes, lessThanOrEqualTo(1800));
    cache.put(identity, chunk(2));
    expect(cache.estimatedBytes, lessThanOrEqualTo(1800));
  });

  test('isolates identities and rejects invalid chunks', () {
    final cache = DjWaveformChunkLru();
    cache.put(identity, chunk(0));
    const otherSource = DjWaveformIdentity(
      songId: 'song-a',
      analysisVersion: 1,
      sourceFingerprint: 'source-b',
      durationMs: 32000,
      schemaVersion: 1,
    );
    expect(cache.get(otherSource, 0), isNull);
    cache.put(identity, chunk(0, songId: 'different-song'));
    expect(cache.length, 1);
  });

  test('clear releases all retained peaks and byte accounting', () {
    final cache = DjWaveformChunkLru();
    cache.put(identity, chunk(0));
    expect(cache.length, 1);
    expect(cache.estimatedBytes, greaterThan(0));
    cache.clear();
    expect(cache.length, 0);
    expect(cache.estimatedBytes, 0);
  });
}
