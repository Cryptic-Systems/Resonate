import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import '../providers/library_provider.dart';
import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../models/song.dart';
import '../navigation/shell_nav.dart';
import '../services/dj_waveform_range_reader.dart';
import '../services/dj_cue_point_store.dart';
import '../services/playback_snapshot.dart';
import '../services/playback_engine_session.dart';
import '../providers/dj_mode_provider.dart';
import '../dj_engine/core/dj_types.dart';
import '../ui/resonate_glass.dart';
import 'dj_console_deck_tempo_control.dart';
import 'dj_console_duration_policy.dart';
import 'dj_console_tempo_policy.dart';
import 'dj_console_manual_controls_policy.dart';
import 'dj_console_jog_seek_policy.dart';
import 'dj_console_overlay_policy.dart';
import 'dj_console_waveform_status.dart';
import 'dj_waveform_viewport_policy.dart';

/// Landscape-first visual foundation for the future performance console.
///
/// The Console exposes only controls backed by the existing Media3 authority.
/// Platter gestures publish bounded, coalesced scratch controls to the matching
/// physical deck; waveform taps remain one-shot Media3 seeks.
class DjConsoleScreen extends StatefulWidget {
  const DjConsoleScreen({super.key});

  @override
  State<DjConsoleScreen> createState() => _DjConsoleScreenState();
}

class _DjConsoleScreenState extends State<DjConsoleScreen> {
  final Map<String, Future<DjTrackProfile?>> _profileFutures = {};
  final DjWaveformRangeReader _waveformReader = DjWaveformRangeReader();
  final DjCuePointStore _cuePointStore = DjCuePointStore();
  Map<String, List<Duration?>> _hotCues = <String, List<Duration?>>{};

