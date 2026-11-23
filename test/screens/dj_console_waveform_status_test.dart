import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/analysis/dj_waveform_chunk.dart';
import 'package:resonate/screens/dj_console_waveform_status.dart';

DjWaveformChunk _chunk({
  required int index,
  required int start,
  required int end,
  String songId = 'song-1',
  int duration = 16000,
}) =>
    DjWaveformChunk(
      songId: songId,
      analysisVersion: 1,
      chunkIndex: index,
      requestedStartMs: start,
      requestedEndMs: end,
      actualStartMs: start,
      actualEndMs: end,
      sourceFingerprint: 'source-a',
      durationMs: duration,
      schemaVersion: 1,
      sampleRate: 44100,
      channels: 2,
      peaks: const [0.1, 0.5, 0.2],
      completedAt: DateTime.utc(2026, 1, 1),
    );

Widget _status(DjConsoleWaveformState state, {int count = 0}) =>
    MaterialApp(
      home: Scaffold(
        body: DjConsoleWaveformStatus(state: state, chunkCount: count),
      ),
    );

void main() {
  group('DJ Console waveform coverage widget', () {
    testWidgets('shows loading while range query is pending', (tester) async {
      await tester.pumpWidget(_status(DjConsoleWaveformState.loading));
      expect(find.text('LOADING MEASURED PCM CHUNKS'), findsOneWidget);
    });

    testWidgets('shows partial measured coverage without implying silence',
        (tester) async {
      await tester.pumpWidget(_status(DjConsoleWaveformState.partial, count: 1));
      expect(find.text('VISIBLE RANGE · 1 CHUNKS · GAPS UNANALYSED'),
          findsOneWidget);
    });

    testWidgets('shows full coverage only for a complete measured timeline',
        (tester) async {
      await tester.pumpWidget(_status(DjConsoleWaveformState.complete, count: 2));
      expect(find.text('VISIBLE RANGE · 2 CHUNKS · COMPLETE'),
          findsOneWidget);
    });

    testWidgets('hides stale waveform identity', (tester) async {
      await tester.pumpWidget(_status(DjConsoleWaveformState.stale));
      expect(find.text('WAVEFORM IDENTITY MISMATCH · HIDDEN'), findsOneWidget);
    });

    testWidgets('shows unsupported source state', (tester) async {
      await tester.pumpWidget(_status(DjConsoleWaveformState.unsupported));
      expect(find.text('WAVEFORM DATA UNAVAILABLE'), findsOneWidget);
    });
  });

  group('DJ Console waveform coverage classification', () {
    const expectedSongId = 'song-1';

    test('classifies pending query as loading', () {
      final state = DjConsoleWaveformStatus.classify(
        snapshot: const AsyncSnapshot<List<DjWaveformChunk>>.waiting(),
        expectedSongId: expectedSongId,
        durationMs: 16000,
        legacyAvailable: false,
        profileLoading: false,
        profileIdentityMismatch: false,
      );
      expect(state, DjConsoleWaveformState.loading);
    });

    test('classifies contiguous measured chunks as complete', () {
      final state = DjConsoleWaveformStatus.classify(
        snapshot: AsyncSnapshot.withData(ConnectionState.done, [
          _chunk(index: 0, start: 0, end: 8000),
          _chunk(index: 1, start: 8000, end: 16000),
        ]),
        expectedSongId: expectedSongId,
        durationMs: 16000,
        legacyAvailable: false,
        profileLoading: false,
        profileIdentityMismatch: false,
      );
      expect(state, DjConsoleWaveformState.complete);
    });

    test('classifies complete coverage only for the requested visible interval', () {
      final state = DjConsoleWaveformStatus.classify(
        snapshot: AsyncSnapshot.withData(ConnectionState.done, [
          _chunk(index: 1, start: 8000, end: 16000),
        ]),
        expectedSongId: expectedSongId,
        durationMs: 32000,
        visibleStartMs: 8000,
        visibleEndMs: 16000,
        legacyAvailable: false,
        profileLoading: false,
        profileIdentityMismatch: false,
      );
      expect(state, DjConsoleWaveformState.complete);
    });

    test('classifies missing interval as partial', () {
      final state = DjConsoleWaveformStatus.classify(
        snapshot: AsyncSnapshot.withData(ConnectionState.done, [
          _chunk(index: 0, start: 0, end: 8000),
          _chunk(index: 2, start: 12000, end: 16000),
        ]),
        expectedSongId: expectedSongId,
        durationMs: 16000,
        legacyAvailable: false,
        profileLoading: false,
        profileIdentityMismatch: false,
      );
      expect(state, DjConsoleWaveformState.partial);
    });

    test('rejects chunks belonging to another song as stale', () {
      final state = DjConsoleWaveformStatus.classify(
        snapshot: AsyncSnapshot.withData(ConnectionState.done, [
          _chunk(index: 0, start: 0, end: 16000, songId: 'song-2'),
        ]),
        expectedSongId: expectedSongId,
        durationMs: 16000,
        legacyAvailable: false,
        profileLoading: false,
        profileIdentityMismatch: false,
      );
      expect(state, DjConsoleWaveformState.stale);
    });

    test('maps decoder or storage errors to unsupported', () {
      final state = DjConsoleWaveformStatus.classify(
        snapshot: AsyncSnapshot.withError(ConnectionState.done, StateError('unsupported')),
        expectedSongId: expectedSongId,
        durationMs: 16000,
        legacyAvailable: false,
        profileLoading: false,
        profileIdentityMismatch: false,
      );
      expect(state, DjConsoleWaveformState.unsupported);
    });
  });
}
