import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'database_helper.dart';
import 'dj_analysis_service.dart';
import 'dj_analysis_foreground_service.dart';
import 'dj_waveform_chunk_analysis_service.dart';
import 'resonate_diagnostics.dart';

/// Background BPM/key tag scan when DJ Mode "Analyze library when idle" is on.
///
/// Idle analysis deliberately awaits each song to completion. A Future.timeout
/// does not cancel the native decode/analyzer underneath it; timing out and
/// advancing the loop can leave orphaned work running alongside later songs.
/// Playback/stop requests therefore take effect between songs, not by
/// abandoning a still-running analysis operation.
class DjIdleAnalysisService {
  DjIdleAnalysisService({
    DatabaseHelper? database,
    DjAnalysisService? analysis,
    DjWaveformChunkAnalysisService? waveformChunks,
  })  : _db = database ?? DatabaseHelper(),
        _analysis = analysis ?? DjAnalysisService(),
        _waveformChunks = waveformChunks ?? DjWaveformChunkAnalysisService();

  final DatabaseHelper _db;
  final DjAnalysisService _analysis;
  final DjWaveformChunkAnalysisService _waveformChunks;

  bool _running = false;
  bool _stopRequested = false;
  bool _backgroundServiceStarting = false;
  bool _backgroundServiceStarted = false;
  int _scanned = 0;
  int _updated = 0;
  int _failed = 0;
  final Map<String, DateTime> _lastProfileAttemptAt = <String, DateTime>{};
  static const Duration _retryCooldown = Duration(hours: 6);

  bool get isRunning => _running;
  bool get canContinueInBackground =>
      _backgroundServiceStarting || _backgroundServiceStarted;
  int get scanned => _scanned;
  int get updated => _updated;
  int get failed => _failed;