  Future<DjTrackProfile?>? _profileFutureFor(
    BuildContext context,
    String? songId,
  ) {
    if (songId == null) return null;
    final cached = _profileFutures.putIfAbsent(
      songId,
      () => context.read<DjModeProvider>().analysis.getProfile(songId),
    );
    // The Console displays at most two decks. Keep a small rolling cache so
    // repeated queue changes cannot retain an unbounded set of profile futures.
    while (_profileFutures.length > 4) {
      final oldest = _profileFutures.keys.first;
      if (oldest == songId) break;
      _profileFutures.remove(oldest);
    }
    return cached;
  }
  static const _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(_landscape);
    unawaited(_loadCuePoints());
  }

  @override
  void dispose() {
    // Restore the app's normal portrait-first policy when leaving the Console.
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  Future<void> _loadCuePoints() async {
    try {
      final loaded = await _cuePointStore.load();
      if (!mounted) return;
      setState(() => _hotCues = loaded);
    } catch (error) {
      debugPrint('DJ cue points could not be loaded: $error');
    }
  }

  Future<void> _setHotCue(String deckId, PlaybackDeckSnapshot? deck, int slot) async {
    final expectedTrackId = deck?.mediaId;
    if (expectedTrackId == null || expectedTrackId.isEmpty || slot < 0 || slot >= DjCuePointStore.slotCount) return;
    final music = context.read<MusicProvider>();
    final latestState = music.media3ShadowState;
    final latestDeck = deckId == 'A' ? latestState?.deckA : latestState?.deckB;
    if (latestState?.djDualDeckMode != true || latestDeck?.mediaId != expectedTrackId) return;
    final cuePosition = latestDeck!.position;
    final updated = <String, List<Duration?>>{
      for (final entry in _hotCues.entries) entry.key: List<Duration?>.from(entry.value),
    };
    final slots = updated.putIfAbsent(expectedTrackId, () => List<Duration?>.filled(DjCuePointStore.slotCount, null));
    while (slots.length < DjCuePointStore.slotCount) { slots.add(null); }
    slots[slot] = cuePosition;
    try {
      await _cuePointStore.saveAll(updated);
      if (!mounted) return;
      setState(() => _hotCues = updated);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deck $deckId hot cue ${slot + 1} saved at ${_formatCue(cuePosition)}.'),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hot cue could not be saved: $error')));
    }
  }

  Future<void> _clearHotCue(String deckId, PlaybackDeckSnapshot? deck, int slot) async {
    final expectedTrackId = deck?.mediaId;
    if (expectedTrackId == null ||
        expectedTrackId.isEmpty ||
        slot < 0 ||
        slot >= DjCuePointStore.slotCount) {
      return;
    }
    final music = context.read<MusicProvider>();
    final latestState = music.media3ShadowState;
    final latestDeck = deckId == 'A' ? latestState?.deckA : latestState?.deckB;
    if (latestState?.djDualDeckMode != true ||
        latestDeck?.mediaId != expectedTrackId) {
      return;
    }
    final updated = <String, List<Duration?>>{
      for (final entry in _hotCues.entries)
        entry.key: List<Duration?>.from(entry.value),
    };
    final slots = updated[expectedTrackId];
    if (slots == null || slot >= slots.length || slots[slot] == null) return;
    slots[slot] = null;
    try {
      await _cuePointStore.saveAll(updated);
      if (!mounted) return;
      setState(() => _hotCues = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deck $deckId cue ${slot + 1} cleared.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cue could not be cleared: $error')),
      );
    }
  }

  Future<void> _seekToHotCue(String deckId, PlaybackDeckSnapshot? deck, int slot) async {
    final expectedTrackId = deck?.mediaId;
    if (expectedTrackId == null || expectedTrackId.isEmpty || slot < 0 || slot >= DjCuePointStore.slotCount) return;
    final cues = _hotCues[expectedTrackId];
    if (cues == null || slot >= cues.length || cues[slot] == null) return;
    final cue = cues[slot]!;
    final music = context.read<MusicProvider>();
    final latestState = music.media3ShadowState;
    final latestDeck = deckId == 'A' ? latestState?.deckA : latestState?.deckB;
    if (latestState?.djDualDeckMode != true || latestDeck?.mediaId != expectedTrackId) return;
    if (latestDeck!.duration != null && cue > latestDeck.duration!) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Saved hot cue is beyond this track duration. Set that pad again.'),
      ));
      return;
    }
    try {
      await music.seekDjDeck(deckId: deckId, position: cue, expectedMediaId: expectedTrackId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deck $deckId hot cue seek was not applied: $error'),
      ));
    }
  }
  String _formatCue(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _syncDeckToOther(String deckId) async {
    if (deckId != 'A' && deckId != 'B') return;
    final music = context.read<MusicProvider>();
    final initial = music.media3ShadowState;
    final initialTarget = deckId == 'A' ? initial?.deckA : initial?.deckB;
    final initialSource = deckId == 'A' ? initial?.deckB : initial?.deckA;
    if (initial?.djDualDeckMode != true ||
        !music.media3ProviderSessionActive ||
        music.transitionInProgress ||
        initialTarget == null ||
        initialSource == null) {
      return;
    }
    final targetId = initialTarget.mediaId;
    final sourceId = initialSource.mediaId;
    if (targetId == null || sourceId == null || targetId == sourceId) return;

    try {
      final profiles = await Future.wait<DjTrackProfile?>([
        _profileFutureFor(context, targetId)!,
        _profileFutureFor(context, sourceId)!,
      ]);
      if (!mounted) return;
      final targetGrid = profiles[0]?.beatGrid;
      final sourceGrid = profiles[1]?.beatGrid;
      if (targetGrid == null ||
          sourceGrid == null ||
          !DjConsoleOverlayPolicy.hasTrustedTempo(targetGrid) ||
          !DjConsoleOverlayPolicy.hasTrustedTempo(sourceGrid)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('SYNC needs a trusted BPM analysis on both decks.'),
        ));
        return;
      }

      final targetBpm = targetGrid.bpm;
      final sourceBpm = sourceGrid.bpm;
      if (targetBpm == null ||
          sourceBpm == null ||
          !targetBpm.isFinite ||
          !sourceBpm.isFinite ||
          targetBpm <= 0 ||
          sourceBpm <= 0) {
        return;
      }

      // Beat-grid loading can take seconds. Never use the deck positions or
      // tempo captured before that await: re-read both physical decks now.
      final beforeTempo = music.media3ShadowState;
      final target = deckId == 'A' ? beforeTempo?.deckA : beforeTempo?.deckB;
      final source = deckId == 'A' ? beforeTempo?.deckB : beforeTempo?.deckA;
      if (beforeTempo?.djDualDeckMode != true ||
          !music.media3ProviderSessionActive ||
          music.transitionInProgress ||
          target?.mediaId != targetId ||
          source?.mediaId != sourceId ||
          target == null ||
          source == null ||
          !source.speed.isFinite ||
          source.speed <= 0) {
        return;
      }

      // Match effective tempo, not just analyzed base BPM: the source deck
      // may already have a manual tempo-fader adjustment.
      final sourceEffectiveBpm = sourceBpm * source.speed;
      final speed = DjConsoleTempoPolicy.syncSpeed(
        sourceBpm: sourceEffectiveBpm,
        targetBpm: targetBpm,
      );
      if (speed == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('SYNC is outside the ±6% tempo range. Adjust the tempo manually first.'),
        ));
        return;
      }

      await music.setDjDeckPlaybackParameters(
        deckId: deckId,
        speed: speed,
        pitch: 1.0,
      );

      // Re-read after the native tempo command. This gives phase alignment a
      // current position for both decks and the target's confirmed new speed;
      // adding elapsed time to an old position is not reliable if UI polling
      // or the platform command was delayed.
      var phaseAligned = false;
      var phaseTrimSkippedAtBoundary = false;
      var phaseCorrectionUnavailable = false;
      final afterTempo = music.media3ShadowState;
      final afterTarget = deckId == 'A' ? afterTempo?.deckA : afterTempo?.deckB;
      final afterSource = deckId == 'A' ? afterTempo?.deckB : afterTempo?.deckA;
      final canPhaseAlign = afterTempo?.djDualDeckMode == true &&
          afterTarget?.mediaId == targetId &&
          afterSource?.mediaId == sourceId &&
          afterTarget != null &&
          afterSource != null &&
          afterTarget.speed.isFinite &&
          afterTarget.speed > 0 &&
          afterSource.speed.isFinite &&
          afterSource.speed > 0 &&
          afterTarget.isPlaying &&
          afterSource.isPlaying &&
          !music.transitionInProgress;

      if (canPhaseAlign) {
        final phaseCorrection = DjConsoleTempoPolicy.phaseCorrectionMs(
          sourceBeatMs: sourceGrid.beatMs,
          targetBeatMs: targetGrid.beatMs,
          sourcePositionMs: afterSource.position.inMilliseconds,
          targetPositionMs: afterTarget.position.inMilliseconds,
          sourceBpm: sourceBpm,
          targetBpm: targetBpm,
          sourceSpeed: afterSource.speed,
          targetSpeed: afterTarget.speed,
        );
        if (phaseCorrection == null) {
          phaseCorrectionUnavailable = true;
        } else if (phaseCorrection != 0) {
          final alignedPosition = afterTarget.position +
              Duration(milliseconds: phaseCorrection);
          if (alignedPosition.isNegative ||
              (afterTarget.duration != null &&
                  alignedPosition > afterTarget.duration!)) {
            phaseTrimSkippedAtBoundary = true;
          } else {
            final latest = music.media3ShadowState;
            final latestTarget = deckId == 'A' ? latest?.deckA : latest?.deckB;
            final latestSource = deckId == 'A' ? latest?.deckB : latest?.deckA;
            if (latest?.djDualDeckMode == true &&
                latestTarget?.mediaId == targetId &&
                latestSource?.mediaId == sourceId &&
                !music.transitionInProgress) {
              await music.seekDjDeck(
                deckId: deckId,
                position: alignedPosition,
                expectedMediaId: targetId,
              );
              phaseAligned = true;
            }
          }
        } else {
          phaseAligned = true;
        }
      }

      if (!mounted) return;
      final phaseMessage = !canPhaseAlign
          ? ' Start both decks for phase alignment.'
          : phaseTrimSkippedAtBoundary
              ? ' Tempo synced; phase trim was skipped at the track boundary.'
              : phaseCorrectionUnavailable
                  ? ' Phase offset is too large for a safe automatic trim; align manually.'
                  : phaseAligned
                      ? ' Beat phase aligned.'
                      : ' Tempo synced; phase alignment was not applied.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Deck $deckId tempo synced to ${sourceEffectiveBpm.toStringAsFixed(1)} BPM.$phaseMessage',
        ),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deck $deckId SYNC was not applied: $error'),
      ));
    }
  }

  Future<void> _chooseTrackForDeck(
    BuildContext context,
    String deckId,
    MusicProvider music,
    LibraryProvider library,
  ) async {
    final state = music.media3ShadowState;
    final currentDeckMediaId =
        (deckId == 'A' ? state?.deckA : state?.deckB)?.mediaId;
    final otherDeckMediaId =
        (deckId == 'A' ? state?.deckB : state?.deckA)?.mediaId;
    final song = await showModalBottomSheet<Song>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _DjTrackPickerSheet(
        deckId: deckId,
        songs: library.allSongs,
        currentDeckMediaId: currentDeckMediaId,
        otherDeckMediaId: otherDeckMediaId,
      ),
    );
    if (song == null || !mounted) return;
    try {
      await music.loadDjDeck(deckId, <Song>[song]);
      if (!mounted) return;
      unawaited(context.read<DjModeProvider>().ensureTrackWaveform(song));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded “${song.title}” into Deck $deckId.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load Deck $deckId: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appTheme = Theme.of(context);
    // The performance console uses dark glass surfaces regardless of the
    // app-wide appearance. Pin its foreground palette so light-mode theme
    // text cannot disappear against the deck and mixer panels.
    final theme = appTheme.copyWith(
      brightness: Brightness.dark,
      colorScheme: appTheme.colorScheme.copyWith(
        brightness: Brightness.dark,
        surface: const Color(0xFF101923),
        onSurface: Colors.white,
        onSurfaceVariant: const Color(0xFFCBD5E1),
      ),
      textTheme: appTheme.textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      primaryTextTheme: appTheme.primaryTextTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      iconTheme: appTheme.iconTheme.copyWith(
        color: const Color(0xFFE6EDF5),
      ),
      scaffoldBackgroundColor: const Color(0xFF080E15),
    );
    return Theme(
      data: theme,
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: ResonateGlassBackground(
        child: SafeArea(
          child: Consumer3<MusicProvider, LibraryProvider, DjModeProvider>(
        builder: (context, music, library, djMode, _) {
          final state = music.media3ShadowState;
          final deckA = state?.deckA;
          final deckB = state?.deckB;

          Song? findSong(String? id) {
            if (id == null) return null;
            for (final candidate in library.allSongs) {
              if (candidate.id == id) return candidate;
            }
            return null;
          }

          final songA = findSong(deckA?.mediaId);
          final songB = findSong(deckB?.mediaId);
          const durationPolicy = DjConsoleDurationPolicy();
          // Match the library duration used by persisted waveform chunks.
          // Media3 duration is the fallback before the library item resolves.
          final durationA = durationPolicy.resolve(
            libraryDuration: songA?.duration,
            mediaDuration: deckA?.duration,
          );
          final durationB = durationPolicy.resolve(
            libraryDuration: songB?.duration,
            mediaDuration: deckB?.duration,
          );
          final progressA = durationA.inMilliseconds <= 0
              ? 0.0
              : ((deckA?.position ?? Duration.zero).inMilliseconds /
                      durationA.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
          final progressB = durationB.inMilliseconds <= 0
              ? 0.0
              : ((deckB?.position ?? Duration.zero).inMilliseconds /
                      durationB.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
          final djSessionActive = state?.djDualDeckMode == true;
          final screenSize = MediaQuery.sizeOf(context);
          final compact = screenSize.width < 820 || screenSize.height < 520;

          Widget buildDeck({
            required String id,
            required PlaybackDeckSnapshot? deck,
            required Song? song,
            required Duration duration,
            required double progress,
          }) {
            final loaded = deck?.mediaId != null;
            final isPlaying = deck?.isPlaying == true;
            final trackId = deck?.mediaId;
            final storedCues = List<Duration?>.generate(
              DjCuePointStore.slotCount,
              (index) {
                final slots = trackId == null ? null : _hotCues[trackId];
                final value = slots != null && index < slots.length ? slots[index] : null;
                return value != null && deck?.duration != null && value > deck!.duration!
                    ? null
                    : value;
              },
            );
            final title = deck?.title ?? song?.title ?? 'Empty deck';
            final artist = deck?.artist ?? song?.artist ??
                'Load a track from the shared library';
            final position = deck?.position ?? Duration.zero;
            return _ConsoleDeck(
                deck: 'DECK $id',
                active: loaded,
                selected: state?.activeDeckId == id,
                onAir: DjConsoleManualControlsPolicy.isDeckOnAir(
                  deckId: id,
                  deckHasMedia: loaded,
                  isPlaying: isPlaying,
                  crossfaderPosition: state?.djCrossfaderPosition ?? 0.5,
                ),
                compact: compact,
                isPlaying: isPlaying,
                waveformRevision: djMode.waveformRevision,
                onEnsureWaveform: song == null
                    ? null
                    : () => unawaited(context.read<DjModeProvider>().ensureTrackWaveform(song)),
                canPlay: djSessionActive && loaded && music.media3ProviderSessionActive,
                canAdjustChannelGain:
                    DjConsoleManualControlsPolicy.canAdjustChannelGain(
                  djSessionActive: djSessionActive,
                  media3SessionActive: music.media3ProviderSessionActive,
                  transitionInProgress: music.transitionInProgress,
                  deckHasMedia: loaded,
                ),
                canAdjustEq: djSessionActive && loaded &&
                    music.media3ProviderSessionActive,
                jogSeekEnabled: djSessionActive && loaded &&
                    music.media3ProviderSessionActive &&
                    !music.transitionInProgress,
                onSync: djSessionActive && loaded &&
                        (id == 'A' ? deckB?.mediaId : deckA?.mediaId) != null
                    ? () => unawaited(_syncDeckToOther(id))
                    : null,
                onPlayPause: () async {
                  if (isPlaying) {
                    await music.pauseDjDeck(id);
                  } else {
                    await music.playDjDeck(id);
                  }
                },
                hotCuePositions: storedCues,
                onSetHotCue: djSessionActive && loaded
                    ? (slot) => unawaited(_setHotCue(id, deck, slot))
                    : null,
                onClearHotCue: djSessionActive && loaded
                    ? (slot) => unawaited(_clearHotCue(id, deck, slot))
                    : null,
                onHotCue: djSessionActive && loaded
                    ? (slot) => unawaited(_seekToHotCue(id, deck, slot))
                    : null,
                channelGain: deck?.channelGain ?? 1.0,
                onChannelGainChanged: (gain) =>
                    music.setDjDeckChannelGain(deckId: id, gain: gain),
                eqGains: music.djDeckEqGains(id),
                onEqChanged: (gains) => music.setDjDeckEq(
                  deckId: id,
                  gainsDb: gains,
                ),
                filterType: music.djDeckFilterType(id),
                filterCutoffHz: music.djDeckFilterCutoff(id),
                onFilterChanged: (type, cutoffHz) => music.setDjDeckFilter(
                  deckId: id, type: type, cutoffHz: cutoffHz,
                ),
                onJogSeek: (target) => music.seekDjDeck(
                  deckId: id,
                  position: target,
                  expectedMediaId: deck!.mediaId!,
                ),
                onScratchControl: (active, velocity, anchor) async {
                  final session = music.media3PlaybackSession;
                  if (session is! PlaybackDjScratchSession) {
                    throw UnsupportedError('The active Media3 session does not support platter scratch.');
                  }
                  await (session as PlaybackDjScratchSession).setDjScratchControl(
                    deckId: id,
                    expectedMediaId: deck!.mediaId!,
                    active: active,
                    velocity: velocity,
                    anchor: anchor,
                  );
                },
                loopActive: deck?.loopActive == true,
                loopStart: deck?.loopStart,
                loopEnd: deck?.loopEnd,
                onSetLoopRange: djSessionActive && loaded &&
                        music.media3ProviderSessionActive && !music.transitionInProgress
                    ? (start, end) => music.setDjDeckLoopRange(
                          deckId: id,
                          start: start,
                          end: end,
                          expectedMediaId: deck!.mediaId!,
                        )
                    : null,
                onClearLoop: djSessionActive && loaded &&
                        music.media3ProviderSessionActive && !music.transitionInProgress
                    ? () => music.clearDjDeckLoop(deckId: id)
                    : null,
                status: DjConsoleManualControlsPolicy.deckStatusLabel(
                  selected: state?.activeDeckId == id,
                  isPlaying: isPlaying,
                  onAir: DjConsoleManualControlsPolicy.isDeckOnAir(
                    deckId: id,
                    deckHasMedia: loaded,
                    isPlaying: isPlaying,
                    crossfaderPosition: state?.djCrossfaderPosition ?? 0.5,
                  ),
                  deckHasMedia: loaded,
                ),
                title: title,
                artist: artist,
                progress: progress,
                position: position,
                duration: duration,
                profileFuture: _profileFutureFor(context, song?.id),
                expectedSongId: song?.id ?? deck?.mediaId,
                waveformSourceKey: song?.filePath,
                waveformLoader: song == null
                    ? null
                    : (startMs, endMs) => _waveformReader.loadVisibleRange(
                          song,
                          startMs: startMs,
                          endMs: endMs,
                        ),
              );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(
              children: [
                SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back to DJ Workspace',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 4),
                      Text('DJ CONSOLE', style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      const Spacer(),
                      if (!djSessionActive)
                        const Tooltip(message: 'DJ deck session is not active',
                          child: Icon(Icons.warning_amber_rounded, size: 18)),
                    ],
                  ),
                ),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final mixerStatus =
                          DjConsoleManualControlsPolicy.crossfaderStatusText(
                        djSessionActive: djSessionActive,
                        media3SessionActive: music.media3ProviderSessionActive,
                        transitionInProgress: music.transitionInProgress,
                        deckAHasMedia: deckA?.mediaId != null,
                        deckBHasMedia: deckB?.mediaId != null,
                        deckAIsPlaying: deckA?.isPlaying == true,
                        deckBIsPlaying: deckB?.isPlaying == true,
                      );
                      final mixer = SizedBox(
                        width: compact ? 148 : 188,
                        child: _DjConsoleMixer(
                          enabled: DjConsoleManualControlsPolicy.canAdjustCrossfader(
                            djSessionActive: djSessionActive && music.media3ProviderSessionActive,
                            transitionInProgress: music.transitionInProgress,
                            deckAHasMedia: deckA?.mediaId != null,
                            deckBHasMedia: deckB?.mediaId != null,
                          ),
                          position: state?.djCrossfaderPosition ?? 0.5,
                          compact: compact,
                          statusMessage: mixerStatus,
                          onChanged: music.setDjCrossfader,
                          onLoadA: djSessionActive ? () => unawaited(_chooseTrackForDeck(context, 'A', music, library)) : null,
                          onLoadB: djSessionActive ? () => unawaited(_chooseTrackForDeck(context, 'B', music, library)) : null,
                          onGestureStart: music.beginDjCrossfaderGesture,
                          onGestureEnd: music.endDjCrossfaderGesture,
                        ),
                      );
                      final deckAWidget = buildDeck(
                        id: 'A',
                        deck: deckA,
                        song: songA,
                        duration: durationA,
                        progress: progressA,
                      );
                      final deckBWidget = buildDeck(
                        id: 'B',
                        deck: deckB,
                        song: songB,
                        duration: durationB,
                        progress: progressB,
                      );

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: deckAWidget),
                          SizedBox(width: compact ? 8 : 12),
                          mixer,
                          SizedBox(width: compact ? 8 : 12),
                          Expanded(child: deckBWidget),
                        ],
                      );
                    },
                  ),
                ),

              ],
            ),
          );
        },
          ),
        ),
      ),
      ),
    );
  }
}

