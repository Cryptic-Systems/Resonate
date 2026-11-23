import 'package:flutter/material.dart';

import '../dj_engine/analysis/dj_waveform_chunk.dart';

enum DjConsoleWaveformState {
  loading,
  partial,
  complete,
  stale,
  unsupported,
  legacy,
  unavailable,
}

/// Pure coverage classification shared by the Console and its widget tests.
class DjConsoleWaveformStatus extends StatelessWidget {
  const DjConsoleWaveformStatus({
    super.key,
    required this.state,
    required this.chunkCount,
  });

  final DjConsoleWaveformState state;
  final int chunkCount;

  static DjConsoleWaveformState classify({
    required AsyncSnapshot<List<DjWaveformChunk>> snapshot,
    required String? expectedSongId,
    required int durationMs,
    required bool legacyAvailable,
    required bool profileLoading,
    required bool profileIdentityMismatch,
  }) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return DjConsoleWaveformState.loading;
    }
    if (snapshot.hasError) return DjConsoleWaveformState.unsupported;

    final raw = snapshot.data ?? const <DjWaveformChunk>[];
    final valid = raw.where((chunk) =>
        expectedSongId != null &&
        chunk.songId == expectedSongId &&
        chunk.durationMs == durationMs).toList()
      ..sort((a, b) => a.actualStartMs.compareTo(b.actualStartMs));

    if (raw.isNotEmpty && valid.isEmpty) return DjConsoleWaveformState.stale;
    if (valid.isNotEmpty && durationMs > 0) {
      var coveredUntil = 0;
      for (final chunk in valid) {
        if (chunk.actualStartMs > coveredUntil) break;
        if (chunk.actualEndMs > coveredUntil) {
          coveredUntil = chunk.actualEndMs;
        }
      }
      if (coveredUntil >= durationMs) return DjConsoleWaveformState.complete;
      return DjConsoleWaveformState.partial;
    }
    if (legacyAvailable) return DjConsoleWaveformState.legacy;
    if (profileLoading) return DjConsoleWaveformState.loading;
    if (profileIdentityMismatch) return DjConsoleWaveformState.stale;
    return DjConsoleWaveformState.unavailable;
  }

  String get label => switch (state) {
        DjConsoleWaveformState.loading => 'LOADING MEASURED PCM CHUNKS',
        DjConsoleWaveformState.partial =>
          'MEASURED PCM · $chunkCount CHUNKS · GAPS UNANALYSED',
        DjConsoleWaveformState.complete =>
          'MEASURED PCM · $chunkCount CHUNKS · FULL COVERAGE',
        DjConsoleWaveformState.stale => 'WAVEFORM IDENTITY MISMATCH · HIDDEN',
        DjConsoleWaveformState.unsupported => 'WAVEFORM DATA UNAVAILABLE',
        DjConsoleWaveformState.legacy => 'LEGACY SAMPLED PCM · GAPS UNANALYSED',
        DjConsoleWaveformState.unavailable => 'NO MEASURED PCM AVAILABLE',
      };

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: const TextStyle(
          fontSize: 7,
          letterSpacing: .5,
          color: Colors.white70,
        ),
      );
}