  Future<void> startIfNeeded({
    int maxSongs = 40,
    int maxWaveformChunks = 2,
    bool Function()? isStillIdle,
  }) async {
    if (_running) return;
    _running = true;
    _stopRequested = false;
    _scanned = 0;
    _updated = 0;
    _failed = 0;
    try {
      // Start while the Activity is foregrounded. Android then keeps the
      // process eligible for background execution with a visible notification.
      _backgroundServiceStarting = true;
      try {
        _backgroundServiceStarted = await DjAnalysisForegroundService.start();
      } finally {
        _backgroundServiceStarting = false;
      }
      await ResonateDiagnostics.recordDj(
        stage: 'idle_scan_start',
        outcome: 'started',
        extra: {
          'maxSongs': maxSongs,
          'backgroundExecution': _backgroundServiceStarted,
        },
      );
      final songs = await _db.getAllSongs();
      for (final song in songs) {
        if (_stopRequested || (isStillIdle != null && !isStillIdle())) break;
        if (_scanned >= maxSongs) break;
        if (song.filePath.trim().isEmpty) continue;
        try {
          final existing = await _analysis.getAnalysis(song.id);
          final hasUsableTags = existing != null &&
              (existing.hasUsableBpm || existing.hasUsableKey);
          final hasSectionProfile = existing?.sectionHint != null &&
              existing?.sectionHint != 'unknown';
          final hasWaveformProfile = await _analysis.hasWaveformProfile(song.id);
          final hasPsychicReport = await _analysis.hasPsychicReport(song.id);
          final hasUsablePsychicAnalysis =
              await _analysis.hasPsychicAnalysis(song.id);
          final now = DateTime.now();
          final psychicRetryDue = hasPsychicReport &&
              !hasUsablePsychicAnalysis &&
              existing?.analyzedAt != null &&
              now.difference(existing!.analyzedAt!) >= _retryCooldown;
          if (existing != null &&
              !existing.isStale &&
              hasUsableTags &&
              hasSectionProfile &&
              hasWaveformProfile &&
              hasPsychicReport &&
              !psychicRetryDue) {
            continue;
          }

          // Persisted attempt timestamps provide a retry backoff across process
          // death. In particular, a missing Psychic report must not trigger
          // an immediate full decode on every app launch.
          final recentlyAttempted = existing?.analyzedAt != null &&
              now.difference(existing!.analyzedAt!) < _retryCooldown;
          if (recentlyAttempted &&
              existing?.isStale != true &&
              (!hasPsychicReport ||
                  !hasWaveformProfile ||
                  !hasUsableTags ||
                  !hasSectionProfile)) {
            continue;
          }
          final lastAttempt = _lastProfileAttemptAt[song.id];
          if (lastAttempt != null &&
              now.difference(lastAttempt) < _retryCooldown) {
            continue;
          }
          // Persisted empty results also need a cooldown across app launches;
          // otherwise every unlock/route event would repeat expensive work.
          if (existing != null &&
              !existing.isStale &&
              !hasUsableTags &&
              existing.analyzedAt != null &&
              now.difference(existing.analyzedAt!) < _retryCooldown) {
            continue;
          }

          _scanned++;
          await DjAnalysisForegroundService.heartbeat();
          final before = existing;
          final needsFullProfile = before == null ||
              before.isStale ||
              !hasUsableTags ||
              !hasSectionProfile ||
              !hasWaveformProfile ||
              !hasPsychicReport ||
              psychicRetryDue;

          // Do not wrap this in Future.timeout: Dart timeout only stops waiting,
          // not the native decode. Keep the scan serial until the analyzer
          // really completes so the next song cannot overlap orphaned work.
          final after = await _analysis.analyzeSong(
            song,
            force: needsFullProfile,
          );

          // Cancellation is not a completed analysis attempt. The analyzer may
          // return an empty placeholder when its generation is invalidated;
          // do not mislabel that as missing tags or suppress a later retry.
          if (_stopRequested || (isStillIdle != null && !isStillIdle())) {
            await ResonateDiagnostics.recordDj(
              stage: 'idle_scan_song',
              songId: song.id,
              outcome: 'cancelled',
              extra: {'stopRequestedDuringAnalysis': true},
            );
          } else {
            _lastProfileAttemptAt[song.id] = DateTime.now();
            final gained =
                (after.hasUsableBpm && !(before?.hasUsableBpm ?? false)) ||
                (after.hasUsableKey && !(before?.hasUsableKey ?? false));
            if (gained) _updated++;
            await ResonateDiagnostics.recordDj(
              stage: 'idle_scan_song',
              songId: song.id,
              outcome: gained ? 'updated' : 'no_tags',
              extra: {
                'bpm': after.bpm,
                'hasKey': after.hasUsableKey,
                'psychicReportReady': await _analysis.hasPsychicAnalysis(song.id),
                'stopRequestedDuringAnalysis': false,
              },
            );
          }
        } catch (e) {
          if (_stopRequested || (isStillIdle != null && !isStillIdle())) {
            // A stop racing with a thrown platform error is still a
            // cancellation, not a failed analysis and not a retry cooldown.
            await ResonateDiagnostics.recordDj(
              stage: 'idle_scan_song',
              songId: song.id,
              outcome: 'cancelled',
              extra: {'stopRequestedDuringAnalysis': true},
            );
          } else {
            _failed++;
            _lastProfileAttemptAt[song.id] = DateTime.now();
            await ResonateDiagnostics.recordDj(
              stage: 'idle_scan_error',
              songId: song.id,
              outcome: 'failed',
              reason: e.toString(),
            );
          }
        }
        // Yield to the UI and re-check stop state before the next song.
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      // Waveform extraction is a separate serial pass after compact profile
      // analysis. A single idle opportunity may decode only a tiny bounded
      // number of chunks across the entire library, never per track.
      var waveformChunksRemaining = maxWaveformChunks.clamp(0, 4).toInt();
      var waveformChunksProcessed = 0;
      var waveformChunksEvicted = 0;
      if (!_stopRequested && waveformChunksRemaining > 0) {
        for (final song in songs) {
          if (_stopRequested ||
              (isStillIdle != null && !isStillIdle()) ||
              waveformChunksRemaining <= 0) {
            break;
          }
          if (song.filePath.trim().isEmpty ||
              song.duration.inMilliseconds <= 0) {
            continue;
          }
          await DjAnalysisForegroundService.heartbeat();
          final processed = await _waveformChunks.processMissingChunks(
            song,
            maxChunks: waveformChunksRemaining,
            isStillIdle: () =>
                !_stopRequested && (isStillIdle?.call() ?? true),
          );
          waveformChunksRemaining -= processed;
          waveformChunksProcessed += processed;
        }
      }
      if (waveformChunksProcessed > 0 &&
          !_stopRequested &&
          (isStillIdle?.call() ?? true)) {
        waveformChunksEvicted =
            await _db.pruneDjWaveformChunks();
      }
      await ResonateDiagnostics.recordDj(
        stage: 'idle_scan_done',
        outcome: _stopRequested ? 'stopped' : 'completed',
        extra: {
          'scanned': _scanned,
          'updated': _updated,
          'failed': _failed,
          'waveformChunksProcessed': waveformChunksProcessed,
          'waveformChunksEvicted': waveformChunksEvicted,
          'waveformChunkBudgetRemaining': waveformChunksRemaining,
          'idlePredicateStillTrue': isStillIdle?.call() ?? true,
        },
      );
    } catch (e) {
      await ResonateDiagnostics.recordDj(
        stage: 'idle_scan_error',
        outcome: 'failed',
        reason: e.toString(),
      );
    } finally {
      _running = false;
      await DjAnalysisForegroundService.stop();
      _backgroundServiceStarted = false;
      _backgroundServiceStarting = false;
    }
  }

  /// Stops after the currently awaited song analysis completes.
  ///
  /// Native decoding does not currently expose cancellation, so this method
  /// must not pretend it can interrupt an in-flight platform operation.
  void stop() {
    _stopRequested = true;
    _analysis.cancelCurrentAnalysis();
    _waveformChunks.cancel();
  }
}