class _ConsoleDeck extends StatefulWidget {
  const _ConsoleDeck({
    required this.deck, required this.active, required this.selected, required this.onAir,
    required this.compact,
    required this.isPlaying,
    required this.onEnsureWaveform,
    required this.waveformRevision,
    required this.canPlay,
    required this.onPlayPause,
    this.onSync,
    required this.hotCuePositions,
    required this.onSetHotCue,
    required this.onClearHotCue,
    required this.onHotCue,
    required this.channelGain,
    required this.canAdjustChannelGain,
    required this.canAdjustEq,
    required this.onChannelGainChanged,
    required this.eqGains,
    required this.onEqChanged,
    required this.filterType,
    required this.filterCutoffHz,
    required this.onFilterChanged,
    required this.jogSeekEnabled,
    required this.onJogSeek,
    required this.onScratchControl,
    required this.loopActive,
    required this.loopStart,
    required this.loopEnd,
    required this.onSetLoopRange,
    required this.onClearLoop,
    required this.status, required this.title, required this.artist, required this.progress,
    required this.position, required this.duration, required this.profileFuture,
    required this.expectedSongId,
    required this.waveformSourceKey,
    required this.waveformLoader,
  });

  final String deck, status, title, artist;
  final bool active, selected, onAir, compact, isPlaying, canPlay, jogSeekEnabled;
  final VoidCallback? onEnsureWaveform;
  final int waveformRevision;
  final Future<void> Function() onPlayPause;
  final VoidCallback? onSync;
  final List<Duration?> hotCuePositions;
  final ValueChanged<int>? onSetHotCue;
  final ValueChanged<int>? onClearHotCue;
  final ValueChanged<int>? onHotCue;
  final double channelGain;
  final bool canAdjustChannelGain, canAdjustEq;
  final Future<void> Function(double gain) onChannelGainChanged;
  final List<double> eqGains;
  final Future<void> Function(List<double> gains) onEqChanged;
  final int filterType;
  final double filterCutoffHz;
  final Future<void> Function(int type, double cutoffHz) onFilterChanged;
  final Future<void> Function(Duration position) onJogSeek;
  final Future<void> Function(bool active, double velocity, Duration anchor) onScratchControl;
  final bool loopActive;
  final Duration? loopStart, loopEnd;
  final Future<void> Function(Duration start, Duration end)? onSetLoopRange;
  final Future<void> Function()? onClearLoop;
  final double progress;
  final Duration position, duration;
  final Future<DjTrackProfile?>? profileFuture;
  final String? expectedSongId;
  final String? waveformSourceKey;
  final Future<List<DjWaveformChunk>> Function(int startMs, int endMs)? waveformLoader;

  @override
  State<_ConsoleDeck> createState() => _ConsoleDeckState();
}

