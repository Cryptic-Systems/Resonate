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
import '../providers/dj_mode_provider.dart';
import '../dj_engine/core/dj_types.dart';
import '../ui/resonate_glass.dart';
import 'dj_console_deck_tempo_control.dart';
import 'dj_console_manual_controls_policy.dart';
import 'dj_console_jog_seek_policy.dart';
import 'dj_console_overlay_policy.dart';
import 'dj_console_waveform_status.dart';
import 'dj_waveform_viewport_policy.dart';

/// Landscape-first visual foundation for the future performance console.
///
/// The Console exposes only controls backed by the existing Media3 authority.
/// Jog input is a one-shot active-deck seek on gesture completion; it is not
/// scratching, rate control, or a stream of high-frequency transport writes.
class DjConsoleScreen extends StatefulWidget {
  const DjConsoleScreen({super.key});

  @override
  State<DjConsoleScreen> createState() => _DjConsoleScreenState();
}

class _DjConsoleScreenState extends State<DjConsoleScreen> {
  final Map<String, Future<DjTrackProfile?>> _profileFutures = {};
  final DjWaveformRangeReader _waveformReader = DjWaveformRangeReader();
  final DjCuePointStore _cuePointStore = DjCuePointStore();
  Map<String, Duration> _cuePoints = <String, Duration>{};

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
      setState(() => _cuePoints = loaded);
    } catch (error) {
      debugPrint('DJ cue points could not be loaded: $error');
    }
  }

  Future<void> _setCuePoint(
    String deckId,
    PlaybackDeckSnapshot? deck,
  ) async {
    final currentDeck = deck;
    final trackId = currentDeck?.mediaId;
    if (trackId == null || trackId.isEmpty) return;
    final updated = Map<String, Duration>.from(_cuePoints)
      ..[trackId] = currentDeck!.position;
    try {
      await _cuePointStore.saveAll(updated);
      if (!mounted) return;
      setState(() => _cuePoints = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deck $deckId cue saved at ${_formatCue(currentDeck.position)}.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cue point could not be saved: $error')),
      );
    }
  }

  Future<void> _seekToCue(
    String deckId,
    PlaybackDeckSnapshot? deck,
  ) async {
    final currentDeck = deck;
    final trackId = currentDeck?.mediaId;
    if (trackId == null || trackId.isEmpty) return;
    final cue = _cuePoints[trackId];
    if (cue == null) return;
    final duration = currentDeck!.duration;
    if (duration != null && cue > duration) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved cue is beyond this track duration. Set a new cue point.')),
      );
      return;
    }
    if (!mounted) return;
    try {
      await context.read<MusicProvider>().seekDjDeck(
        deckId: deckId,
        position: cue,
        expectedMediaId: trackId,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deck $deckId cue seek was not applied: $error')),
      );
    }
  }

  String _formatCue(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _chooseTrackForDeck(
    BuildContext context,
    String deckId,
    MusicProvider music,
    LibraryProvider library,
  ) async {
    final song = await showModalBottomSheet<Song>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
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
                        child: Text('Load Deck $deckId',
                            style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: library.allSongs.isEmpty
                      ? const Center(child: Text('No music in the shared library yet.'))
                      : ListView.builder(
                          controller: controller,
                          itemCount: library.allSongs.length,
                          itemBuilder: (context, index) {
                            final song = library.allSongs[index];
                            final playable = song.filePath.trim().isNotEmpty;
                            return ListTile(
                              enabled: playable,
                              leading: const Icon(Icons.music_note_rounded),
                              title: Text(song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              trailing: playable
                                  ? const Icon(Icons.add_circle_outline_rounded)
                                  : const Icon(Icons.block_rounded),
                              onTap: playable
                                  ? () => Navigator.pop(sheetContext, song)
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (song == null || !mounted) return;
    try {
      await music.loadDjDeck(deckId, <Song>[song]);
      if (!mounted) return;
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
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ResonateGlassBackground(
        child: SafeArea(
          child: Consumer2<MusicProvider, LibraryProvider>(
        builder: (context, music, library, _) {
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
          final durationA = deckA?.duration ?? songA?.duration ?? Duration.zero;
          final durationB = deckB?.duration ?? songB?.duration ?? Duration.zero;
          final progressA = durationA.inMilliseconds <= 0
              ? 0.0
              : (deckA!.position.inMilliseconds / durationA.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
          final progressB = durationB.inMilliseconds <= 0
              ? 0.0
              : (deckB!.position.inMilliseconds / durationB.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
          final djReady = state?.djDualDeckMode == true;
          final compact = MediaQuery.sizeOf(context).width < 820;

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
            final storedCue = trackId == null ? null : _cuePoints[trackId];
            final cuePosition = storedCue != null &&
                    deck?.duration != null &&
                    storedCue > deck!.duration!
                ? null
                : storedCue;
            final title = deck?.title ?? song?.title ?? 'Empty deck';
            final artist = deck?.artist ?? song?.artist ??
                'Load a track from the shared library';
            final position = deck?.position ?? Duration.zero;
            return Expanded(
              child: _ConsoleDeck(
                deck: 'DECK $id',
                active: loaded,
                compact: compact,
                isPlaying: isPlaying,
                canPlay: djReady && loaded && music.media3ProviderSessionActive,
                canAdjustChannelGain:
                    DjConsoleManualControlsPolicy.canAdjustChannelGain(
                  djModeEnabled: djReady,
                  media3SessionActive: music.media3ProviderSessionActive,
                  transitionInProgress: music.transitionInProgress,
                  deckHasMedia: loaded,
                ),
                jogSeekEnabled: djReady && loaded &&
                    music.media3ProviderSessionActive &&
                    !music.transitionInProgress,
                onPlayPause: () async {
                  if (isPlaying) {
                    await music.pauseDjDeck(id);
                  } else {
                    await music.playDjDeck(id);
                  }
                },
                onLoad: djReady
                    ? () => unawaited(
                          _chooseTrackForDeck(context, id, music, library),
                        )
                    : null,
                cuePosition: cuePosition,
                channelGain: deck?.channelGain ?? 1.0,
                onChannelGainChanged: (gain) =>
                    music.setDjDeckChannelGain(deckId: id, gain: gain),
                onSetCue: djReady && loaded
                    ? () => unawaited(_setCuePoint(id, deck))
                    : null,
                onCue: djReady && loaded && cuePosition != null
                    ? () => unawaited(_seekToCue(id, deck))
                    : null,
                onJogSeek: (target) => music.seekDjDeck(
                  deckId: id,
                  position: target,
                  expectedMediaId: deck!.mediaId!,
                ),
                status: !loaded
                    ? 'EMPTY'
                    : isPlaying
                        ? 'PLAYING'
                        : 'LOADED',
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
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => openShellPlayer(context),
                      icon: const Icon(Icons.arrow_back_rounded, size: 17),
                      label: const Text('PLAYER'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'DJ CONSOLE',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _ConsoleStatus(
                      label: djReady ? 'DUAL DECK SESSION' : 'SESSION OFF',
                      active: djReady,
                    ),
                    const SizedBox(width: 8),
                    _ConsoleStatus(
                      label: (deckA?.isPlaying == true || deckB?.isPlaying == true)
                          ? 'OUTPUT ACTIVE'
                          : 'OUTPUT STOPPED',
                      active: deckA?.isPlaying == true || deckB?.isPlaying == true,
                    ),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 10),
                if (!djReady)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: MaterialBanner(
                      content: const Text(
                        'The persistent DJ deck session is not active. Return to the DJ Workspace and initialize the session before using the Console.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Text('WORKSPACE'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      buildDeck(
                        id: 'A',
                        deck: deckA,
                        song: songA,
                        duration: durationA,
                        progress: progressA,
                      ),
                      SizedBox(width: compact ? 8 : 12),
                      SizedBox(
                        width: compact ? 146 : 204,
                        child: _DjConsoleMixer(
                          enabled: DjConsoleManualControlsPolicy.canAdjustCrossfader(
                            djModeEnabled: djReady && music.media3ProviderSessionActive,
                            transitionInProgress: music.transitionInProgress,
                            deckAHasMedia: deckA?.mediaId != null,
                            deckBHasMedia: deckB?.mediaId != null,
                            deckAIsPlaying: deckA?.isPlaying == true,
                            deckBIsPlaying: deckB?.isPlaying == true,
                          ),
                          position: state?.djCrossfaderPosition ?? 0.5,
                          compact: compact,
                          onChanged: music.setDjCrossfader,
                          onGestureStart: music.beginDjCrossfaderGesture,
                          onGestureEnd: music.endDjCrossfaderGesture,
                        ),
                      ),
                      SizedBox(width: compact ? 8 : 12),
                      buildDeck(
                        id: 'B',
                        deck: deckB,
                        song: songB,
                        duration: durationB,
                        progress: progressB,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Each deck owns its queue, transport, cue position and tempo. The crossfader is operator-controlled; Player Autopilot cannot move it. Jog drag seeks the selected physical deck once on release.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.dashboard_outlined, size: 17),
                      label: const Text('Workspace'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
          ),
        ),
      ),
    );
  }
}

class _ConsoleDeck extends StatefulWidget {
  const _ConsoleDeck({
    required this.deck, required this.active, required this.compact,
    required this.isPlaying,
    required this.canPlay,
    required this.onPlayPause,
    required this.onLoad,
    required this.cuePosition,
    required this.channelGain,
    required this.canAdjustChannelGain,
    required this.onChannelGainChanged,
    required this.onSetCue,
    required this.onCue,
    required this.jogSeekEnabled,
    required this.onJogSeek,
    required this.status, required this.title, required this.artist, required this.progress,
    required this.position, required this.duration, required this.profileFuture,
    required this.expectedSongId,
    required this.waveformSourceKey,
    required this.waveformLoader,
  });

  final String deck, status, title, artist;
  final bool active, compact, isPlaying, canPlay, jogSeekEnabled;
  final Future<void> Function() onPlayPause;
  final VoidCallback? onLoad;
  final Duration? cuePosition;
  final double channelGain;
  final bool canAdjustChannelGain;
  final Future<void> Function(double gain) onChannelGainChanged;
  final VoidCallback? onSetCue;
  final VoidCallback? onCue;
  final Future<void> Function(Duration position) onJogSeek;
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
  final ScrollController _waveformScroll = ScrollController();
  Future<List<DjWaveformChunk>>? _waveformFuture;
  int? _requestedStartMs;
  int? _requestedEndMs;
  double _viewportWidth = 0;
  bool _resetWaveformScrollPending = false;
  double _channelGain = 1.0;
  bool _channelGainDragging = false;
  double? _jogLastAngle;
  double _jogAccumulatedRadians = 0;
  Duration? _jogStartPosition;
  Duration? _jogPreviewPosition;
  String? _jogSongId;
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
    _syncPlatterMotion();
    _waveformScroll.addListener(_onWaveformScroll);
  }

  @override
  void didUpdateWidget(covariant _ConsoleDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.canAdjustChannelGain) {
      // Drop a local preview if a native transition takes ownership of gain.
      _channelGainDragging = false;
      _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
    } else if (!_channelGainDragging &&
        oldWidget.channelGain != widget.channelGain) {
      _channelGain = widget.channelGain.clamp(0.0, 1.0).toDouble();
    }
    if (_jogStartPosition != null &&
        (!widget.jogSeekEnabled || !widget.active ||
            oldWidget.expectedSongId != widget.expectedSongId ||
            oldWidget.waveformSourceKey != widget.waveformSourceKey ||
            oldWidget.duration != widget.duration)) {
      _clearJog();
    }
    if (oldWidget.expectedSongId != widget.expectedSongId) {
      _platterRotation.value = 0;
      _requestedStartMs = null;
      _requestedEndMs = null;
      _waveformFuture = null;
      _resetWaveformScrollPending = true;
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

  void _onWaveformScroll() {
    if (!_resetWaveformScrollPending) _requestVisibleWaveform();
  }

  void _requestVisibleWaveform() {
    final loader = widget.waveformLoader;
    final durationMs = widget.duration.inMilliseconds;
    if (loader == null || durationMs <= 0 || _viewportWidth <= 0) return;
    final range = _viewportPolicy.visibleRange(
      durationMs: durationMs,
      viewportWidth: _viewportWidth,
      scrollOffset: _waveformScroll.hasClients ? _waveformScroll.offset : 0,
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
    if (!widget.jogSeekEnabled || !widget.active ||
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
    _jogAccumulatedRadians += DjConsoleJogSeekPolicy.normalizedAngleDelta(
      angle - previous,
    );
    _jogLastAngle = angle;
    final next = DjConsoleJogSeekPolicy.targetPosition(
      start: start,
      deltaRadians: _jogAccumulatedRadians,
      duration: widget.duration,
    );
    setState(() => _jogPreviewPosition = next);
  }

  void _cancelJog() {
    if (_jogStartPosition == null) return;
    _clearJog();
    _syncPlatterMotion();
    setState(() {});
  }

  void _clearJog() {
    _jogLastAngle = null;
    _jogAccumulatedRadians = 0;
    _jogStartPosition = null;
    _jogPreviewPosition = null;
    _jogSongId = null;
  }

  Future<void> _finishJog() async {
    final target = _jogPreviewPosition;
    final songId = _jogSongId;
    final shouldCommit = target != null &&
        _jogStartPosition != null &&
        widget.jogSeekEnabled &&
        widget.active &&
        songId != null &&
        songId == widget.expectedSongId &&
        target != _jogStartPosition;
    _clearJog();
    _syncPlatterMotion();
    if (mounted) setState(() {});
    if (!shouldCommit) return;
    try {
      await widget.onJogSeek(target);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Jog seek was not applied: $error')),
      );
    }
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

  Future<void> _togglePlayback() async {
    try {
      await widget.onPlayPause();
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
    _waveformScroll.removeListener(_onWaveformScroll);
    _waveformScroll.dispose();
    _platterRotation.dispose();
    super.dispose();
  }

  String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.active ? const Color(0xFF55D6BE) : const Color(0xFF8290A8);
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
      padding: EdgeInsets.all(compact ? 10 : 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101923),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: active ? .65 : .24), width: active ? 1.4 : 1),
        boxShadow: active ? [BoxShadow(color: accent.withValues(alpha: .08), blurRadius: 22)] : null,
      ),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Row(children: [
            Text(deck, style: theme.textTheme.labelLarge?.copyWith(
              color: accent, letterSpacing: 1.8, fontWeight: FontWeight.w800)),
            const Spacer(),
            _ConsoleStatus(label: status, active: active),
          ]),
          const SizedBox(height: 10),
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60)),
          SizedBox(
            height: compact ? 218 : 286,
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: compact ? 290 : 350,
                    maxHeight: compact ? 290 : 350,
                  ),
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
                          onPanEnd: widget.jogSeekEnabled ? (_) => _finishJog() : null,
                          onPanCancel: _cancelJog,
                          child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(colors: [
                            Color(0xFF344353), Color(0xFF111923), Color(0xFF080D13),
                          ]),
                          border: Border.all(color: accent.withValues(alpha: .35), width: 2),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .4), blurRadius: 18)],
                        )),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _ConsoleRecordDetailPainter(accent: accent),
                          ),
                        ),
                        Container(
                          width: 88, height: 88,
                          decoration: BoxDecoration(shape: BoxShape.circle,
                            color: const Color(0xFF182431),
                            border: Border.all(color: accent.withValues(alpha: .7), width: 2)),
                          child: Icon(Icons.album, color: accent, size: 44),
                        ),
                        Positioned(bottom: 18, child: Text(
                          _jogPreviewPosition == null
                              ? (widget.jogSeekEnabled ? 'TOUCH · DRAG TO SEEK' : 'PLATTER')
                              : 'SEEK ${_time(_jogPreviewPosition!)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: _jogPreviewPosition == null
                                ? Colors.white38 : accent,
                            letterSpacing: 1.4,
                          ),
                        )),
                          ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'PERFORMANCE CONTROLS',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white38,
                letterSpacing: 1.0,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: const [
                _ConsolePlaceholderControl(label: 'VINYL', icon: Icons.album_outlined),
                _ConsolePlaceholderControl(label: 'SLIP', icon: Icons.motion_photos_on_outlined),
                _ConsolePlaceholderControl(label: 'SYNC', icon: Icons.sync_rounded),
                _ConsolePlaceholderControl(label: 'LOOP', icon: Icons.loop_rounded),
                _ConsolePlaceholderControl(label: 'HOT CUE', icon: Icons.bookmark_outline_rounded),
                _ConsolePlaceholderControl(label: 'FX', icon: Icons.auto_awesome_outlined),
                _ConsolePlaceholderControl(label: 'SAMPLES', icon: Icons.grid_view_rounded),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.cuePosition == null
                      ? 'NO CUE'
                      : 'CUE ${_format(widget.cuePosition!)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                    letterSpacing: .7,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: widget.onCue,
                child: const Text('CUE'),
              ),
              TextButton(
                onPressed: widget.onSetCue,
                child: const Text('SET'),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                'CHANNEL GAIN',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white70,
                  letterSpacing: .8,
                ),
              ),
              const Spacer(),
              Text(
                '${(_channelGain * 100).round()}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white70,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: _channelGain.clamp(0.0, 1.0).toDouble(),
            min: 0.0,
            max: 1.0,
            divisions: 40,
            onChanged: widget.canAdjustChannelGain
                ? (value) => setState(() {
                      _channelGainDragging = true;
                      _channelGain = value;
                    })
                : null,
            onChangeEnd: widget.canAdjustChannelGain
                ? (value) => unawaited(_commitChannelGain(value))
                : null,
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                onPressed: widget.canPlay ? _togglePlayback : null,
                icon: Icon(widget.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
                tooltip: widget.isPlaying ? 'Pause deck' : 'Play deck',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onLoad,
                  icon: const Icon(Icons.library_add_rounded, size: 15),
                  label: const Text('LOAD TRACK'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    textStyle: theme.textTheme.labelSmall,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<DjTrackProfile?>
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
                      if (_resetWaveformScrollPending) {
                        _resetWaveformScrollPending = false;
                        if (_waveformScroll.hasClients &&
                            _waveformScroll.offset != 0) {
                          _waveformScroll.jumpTo(0);
                        }
                      }
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
                        height: compact ? 42 : 58,
                        decoration: BoxDecoration(
                          color: const Color(0xFF080E15),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Stack(fit: StackFit.expand, children: [
                          SingleChildScrollView(
                            controller: _waveformScroll,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: contentWidth,
                              height: compact ? 42 : 58,
                              child: RepaintBoundary(
                                child: CustomPaint(
                                painter: _ConsoleWavePainter(
                                  progress: progress,
                                  color: accent,
                                  segments: segments,
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
                        ]),
                      ),
                      const SizedBox(height: 7),
                      _ConsoleAnalysisStrip(
                        profile: verifiedProfile,
                        positionMs: position.inMilliseconds,
                        compact: compact,
                      ),
                    ],
                  );
                },
              );
                },
              );
            },
          ),
          const SizedBox(height: 5),
          Row(children: [
            Text(_time(position), style: theme.textTheme.labelSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()])),
            const Spacer(),
            Text(duration > Duration.zero ? _time(duration) : '--:--',
              style: theme.textTheme.labelSmall?.copyWith(color: Colors.white54)),
          ]),
          DjConsoleDeckTempoControl(
            physicalDeckId: deck.endsWith('A') ? 'A' : 'B',
            compact: compact,
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
    required this.onChanged,
    required this.onGestureStart,
    required this.onGestureEnd,
  });

  final bool enabled;
  final double position;
  final bool compact;
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
          const SizedBox(height: 18),
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
            widget.enabled ? 'MANUAL MIX READY' : 'LOAD & PLAY BOTH DECKS',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white54,
              fontSize: widget.compact ? 8 : 9,
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 8),
          Text(
            'MIXER RACK · PLANNED',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white38,
              letterSpacing: .7,
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 3,
            runSpacing: 3,
            children: const [
              _ConsolePlaceholderControl(label: 'EQ', icon: Icons.equalizer_rounded),
              _ConsolePlaceholderControl(label: 'FILTER', icon: Icons.tune_rounded),
              _ConsolePlaceholderControl(label: 'PFL', icon: Icons.headphones_rounded),
              _ConsolePlaceholderControl(label: 'MASTER', icon: Icons.volume_up_rounded),
              _ConsolePlaceholderControl(label: 'REC', icon: Icons.fiber_manual_record_rounded),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConsolePlaceholderControl extends StatelessWidget {
  const _ConsolePlaceholderControl({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: '$label control is planned but not wired yet',
        child: OutlinedButton.icon(
          onPressed: null,
          icon: Icon(icon, size: 13),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            textStyle: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: .3,
            ),
          ),
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
                      color: Colors.white38,
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
      color: active ? const Color(0xFF55D6BE) : Colors.white60,
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