class _ConsoleDeckState extends State<_ConsoleDeck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _platterRotation;
  Future<List<DjWaveformChunk>>? _waveformFuture;
  int? _requestedStartMs;
  int? _requestedEndMs;
  double _viewportWidth = 0;
  Object? _overviewSourceIdentity;
  int? _overviewDurationMs;
  double? _overviewWidth;
  List<DjWaveformSegment> _overviewSegments = const <DjWaveformSegment>[];
  double _channelGain = 1.0;
  bool _channelGainDragging = false;
  late List<double> _eqGains;
  int _filterType = 0;
  double _filterCutoffHz = 1000.0;
  bool _filterDragging = false;
  final List<bool> _eqDragging = <bool>[false, false, false];
  double? _jogLastAngle;
  double _jogAccumulatedRadians = 0;
  Duration? _jogStartPosition;
  Duration? _jogPreviewPosition;
  String? _jogSongId;
  int _jogLastUpdateUs = 0;
  final Stopwatch _scratchClock = Stopwatch();
  Timer? _scratchHoldTimer;
  Timer? _scratchDispatchTimer;
  bool _scratchDispatchInFlight = false;
  ({bool active, double velocity, Duration anchor})? _pendingScratchControl;
  Duration? _loopInPreview;
  static const _viewportPolicy = DjWaveformViewportPolicy();

  @override
  void initState() {
    super.initState();
    // A 1.8-second revolution approximates a 33⅓ RPM record. Rotation is
    // decorative during playback; touch-drag is a separate one-shot seek.
    _platterRotation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
    _filterType = widget.filterType;
    _filterCutoffHz = widget.filterCutoffHz;
    _eqGains = List<double>.generate(
      3,
      (index) => index < widget.eqGains.length
          ? widget.eqGains[index].clamp(-12.0, 12.0).toDouble()
          : 0.0,
    );
    _syncPlatterMotion();
  }

  @override
  void didUpdateWidget(covariant _ConsoleDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filterType != widget.filterType && !_filterDragging) _filterType = widget.filterType;
    if (oldWidget.filterCutoffHz != widget.filterCutoffHz && !_filterDragging) _filterCutoffHz = widget.filterCutoffHz;
    if (oldWidget.eqGains != widget.eqGains &&
        !_eqDragging.any((dragging) => dragging)) {
      _eqGains = List<double>.generate(
        3,
        (index) => index < widget.eqGains.length
            ? widget.eqGains[index].clamp(-12.0, 12.0).toDouble()
            : 0.0,
      );
    }
    if (!widget.canAdjustChannelGain) {
      // Drop a local preview if a native transition takes ownership of gain.
      _channelGainDragging = false;
      _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
    } else if (!_channelGainDragging &&
        oldWidget.channelGain != widget.channelGain) {
      _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
    }
    if (_jogStartPosition != null &&
        (!widget.jogSeekEnabled || !widget.active || !widget.isPlaying ||
            oldWidget.expectedSongId != widget.expectedSongId ||
            oldWidget.waveformSourceKey != widget.waveformSourceKey ||
            oldWidget.duration != widget.duration)) {
      _abortJogScratch();
    }
    if (oldWidget.waveformRevision != widget.waveformRevision) {
      _requestedStartMs = null;
      _requestedEndMs = null;
      _waveformFuture = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestVisibleWaveform();
      });
    }
    if (oldWidget.expectedSongId != widget.expectedSongId) {
      _loopInPreview = null;
      _platterRotation.value = 0;
      _requestedStartMs = null;
      _requestedEndMs = null;
      _waveformFuture = null;
    }
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.active != widget.active ||
        oldWidget.jogSeekEnabled != widget.jogSeekEnabled ||
        oldWidget.expectedSongId != widget.expectedSongId) {
      _syncPlatterMotion();
    }
    if (oldWidget.waveformSourceKey != widget.waveformSourceKey ||
        oldWidget.duration != widget.duration) {
      _requestedStartMs = null;
      _requestedEndMs = null;
      _waveformFuture = null;
    }
  }

  void _requestVisibleWaveform() {
    final loader = widget.waveformLoader;
    final durationMs = widget.duration.inMilliseconds;
    if (loader == null || durationMs <= 0 || _viewportWidth <= 0) return;
    final range = _viewportPolicy.visibleRange(
      durationMs: durationMs,
      viewportWidth: _viewportWidth,
      scrollOffset: 0,
    );
    if (range == null) return;
    final startMs = range.startMs;
    final endMs = range.endMs;
    if (startMs == _requestedStartMs && endMs == _requestedEndMs) return;
    _requestedStartMs = startMs;
    _requestedEndMs = endMs;
    final next = loader(startMs, endMs);
    if (mounted) setState(() => _waveformFuture = next);
  }

  void _beginJog(Offset localPosition, Offset center) {
    if (!widget.jogSeekEnabled || !widget.isPlaying || !widget.active ||
        widget.expectedSongId == null || widget.duration <= Duration.zero) {
      return;
    }
    _jogLastAngle = math.atan2(
      localPosition.dy - center.dy,
      localPosition.dx - center.dx,
    );
    _jogAccumulatedRadians = 0;
    _jogStartPosition = widget.position;
    _jogPreviewPosition = widget.position;
    _jogSongId = widget.expectedSongId;
    _scratchClock
      ..reset()
      ..start();
    _jogLastUpdateUs = 0;
    _queueScratchControl(active: true, velocity: 0, anchor: widget.position);
    _platterRotation.stop();
    setState(() {});
  }

  void _updateJog(Offset localPosition, Offset center) {
    final previous = _jogLastAngle;
    final start = _jogStartPosition;
    if (previous == null || start == null || _jogSongId != widget.expectedSongId) {
      return;
    }
    final angle = math.atan2(
      localPosition.dy - center.dy,
      localPosition.dx - center.dx,
    );
    final deltaRadians = DjConsoleJogSeekPolicy.normalizedAngleDelta(
      angle - previous,
    );
    _jogAccumulatedRadians += deltaRadians;
    _jogLastAngle = angle;
    // One platter revolution represents 1.8 seconds at 33⅓ RPM. The
    // resulting source/output ratio is the signed scratch velocity.
    const platterRevolutionMs = 1800.0;
    final deltaMediaMs = deltaRadians / (math.pi * 2) * platterRevolutionMs;
    final elapsedUs = _scratchClock.elapsedMicroseconds;
    final deltaUs = elapsedUs - _jogLastUpdateUs;
    _jogLastUpdateUs = elapsedUs;
    final velocity = deltaUs <= 0
        ? 0.0
        : (deltaMediaMs * 1000 / deltaUs).clamp(-4.0, 4.0).toDouble();
    final totalMediaMs = (_jogAccumulatedRadians / (math.pi * 2) * platterRevolutionMs).round();
    final next = Duration(
      milliseconds: (start.inMilliseconds + totalMediaMs)
          .clamp(0, widget.duration.inMilliseconds)
          .toInt(),
    );
    _queueScratchControl(active: true, velocity: velocity, anchor: next);
    _scratchHoldTimer?.cancel();
    _scratchHoldTimer = Timer(const Duration(milliseconds: 90), () {
      if (_jogStartPosition != null && mounted) {
        _queueScratchControl(
          active: true,
          velocity: 0,
          anchor: _jogPreviewPosition ?? start,
        );
      }
    });
    setState(() => _jogPreviewPosition = next);
  }

  void _queueScratchControl({
    required bool active,
    required double velocity,
    required Duration anchor,
  }) {
    _pendingScratchControl = (
      active: active,
      velocity: velocity.clamp(-4.0, 4.0).toDouble(),
      anchor: anchor,
    );
    if (_scratchDispatchInFlight || _scratchDispatchTimer?.isActive == true) return;
    _scratchDispatchTimer = Timer(
      const Duration(milliseconds: 32),
      _flushScratchControl,
    );
  }

  Future<void> _flushScratchControl() async {
    _scratchDispatchTimer = null;
    if (_scratchDispatchInFlight) return;
    final command = _pendingScratchControl;
    if (command == null) return;
    _pendingScratchControl = null;
    _scratchDispatchInFlight = true;
    try {
      await widget.onScratchControl(
        command.active,
        command.velocity,
        command.anchor,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Platter scratch was not applied: $error')),
        );
      }
    } finally {
      _scratchDispatchInFlight = false;
      if (_pendingScratchControl != null && mounted) {
        _scratchDispatchTimer = Timer(
          const Duration(milliseconds: 8),
          _flushScratchControl,
        );
      }
    }
  }

  void _releaseJogScratch() {
    final anchor = _jogPreviewPosition ?? _jogStartPosition ?? widget.position;
    _scratchHoldTimer?.cancel();
    _scratchClock.stop();
    _queueScratchControl(active: false, velocity: 1, anchor: anchor);
  }

  void _cancelJog() {
    if (_jogStartPosition == null) return;
    _releaseJogScratch();
    _clearJog();
    _syncPlatterMotion();
    if (mounted) setState(() {});
  }

  void _abortJogScratch() {
    // Pause, track replacement or transition invalidates the gesture. Drop
    // debounced controls; native lifecycle/transition barriers retire the
    // mailbox so a delayed active command cannot restart the old platter.
    _scratchHoldTimer?.cancel();
    _scratchDispatchTimer?.cancel();
    _pendingScratchControl = null;
    _scratchClock.stop();
    _clearJog();
  }

  void _clearJog() {
    _scratchHoldTimer?.cancel();
    _jogLastAngle = null;
    _jogAccumulatedRadians = 0;
    _jogStartPosition = null;
    _jogPreviewPosition = null;
    _jogSongId = null;
  }

  Future<void> _finishJog() async {
    if (_jogStartPosition == null) return;
    _releaseJogScratch();
    _clearJog();
    _syncPlatterMotion();
    if (mounted) setState(() {});
  }

  String _format(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _commitChannelGain(double value) async {
    if (!widget.canAdjustChannelGain) {
      if (mounted) {
        setState(() {
          _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
          _channelGainDragging = false;
        });
      }
      return;
    }
    try {
      await widget.onChannelGainChanged(value);
      if (!mounted) return;
      setState(() {
        _channelGain = value;
        _channelGainDragging = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
        _channelGainDragging = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Channel gain was not applied: $error')),
      );
    }
  }

  Future<void> _commitEq(int band, double value) async {
    if (band < 0 || band >= 3 || !widget.canAdjustEq) return;
    final next = List<double>.of(_eqGains);
    next[band] = value.clamp(-12.0, 12.0).toDouble();
    try {
      await widget.onEqChanged(next);
      if (!mounted) return;
      setState(() {
        _eqGains = next;
        _eqDragging[band] = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _eqGains = List<double>.of(widget.eqGains);
        _eqDragging[band] = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deck EQ was not applied: $error')),
      );
    }
  }

  Future<void> _commitFilter({int? type, double? cutoffHz}) async {
    final nextType = type ?? _filterType;
    final nextCutoff = cutoffHz ?? _filterCutoffHz;
    if (!widget.canAdjustEq) return;
    try {
      await widget.onFilterChanged(nextType, nextCutoff);
      if (!mounted) return;
      setState(() { _filterType = nextType; _filterCutoffHz = nextCutoff; _filterDragging = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _filterType = widget.filterType; _filterCutoffHz = widget.filterCutoffHz; _filterDragging = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deck filter was not applied: $error')));
    }
  }

  Future<void> _setLoopIn() async {
    if (widget.onSetLoopRange == null) return;
    if (widget.loopActive && widget.onClearLoop != null) {
      try {
        await widget.onClearLoop!();
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Existing loop could not be cleared: $error')),
        );
        return;
      }
    }
    if (mounted) setState(() => _loopInPreview = widget.position);
  }

  Future<void> _setLoopOut() async {
    final start = _loopInPreview;
    final end = widget.position;
    if (start == null || widget.onSetLoopRange == null) return;
    if (end - start < const Duration(milliseconds: 120) ||
        (widget.duration > Duration.zero &&
            end >= widget.duration - const Duration(milliseconds: 40))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Set LOOP OUT at least 120 ms after LOOP IN and before the track end.'),
      ));
      return;
    }
    try {
      await widget.onSetLoopRange!(start, end);
      if (mounted) setState(() => _loopInPreview = null);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loop was not engaged: $error')),
      );
    }
  }

  Future<void> _exitLoop() async {
    if (widget.onClearLoop == null) return;
    try {
      await widget.onClearLoop!();
      if (mounted) setState(() => _loopInPreview = null);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loop could not be cleared: $error')),
      );
    }
  }

  void _showTrackAnalysis(DjTrackProfile? profile) {
    if (profile == null || profile.songId != widget.expectedSongId) return;
    final grid = profile.beatGrid;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101923),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Text('${widget.deck} · BEATGRID & TRACK ANALYSIS',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900, letterSpacing: .8)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ]),
              _ConsoleAnalysisStrip(
                profile: profile,
                positionMs: widget.position.inMilliseconds,
                compact: false,
              ),
              const SizedBox(height: 12),
              _analysisDetailRow('BEATGRID CONFIDENCE',
                '${(grid.confidence * 100).round()}%'),
              _analysisDetailRow('FIRST BEAT',
                grid.firstBeatMs == null ? '—' : '${(grid.firstBeatMs! / 1000).toStringAsFixed(2)} s'),
              _analysisDetailRow('BEATS PER BAR', '${grid.beatsPerBar}'),
              _analysisDetailRow('DOWNBEAT CONFIDENCE',
                '${(grid.downbeatConfidence * 100).round()}%'),
              _analysisDetailRow('BAR / PHRASE CONFIDENCE',
                '${(grid.barConfidence * 100).round()}% / ${(grid.phraseConfidence * 100).round()}%'),
              _analysisDetailRow('DETECTED SECTIONS', '${profile.sections.length}'),
              _analysisDetailRow('WAVEFORM CHUNKS', '${profile.waveformSegments.length} profile segments'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analysisDetailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(
        color: const Color(0xB8FFFFFF), fontSize: 11, fontWeight: FontWeight.w800))),
      Text(value, style: const TextStyle(
        color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
    ]),
  );

  Future<void> _showDeckTools() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101923),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refreshSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Text('${widget.deck} · CHANNEL TOOLS',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900, letterSpacing: 1.1)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ]),
                Row(children: [
                  const SizedBox(width: 58, child: Text('GAIN')),
                  Expanded(child: Slider(
                    value: _channelGain.clamp(0.0, 1.0).toDouble(),
                    min: 0, max: 1, divisions: 40,
                    onChanged: widget.canAdjustChannelGain ? (value) {
                      setState(() { _channelGainDragging = true; _channelGain = value; });
                      refreshSheet(() {});
                    } : null,
                    onChangeEnd: widget.canAdjustChannelGain
                        ? (value) => unawaited(_commitChannelGain(value)) : null,
                  )),
                  SizedBox(width: 42, child: Text('${(_channelGain * 100).round()}%',
                    textAlign: TextAlign.end)),
                ]),
                const Divider(color: Colors.white12),
                Row(children: List<Widget>.generate(3, (index) {
                  const labels = ['LOW', 'MID', 'HIGH'];
                  final value = _eqGains[index].clamp(-12.0, 12.0).toDouble();
                  return Expanded(child: Padding(
                    padding: EdgeInsets.only(right: index == 2 ? 0 : 8),
                    child: Column(children: [
                      Text(labels[index], style: const TextStyle(
                        color: Colors.white70, fontWeight: FontWeight.w900)),
                      Text('${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} dB',
                        style: TextStyle(color: value == 0 ? const Color(0xB8FFFFFF) : Theme.of(context).colorScheme.primary)),
                      Slider(
                        value: value, min: -12, max: 12, divisions: 48,
                        onChanged: widget.canAdjustEq ? (next) {
                          setState(() { _eqDragging[index] = true; _eqGains[index] = next; });
                          refreshSheet(() {});
                        } : null,
                        onChangeEnd: widget.canAdjustEq
                            ? (next) => unawaited(_commitEq(index, next)) : null,
                      ),
                    ]),
                  ));
                })),
                const Divider(color: Colors.white12),
                Row(children: [
                  const Text('FILTER', style: TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(width: 12),
                  for (final option in const [(0, 'OFF'), (3, 'LOW-PASS'), (4, 'HIGH-PASS')])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(option.$2),
                        selected: _filterType == option.$1,
                        onSelected: widget.canAdjustEq ? (_) {
                          unawaited(_commitFilter(type: option.$1));
                          refreshSheet(() {});
                        } : null,
                      ),
                    ),
                ]),
                Row(children: [
                  const SizedBox(width: 58, child: Text('CUTOFF')),
                  Expanded(child: Slider(
                    value: (math.log(_filterCutoffHz / 40.0) /
                        math.log(18000.0 / 40.0)).clamp(0.0, 1.0),
                    min: 0, max: 1, divisions: 100,
                    onChanged: widget.canAdjustEq && _filterType != 0 ? (value) {
                      setState(() {
                        _filterDragging = true;
                        _filterCutoffHz = (40.0 * math.pow(18000.0 / 40.0, value)).toDouble();
                      });
                      refreshSheet(() {});
                    } : null,
                    onChangeEnd: widget.canAdjustEq && _filterType != 0
                        ? (_) => unawaited(_commitFilter()) : null,
                  )),
                  SizedBox(width: 56, child: Text(
                    _filterType == 0 ? '—' : '${_filterCutoffHz.round()} Hz',
                    textAlign: TextAlign.end)),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _togglePlayback() async {
    try {
      final wasPlaying = widget.isPlaying;
      await widget.onPlayPause();
      if (wasPlaying) widget.onEnsureWaveform?.call();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deck transport was not applied: $error')),
      );
    }
  }

  void _syncPlatterMotion() {
    // Eligibility includes the no-transition guard. If a transition starts
    // during a drag, didUpdateWidget clears the gesture and this stops the
    // decorative platter; it resumes automatically when the active deck is
    // eligible again.
    if (widget.jogSeekEnabled && widget.isPlaying && widget.active) {
      _platterRotation.repeat();
    } else {
      _platterRotation.stop();
    }
  }

  @override
  void dispose() {
    _scratchHoldTimer?.cancel();
    _scratchDispatchTimer?.cancel();
    if (_jogStartPosition != null) {
      unawaited(widget.onScratchControl(
        false,
        1,
        _jogPreviewPosition ?? _jogStartPosition ?? widget.position,
      ).catchError((Object _) {}));
    }
    _scratchClock.stop();
    _platterRotation.dispose();
    super.dispose();
  }

  String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _showCuePadActions(int index) async {
    final cue = index < widget.hotCuePositions.length
        ? widget.hotCuePositions[index]
        : null;
    if (cue == null) {
      widget.onSetHotCue?.call(index);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Cue ${index + 1} · ${_format(cue)}'),
        content: const Text('Replace this cue with the current playhead or clear it?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'clear'),
            child: const Text('CLEAR'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'replace'),
            child: const Text('REPLACE'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'replace') {
      widget.onSetHotCue?.call(index);
    } else if (action == 'clear') {
      widget.onClearHotCue?.call(index);
    }
  }

  Widget _buildCuePad(int index, Color accent) {
    final cue = index < widget.hotCuePositions.length
        ? widget.hotCuePositions[index]
        : null;
    return SizedBox(
      width: 44,
      height: 42,
      child: GestureDetector(
        onLongPress: widget.onSetHotCue == null && widget.onClearHotCue == null
            ? null
            : () => unawaited(_showCuePadActions(index)),
        child: OutlinedButton(
          onPressed: cue == null
              ? (widget.onSetHotCue == null
                  ? null
                  : () => widget.onSetHotCue!(index))
              : (widget.onHotCue == null
                  ? null
                  : () => widget.onHotCue!(index)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            minimumSize: Size.zero,
            side: BorderSide(
              color: cue == null ? Colors.white24 : accent.withValues(alpha: .7),
            ),
            foregroundColor: cue == null ? Colors.white70 : accent,
            backgroundColor: cue == null
                ? Colors.white.withValues(alpha: .025)
                : accent.withValues(alpha: .10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'CUE ${index + 1}',
                style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900),
              ),
              Text(
                cue == null ? '—' : _format(cue),
                style: const TextStyle(fontSize: 8),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.deck.endsWith('A')
        ? const Color(0xFF55D6BE)
        : const Color(0xFF8EA7FF);
    final onAir = widget.onAir;
    final compact = widget.compact;
    final active = widget.active;
    final deck = widget.deck;
    final status = widget.status;
    final title = widget.title;
    final artist = widget.artist;
    final progress = widget.progress;
    final position = widget.position;
    final duration = widget.duration;
    final profileFuture = widget.profileFuture;
    final expectedSongId = widget.expectedSongId;
    final waveformFuture = _waveformFuture;
    return Container(
      padding: EdgeInsets.all(compact ? 6 : 9),
      decoration: BoxDecoration(
        color: const Color(0xFF101923),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accent.withValues(alpha: onAir ? .82 : (active ? .30 : .16)),
          width: onAir ? 2 : 1,
        ),
        boxShadow: onAir
            ? [BoxShadow(color: accent.withValues(alpha: .14), blurRadius: 22)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text(deck, style: theme.textTheme.labelLarge?.copyWith(
              color: accent, letterSpacing: 1.8, fontWeight: FontWeight.w800)),
            const Spacer(),
            _ConsoleStatus(label: status, active: onAir),
          ]),
          const SizedBox(height: 4),
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xBFFFFFFF))),
          const SizedBox(height: 3),
          FutureBuilder<DjTrackProfile?>(
            future: profileFuture,
            builder: (context, profileSnapshot) {
              final profile = profileSnapshot.data;
              final verifiedProfile = profile != null &&
                      expectedSongId != null &&
                      profile.songId == expectedSongId
                  ? profile
                  : null;
              final legacySegments = verifiedProfile?.waveformSegments ??
                  const <DjWaveformSegment>[];
              final beatGrid = verifiedProfile?.beatGrid;
              final sections = verifiedProfile?.sections ?? const <DjSection>[];
              return LayoutBuilder(
                builder: (context, waveformConstraints) {
                  _viewportWidth = waveformConstraints.maxWidth;
                  if (_requestedStartMs == null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _requestVisibleWaveform();
                    });
                  }
                  final contentWidth = _viewportPolicy.visibleRange(
                    durationMs: duration.inMilliseconds,
                    viewportWidth: waveformConstraints.maxWidth,
                    scrollOffset: 0,
                  )?.contentWidth ?? waveformConstraints.maxWidth;
                  return FutureBuilder<List<DjWaveformChunk>>(
                key: ObjectKey(waveformFuture),
                future: waveformFuture,
                builder: (context, waveformSnapshot) {
                  final chunks = (waveformSnapshot.data ?? const <DjWaveformChunk>[])
                      .where((chunk) =>
                          chunk.songId == expectedSongId &&
                          chunk.durationMs == duration.inMilliseconds)
                      .toList(growable: false);
                  final measuredSegments = chunks
                      .map((chunk) => DjWaveformSegment(
                            startMs: chunk.actualStartMs,
                            endMs: chunk.actualEndMs,
                            peaks: chunk.peaks,
                          ))
                      .toList(growable: false);
                  final segments = measuredSegments.isNotEmpty
                      ? measuredSegments
                      : legacySegments;
                  final overviewSourceIdentity = measuredSegments.isNotEmpty
                      ? waveformSnapshot.data
                      : verifiedProfile;
                  if (!identical(_overviewSourceIdentity, overviewSourceIdentity) ||
                      _overviewDurationMs != duration.inMilliseconds ||
                      _overviewWidth != waveformConstraints.maxWidth) {
                    _overviewSourceIdentity = overviewSourceIdentity;
                    _overviewDurationMs = duration.inMilliseconds;
                    _overviewWidth = waveformConstraints.maxWidth;
                    _overviewSegments = _viewportPolicy.overviewSegments(
                      segments: segments,
                      durationMs: duration.inMilliseconds,
                      viewportWidth: waveformConstraints.maxWidth,
                    );
                  }
                  final overviewSegments = _overviewSegments;
                  final waveformState = DjConsoleWaveformStatus.classify(
                    snapshot: waveformSnapshot,
                    expectedSongId: expectedSongId,
                    durationMs: duration.inMilliseconds,
                    visibleStartMs: _requestedStartMs ?? 0,
                    visibleEndMs: _requestedEndMs ?? duration.inMilliseconds,
                    legacyAvailable: legacySegments.isNotEmpty,
                    profileLoading: profileSnapshot.connectionState == ConnectionState.waiting,
                    profileIdentityMismatch: profile != null && verifiedProfile == null,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: compact ? 22 : 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFF080E15),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Stack(fit: StackFit.expand, children: [
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: widget.jogSeekEnabled && duration > Duration.zero
                                ? (details) {
                                    final width = waveformConstraints.maxWidth;
                                    if (width <= 0) return;
                                    final fraction = (details.localPosition.dx / width)
                                        .clamp(0.0, 1.0);
                                    final target = Duration(
                                      milliseconds: (duration.inMilliseconds * fraction).round(),
                                    );
                                    unawaited(widget.onJogSeek(target));
                                  }
                                : null,
                            child: SizedBox(
                              width: contentWidth,
                              height: compact ? 22 : 30,
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  painter: _ConsoleWavePainter(
                                    progress: progress,
                                    color: accent,
                                    segments: overviewSegments,
                                    beatGrid: beatGrid,
                                    sections: sections,
                                    durationMs: duration.inMilliseconds,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 7,
                            top: 4,
                            child: DjConsoleWaveformStatus(
                              state: waveformState,
                              chunkCount: measuredSegments.length,
                            ),
                          ),
                          Positioned(
                            right: 2,
                            top: 0,
                            child: IconButton(
                              tooltip: 'Beatgrid and track analysis',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints.tightFor(width: 30, height: 28),
                              padding: EdgeInsets.zero,
                              onPressed: verifiedProfile == null
                                  ? null
                                  : () => _showTrackAnalysis(verifiedProfile),
                              icon: const Icon(Icons.analytics_outlined, size: 16),
                            ),
                          ),
                        ]),
                      ),

                    ],
                  );
                },
              );
                },
              );
            },
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, stageConstraints) {
                final availableWheelWidth =
                    stageConstraints.maxWidth.clamp(1.0, 480.0);
                final diameter = math.min(
                  stageConstraints.maxHeight,
                  availableWheelWidth,
                ).clamp(1.0, 420.0).toDouble();
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: SizedBox.square(
                        dimension: diameter,
                        child: AnimatedBuilder(
                          animation: _platterRotation,
                          builder: (context, child) => Transform.rotate(
                            angle: _platterRotation.value * math.pi * 2,
                            child: child,
                          ),
                          child: LayoutBuilder(
                            builder: (context, platterConstraints) {
                              final center = Offset(
                                platterConstraints.maxWidth / 2,
                                platterConstraints.maxHeight / 2,
                              );
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: widget.jogSeekEnabled
                                    ? (details) => _beginJog(details.localPosition, center)
                                    : null,
                                onPanUpdate: widget.jogSeekEnabled
                                    ? (details) => _updateJog(details.localPosition, center)
                                    : null,
                                onPanEnd: widget.jogSeekEnabled
                                    ? (_) => _finishJog()
                                    : null,
                                onPanCancel: _cancelJog,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: const RadialGradient(
                                          colors: [
                                            Color(0xFF344353),
                                            Color(0xFF111923),
                                            Color(0xFF080D13),
                                          ],
                                        ),
                                        border: Border.all(
                                          color: accent.withValues(alpha: .48),
                                          width: 2,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: .4),
                                            blurRadius: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: _ConsoleRecordDetailPainter(accent: accent),
                                      ),
                                    ),
                                    Container(
                                      width: diameter * .34,
                                      height: diameter * .34,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFF182431),
                                        border: Border.all(
                                          color: accent.withValues(alpha: .7),
                                          width: 2,
                                        ),
                                      ),
                                      child: Icon(
                                        Icons.album,
                                        color: accent,
                                        size: diameter * .18,
                                      ),
                                    ),
                                    Positioned(
                                      bottom: diameter * .12,
                                      child: Text(
                                        _jogPreviewPosition == null
                                            ? (widget.jogSeekEnabled ? 'DRAG TO SEEK' : 'PLATTER')
                                            : 'SEEK ${_time(_jogPreviewPosition!)}',
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: _jogPreviewPosition == null
                                              ? Colors.white70
                                              : accent,
                                          fontSize: compact ? 7 : 9,
                                          letterSpacing: 1.0,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Row(
            children: [
              ...List<Widget>.generate(DjCuePointStore.slotCount, (index) =>
                Expanded(child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _buildCuePad(index, accent),
                )),
              ),
              Expanded(
                child: PopupMenuButton<String>(
                  enabled: widget.onSetLoopRange != null || widget.loopActive,
                  tooltip: 'A/B loop controls',
                  onSelected: (action) {
                    switch (action) {
                      case 'in':
                        unawaited(_setLoopIn());
                        break;
                      case 'out':
                        unawaited(_setLoopOut());
                        break;
                      case 'exit':
                        unawaited(_exitLoop());
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'in',
                      enabled: widget.onSetLoopRange != null,
                      child: const Text('Set LOOP IN at playhead'),
                    ),
                    PopupMenuItem<String>(
                      value: 'out',
                      enabled: widget.onSetLoopRange != null && _loopInPreview != null,
                      child: const Text('Set LOOP OUT and engage'),
                    ),
                    PopupMenuItem<String>(
                      value: 'exit',
                      enabled: widget.loopActive && widget.onClearLoop != null,
                      child: const Text('Exit active loop'),
                    ),
                  ],
                  child: Container(
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: widget.loopActive
                          ? accent.withValues(alpha: .15)
                          : const Color(0xFF080E15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: accent.withValues(alpha: widget.loopActive ? .75 : .35),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('LOOP', style: TextStyle(
                          color: accent, fontSize: 9, fontWeight: FontWeight.w900)),
                        Text(
                          widget.loopActive && widget.loopStart != null && widget.loopEnd != null
                              ? '${_format(widget.loopStart!)}–${_format(widget.loopEnd!)}'
                              : _loopInPreview != null
                                  ? 'IN SET'
                                  : 'A/B',
                          style: const TextStyle(color: Colors.white70, fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(children: [
            IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 42, height: 38),
              onPressed: widget.canPlay ? _togglePlayback : null,
              icon: Icon(widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
              tooltip: widget.isPlaying ? 'Pause deck' : 'Play deck',
            ),
            const SizedBox(width: 5),
            Expanded(child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: widget.active ? _showDeckTools : null,
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: const Text('CHANNEL TOOLS', style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w900)),
            )),
          ]),
          const SizedBox(height: 2),
          Row(children: [
            Text(_time(position), style: theme.textTheme.labelSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()])),
            const Spacer(),
            Text(duration > Duration.zero ? _time(duration) : '--:--',
              style: theme.textTheme.labelSmall?.copyWith(color: const Color(0xB8FFFFFF))),
          ]),
          Row(
            children: [
              Expanded(child: DjConsoleDeckTempoControl(
                physicalDeckId: deck.endsWith('A') ? 'A' : 'B',
                compact: compact,
              )),
              const SizedBox(width: 3),
              IconButton(
                tooltip: 'Sync tempo to the other deck',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onSync,
                icon: const Icon(Icons.sync_rounded, size: 19),
                color: accent,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
class _DjConsoleMixer extends StatefulWidget {
  const _DjConsoleMixer({
    required this.enabled,
    required this.position,
    required this.compact,
    required this.statusMessage,
    required this.onChanged,
    required this.onLoadA,
    required this.onLoadB,
    required this.onGestureStart,
    required this.onGestureEnd,
  });

  final bool enabled;
  final double position;
  final bool compact;
  final String statusMessage;
  final VoidCallback? onLoadA;
  final VoidCallback? onLoadB;
  final Future<void> Function(double position) onChanged;
  final Future<bool> Function() onGestureStart;
  final Future<void> Function() onGestureEnd;

  @override
  State<_DjConsoleMixer> createState() => _DjConsoleMixerState();
}

class _DjConsoleMixerState extends State<_DjConsoleMixer> {
  Timer? _writeTimer;
  double? _pendingPosition;
  late double _position;
  bool _dragging = false;
  bool _gestureReady = false;
  Future<bool>? _gestureStartFuture;
  bool _writeInFlight = false;
  Completer<void>? _writeSettled;

  @override
  void initState() {
    super.initState();
    _position = widget.position.clamp(0.0, 1.0).toDouble();
  }

  @override
  void didUpdateWidget(covariant _DjConsoleMixer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      // Losing native preconditions cancels the whole gesture, not just its
      // debounce timer. The provider releases retained authority after any
      // asynchronous acquisition has settled.
      _cancelGesture(oldWidget.onGestureEnd);
      _position = widget.position.clamp(0.0, 1.0).toDouble();
      return;
    }
    if (_pendingPosition == null && !_dragging) {
      _position = widget.position.clamp(0.0, 1.0).toDouble();
    }
  }

  Future<void> _startGesture() async {
    _gestureReady = false;
    final start = widget.onGestureStart();
    _gestureStartFuture = start;
    final accepted = await start;
    if (!mounted) {
      await widget.onGestureEnd();
      return;
    }
    if (!accepted || !widget.enabled) {
      _pendingPosition = null;
      _gestureReady = false;
      _writeTimer?.cancel();
      _writeTimer = null;
      _position = widget.position.clamp(0.0, 1.0).toDouble();
      return;
    }
    _gestureReady = true;
    if (_pendingPosition != null && _dragging) {
      await _flushWrite();
    }
  }

  void _queueWrite(double value) {
    _pendingPosition = value;
    _writeTimer ??= Timer(const Duration(milliseconds: 28), () {
      unawaited(_flushWrite());
    });
  }

  Future<void> _flushWrite() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    if (!_gestureReady || !widget.enabled || _writeInFlight) return;

    // Keep a single native write in flight while coalescing intermediate
    // slider positions to the latest value. This prevents asynchronous
    // MethodChannel completions from applying stale positions out of order.
    while (_gestureReady && widget.enabled) {
      final value = _pendingPosition;
      if (value == null) return;
      _pendingPosition = null;
      _writeInFlight = true;
      final settled = Completer<void>();
      _writeSettled = settled;
      try {
        await widget.onChanged(value);
      } catch (error) {
        _gestureReady = false;
        _pendingPosition = null;
        _dragging = false;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Crossfader update was not applied: $error')),
          );
        }
        await widget.onGestureEnd();
        return;
      } finally {
        _writeInFlight = false;
        if (!settled.isCompleted) settled.complete();
        if (identical(_writeSettled, settled)) _writeSettled = null;
      }
    }
  }

  Future<void> _finishGesture(double finalValue) async {
    final start = _gestureStartFuture;
    if (start != null) {
      final accepted = await start;
      if (!accepted) {
        _pendingPosition = null;
      } else if (widget.enabled) {
        _gestureReady = true;
        _pendingPosition = finalValue;
        // Wait for the last coalesced write to settle before releasing the
        // gesture lease. No late write can escape after gesture completion.
        while (_writeInFlight) {
          final settled = _writeSettled?.future;
          if (settled == null) break;
          await settled;
        }
        await _flushWrite();
      }
    }
    _gestureReady = false;
    _gestureStartFuture = null;
    await widget.onGestureEnd();
  }

  void _cancelGesture(Future<void> Function() release) {
    _writeTimer?.cancel();
    _writeTimer = null;
    _pendingPosition = null;
    _dragging = false;
    _gestureReady = false;
    final start = _gestureStartFuture;
    _gestureStartFuture = null;
    unawaited(() async {
      if (start != null) await start;
      await release();
    }());
  }

  @override
  void dispose() {
    // A route teardown is not a gesture completion. Wait for a pending lease
    // acquisition, then release it; never dispatch the queued slider value.
    _writeTimer?.cancel();
    _pendingPosition = null;
    final start = _gestureStartFuture;
    _gestureStartFuture = null;
    if (start != null) {
      unawaited(() async {
        await start;
        await widget.onGestureEnd();
      }());
    } else if (_gestureReady) {
      unawaited(widget.onGestureEnd());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      padding: EdgeInsets.all(widget.compact ? 8 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF101923),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: .3)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.tune_rounded, color: accent, size: widget.compact ? 20 : 25),
          const SizedBox(height: 7),
          Text('MIXER',
              style: theme.textTheme.labelLarge?.copyWith(
                letterSpacing: 1.4,
                fontWeight: FontWeight.w900,
              )),
          const SizedBox(height: 3),
          const SizedBox(height: 4),
          Text(
            'TRACK LIBRARY',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: const Color(0xFFD4DEE9),
              fontSize: widget.compact ? 8 : 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(
              tooltip: 'Load Deck A from Track Library',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 42, height: 34),
              onPressed: widget.onLoadA,
              icon: const Icon(Icons.library_music_rounded, size: 18),
            ),
            IconButton(
              tooltip: 'Load Deck B from Track Library',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 42, height: 34),
              onPressed: widget.onLoadB,
              icon: const Icon(Icons.library_music_rounded, size: 18),
            ),
          ]),
          const SizedBox(height: 3),
          Row(
            children: [
              Text('A', style: theme.textTheme.labelLarge),
              const Spacer(),
              Text('B', style: theme.textTheme.labelLarge),
            ],
          ),
          RotatedBox(
            quarterTurns: 0,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: widget.compact ? 4 : 5,
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white24,
                disabledActiveTrackColor: accent.withValues(alpha: .55),
                disabledInactiveTrackColor: Colors.white24,
                disabledThumbColor: accent.withValues(alpha: .8),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: widget.compact ? 9 : 11,
                  disabledThumbRadius: widget.compact ? 9 : 11,
                ),
              ),
              child: Slider(
                min: 0,
                max: 1,
                divisions: 100,
                value: _position,
                onChangeStart: widget.enabled
                    ? (_) {
                        _dragging = true;
                        unawaited(_startGesture());
                      }
                    : null,
                onChanged: widget.enabled
                    ? (value) {
                        setState(() => _position = value);
                        _queueWrite(value);
                      }
                    : null,
                onChangeEnd: widget.enabled
                    ? (value) {
                        _dragging = false;
                        _writeTimer?.cancel();
                        _writeTimer = null;
                        unawaited(_finishGesture(value));
                      }
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _position <= 0.01
                ? 'DECK A'
                : _position >= 0.99
                    ? 'DECK B'
                    : 'BLEND',
            style: theme.textTheme.labelSmall?.copyWith(
              color: accent,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            widget.statusMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: const Color(0xB8FFFFFF),
              fontSize: widget.compact ? 8 : 9,
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 8),
          Text(
            'CROSSFADE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white70,
              letterSpacing: .7,
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),

        ],
      ),
    );
  }
}

class _DjTrackPickerSheet extends StatefulWidget {
  const _DjTrackPickerSheet({
    required this.deckId,
    required this.songs,
    required this.currentDeckMediaId,
    required this.otherDeckMediaId,
  });

  final String deckId;
  final List<Song> songs;
  final String? currentDeckMediaId;
  final String? otherDeckMediaId;

  @override
  State<_DjTrackPickerSheet> createState() => _DjTrackPickerSheetState();
}

class _DjTrackPickerSheetState extends State<_DjTrackPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalizedQuery = _query.trim().toLowerCase();
    final filteredSongs = normalizedQuery.isEmpty
        ? widget.songs
        : widget.songs.where((song) {
            return song.title.toLowerCase().contains(normalizedQuery) ||
                song.artist.toLowerCase().contains(normalizedQuery) ||
                song.album.toLowerCase().contains(normalizedQuery);
          }).toList(growable: false);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, controller) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Load Deck ${widget.deckId}',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (widget.songs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: TextField(
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: 'Search title, artist, or album',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () => setState(() => _query = ''),
                            icon: const Icon(Icons.close_rounded),
                          ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: widget.songs.isEmpty
                  ? const Center(
                      child: Text('No music in the shared library yet.'),
                    )
                  : filteredSongs.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No tracks match "${_query.trim()}".',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: controller,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: filteredSongs.length,
                          itemBuilder: (context, index) {
                            final song = filteredSongs[index];
                            final playable = song.filePath.trim().isNotEmpty;
                            final loadedHere =
                                song.id == widget.currentDeckMediaId;
                            final loadedOnOtherDeck =
                                song.id == widget.otherDeckMediaId;
                            final deckLabel = loadedHere
                                ? 'THIS DECK'
                                : loadedOnOtherDeck
                                    ? 'OTHER DECK'
                                    : null;
                            return ListTile(
                              enabled: playable,
                              leading: Icon(
                                loadedHere
                                    ? Icons.check_circle_rounded
                                    : loadedOnOtherDeck
                                        ? Icons.album_rounded
                                        : Icons.music_note_rounded,
                                color: loadedHere || loadedOnOtherDeck
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${song.artist} · ${song.album}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: deckLabel != null
                                  ? Text(
                                      deckLabel,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    )
                                  : playable
                                      ? const Icon(Icons.add_circle_outline_rounded)
                                      : const Icon(Icons.block_rounded),
                              onTap: playable
                                  ? () => Navigator.pop(context, song)
                                  : null,
                            );
                          },
                        ),
            ),
            if (widget.songs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${filteredSongs.length} of ${widget.songs.length} tracks',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConsoleRecordDetailPainter extends CustomPainter {
  const _ConsoleRecordDetailPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    if (radius <= 0) return;

    final groovePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    for (var i = 0; i < 24; i++) {
      final grooveRadius = radius * (0.39 + i * 0.0205);
      groovePaint.color = Colors.white.withValues(
        alpha: i.isEven ? 0.075 : 0.035,
      );
      canvas.drawCircle(center, grooveRadius, groovePaint);
    }

    final markerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 48; i++) {
      final angle = i * math.pi / 24;
      final inner = radius * (i % 4 == 0 ? 0.925 : 0.952);
      final outer = radius * 0.978;
      markerPaint
        ..strokeWidth = i % 4 == 0 ? 1.8 : 1
        ..color = i % 4 == 0
            ? accent.withValues(alpha: 0.7)
            : Colors.white.withValues(alpha: 0.24);
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        markerPaint,
      );
    }

    final labelPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF182431);
    canvas.drawCircle(center, radius * 0.345, labelPaint);
    canvas.drawCircle(
      center,
      radius * 0.345,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = accent.withValues(alpha: 0.42),
    );
  }

  @override
  bool shouldRepaint(covariant _ConsoleRecordDetailPainter oldDelegate) =>
      oldDelegate.accent != accent;
}

class _ConsoleAnalysisStrip extends StatelessWidget {
  const _ConsoleAnalysisStrip({
    required this.profile,
    required this.positionMs,
    required this.compact,
  });

  final DjTrackProfile? profile;
  final int positionMs;
  final bool compact;

  static const _pitchClasses = <String>[
    'C', 'C♯', 'D', 'D♯', 'E', 'F',
    'F♯', 'G', 'G♯', 'A', 'A♯', 'B',
  ];

  String _sectionName(DjSectionType type) {
    switch (type) {
      case DjSectionType.preChorus:
        return 'PRE-CHORUS';
      case DjSectionType.unknown:
        return 'UNKNOWN';
      default:
        return type.name.replaceAllMapped(
          RegExp(r'[A-Z]'),
          (match) => '-${match.group(0)}',
        ).toUpperCase().replaceFirst('-', '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grid = profile?.beatGrid;
    final trustedTempo = grid != null &&
        DjConsoleOverlayPolicy.hasTrustedTempo(grid);
    final tempoValue = grid?.bpm;
    final bpm = trustedTempo && tempoValue != null
        ? tempoValue.toStringAsFixed(1)
        : '—';
    // Capture the nullable widget field in a local final so Dart can
    // promote it safely for all metadata reads below.
    final currentProfile = profile;
    final trustedKey = currentProfile != null &&
        currentProfile.hasKey &&
        currentProfile.keyConfidence >= 0.65;
    final keyRoot = trustedKey ? currentProfile.keyRoot : null;
    final keyMode = trustedKey ? currentProfile.keyMode : null;
    final key = keyRoot != null && keyMode != null
        ? '${_pitchClasses[keyRoot]} ${keyMode.toUpperCase()}'
        : '—';
    final section = currentProfile == null
        ? null
        : DjConsoleOverlayPolicy.trustedSectionAt(
            currentProfile.sections,
            positionMs,
          );
    final nextBeat = grid == null
        ? null
        : DjConsoleOverlayPolicy.nextBeatInMs(grid, positionMs);
    final metrics = <(String, String)>[
      ('TEMPO', trustedTempo ? '$bpm BPM' : '—'),
      ('KEY', key),
      ('SECTION', section == null ? '—' : _sectionName(section.type)),
      ('NEXT BEAT', nextBeat == null
          ? '—'
          : nextBeat == 0
              ? 'NOW'
              : '${(nextBeat / 1000).toStringAsFixed(2)}s'),
    ];

    return Row(
      children: [
        for (var i = 0; i < metrics.length; i++) ...[
          if (i > 0) SizedBox(width: compact ? 4 : 7),
          Expanded(
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 5 : 8,
                vertical: compact ? 5 : 7,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF0B121B),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: Colors.white.withValues(alpha: .07)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    metrics[i].$1,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontSize: compact ? 6 : 7,
                      letterSpacing: .8,
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    metrics[i].$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: compact ? 8 : 10,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFFB9D9D3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ConsoleStatus extends StatelessWidget {
  const _ConsoleStatus({required this.label, required this.active});
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: (active ? const Color(0xFF55D6BE) : Colors.white24).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: (active ? const Color(0xFF55D6BE) : Colors.white24).withValues(alpha: .4)),
    ),
    child: Text(label, style: TextStyle(fontSize: 9, letterSpacing: .7,
      color: active ? const Color(0xFF55D6BE) : const Color(0xBFFFFFFF),
      fontWeight: FontWeight.w800)),
  );
}

class _ConsoleWavePainter extends CustomPainter {
  const _ConsoleWavePainter({
    required this.progress,
    required this.color,
    required this.segments,
    required this.beatGrid,
    required this.sections,
    required this.durationMs,
  });
  final double progress;
  final Color color;
  final List<DjWaveformSegment> segments;
  final DjBeatGrid? beatGrid;
  final List<DjSection> sections;
  final int durationMs;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final baseline = Paint()
      ..color = Colors.white.withValues(alpha: .14)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), baseline);

    if (durationMs > 0) {
      for (final segment in segments) {
        if (segment.endMs <= segment.startMs || segment.peaks.isEmpty) continue;
        final segmentStart = (segment.startMs / durationMs).clamp(0.0, 1.0).toDouble();
        final segmentEnd = (segment.endMs / durationMs).clamp(0.0, 1.0).toDouble();
        final segmentWidth = (segmentEnd - segmentStart) * size.width;
        if (segmentWidth <= 0) continue;
        final paint = Paint()
          ..strokeWidth = math.max(1.0, segmentWidth / segment.peaks.length * .72).toDouble()
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < segment.peaks.length; i++) {
          final x = (segmentStart * size.width) +
              ((i + .5) / segment.peaks.length) * segmentWidth;
          final peak = segment.peaks[i].clamp(0.0, 1.0).toDouble();
          final halfHeight = math.max(1.0, peak * size.height * .43).toDouble();
          final played = x <= size.width * progress;
          paint.color = color.withValues(alpha: played ? .88 : .48);
          canvas.drawLine(
            Offset(x, mid - halfHeight),
            Offset(x, mid + halfHeight),
            paint,
          );
        }
      }
    }
    if (durationMs > 0) {
      for (final section in DjConsoleOverlayPolicy.trustedSections(sections)) {
        final left = (section.startMs / durationMs).clamp(0.0, 1.0) * size.width;
        final right = (section.endMs / durationMs).clamp(0.0, 1.0) * size.width;
        if (right <= left) continue;
        canvas.drawRect(
          Rect.fromLTRB(left, 0, right, size.height),
          Paint()..color = color.withValues(alpha: .055),
        );
      }

      final grid = beatGrid;
      if (grid != null) {
        final beats = DjConsoleOverlayPolicy.beatTicks(grid);
        final bars = DjConsoleOverlayPolicy.barTicks(grid).toSet();
        final phrases = DjConsoleOverlayPolicy.phraseTicks(grid).toSet();
        for (final beat in beats) {
          if (beat < 0 || beat > durationMs) continue;
          final x = beat / durationMs * size.width;
          final isPhrase = phrases.contains(beat);
          final isBar = bars.contains(beat);
          final tickPaint = Paint()
            ..color = color.withValues(
              alpha: isPhrase ? .78 : isBar ? .48 : .19,
            )
            ..strokeWidth = isPhrase ? 2.0 : isBar ? 1.3 : .7;
          canvas.drawLine(
            Offset(x, isPhrase ? 0 : size.height * .16),
            Offset(x, isPhrase ? size.height : size.height * .84),
            tickPaint,
          );
        }
      }
    }

    final playheadX = size.width * progress.clamp(0.0, 1.0);
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      Paint()..color = Colors.white..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ConsoleWavePainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.durationMs != durationMs ||
      old.beatGrid != beatGrid ||
      !identical(old.sections, sections) ||
      !identical(old.segments, segments);
}
