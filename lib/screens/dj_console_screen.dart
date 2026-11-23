import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import '../dj_engine/analysis/dj_waveform_chunk.dart';
import '../models/song.dart';
import '../services/dj_waveform_range_reader.dart';
import '../providers/dj_mode_provider.dart';
import '../dj_engine/core/dj_types.dart';
import '../ui/resonate_glass.dart';
import 'dj_console_manual_controls.dart';
import 'dj_console_overlay_policy.dart';
import 'dj_console_waveform_status.dart';
import 'dj_waveform_viewport_policy.dart';

/// Landscape-first visual foundation for the future performance console.
///
/// This first milestone is intentionally observational: no deck preparation,
/// seeking, gain writes, cueing or crossfader commands are exposed until their
/// native Media3 contracts and ownership tests are complete.
class DjConsoleScreen extends StatefulWidget {
  const DjConsoleScreen({super.key});

  @override
  State<DjConsoleScreen> createState() => _DjConsoleScreenState();
}

class _DjConsoleScreenState extends State<DjConsoleScreen> {
  final Map<String, Future<DjTrackProfile?>> _profileFutures = {};
  final DjWaveformRangeReader _waveformReader = DjWaveformRangeReader();

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ResonateGlassScaffold(
      title: const Text('DJ Console'),
      body: Consumer<MusicProvider>(
        builder: (context, music, _) {
          final song = music.currentSong;
          final deckState = music.media3ShadowState;
          final reportedDeckId = deckState?.activeDeckId;
          final activeDeckId = reportedDeckId == 'A' || reportedDeckId == 'B'
              ? reportedDeckId
              : null;
          final incomingMediaId = deckState?.incomingMediaId;
          final incomingMatches = incomingMediaId == null
              ? <Song>[]
              : music.queue
                  .where((candidate) => candidate.id == incomingMediaId)
                  .toList(growable: false);
          // A media ID can occur more than once in a queue. Never guess which
          // occurrence Media3 prepared; only expose uniquely matched metadata.
          final standbySong = activeDeckId != null &&
                  incomingMatches.length == 1
              ? incomingMatches.single
              : null;
          final standbyIdentityAmbiguous =
              activeDeckId != null && incomingMatches.length > 1;
          final standbyReady = activeDeckId != null &&
              standbySong != null &&
              deckState?.incomingReady == true &&
              deckState?.crossfadeStatus == 'ready' &&
              !music.transitionInProgress;
          final standbyPosition = standbySong == null
              ? Duration.zero
              : deckState?.incomingPosition ?? Duration.zero;
          final duration = music.currentDuration ?? song?.duration ?? Duration.zero;
          final position = music.currentPosition;
          final progress = duration.inMilliseconds <= 0
              ? 0.0
              : (position.inMilliseconds / duration.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
          final standbyDuration = standbySong?.duration ?? Duration.zero;
          final standbyProgress = standbyDuration.inMilliseconds <= 0
              ? 0.0
              : (standbyPosition.inMilliseconds /
                      standbyDuration.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
          final activeProfileFuture = _profileFutureFor(context, song?.id);
          final standbyProfileFuture =
              _profileFutureFor(context, standbySong?.id);
          String standbyStatus() {
            if (activeDeckId == null) return 'UNMAPPED';
            if (standbyIdentityAmbiguous) return 'AMBIGUOUS';
            if (incomingMediaId != null && standbySong == null) {
              return 'UNVERIFIED';
            }
            if (deckState?.crossfadeStatus == 'preparing') {
              return 'PREPARING';
            }
            if (standbyReady) return 'READY · MUTED';
            return 'STANDBY';
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 760;
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _ConsoleStatus(label: song == null ? 'NO ACTIVE TRACK' : 'MEDIA3 SESSION', active: song != null),
                        const SizedBox(width: 8),
                        const _ConsoleStatus(label: 'PERFORMANCE CONTROLS LOCKED', active: false),
                        const Spacer(),
                        Text('RESONATE  /  TWO-DECK SYSTEM',
                            style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 1.3, color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _ConsoleDeck(
                            deck: 'DECK A',
                            active: activeDeckId == 'A', compact: compact,
                            isPlaying: music.isPlaying && activeDeckId == 'A',
                            status: activeDeckId == null
                                ? 'UNMAPPED'
                                : activeDeckId == 'A' ? 'ON AIR' : standbyStatus(),
                            title: activeDeckId == 'A'
                                ? song?.title ?? 'Waiting for track'
                                : standbySong?.title ?? 'Standby deck',
                            artist: activeDeckId == 'A'
                                ? song?.artist ?? 'Select music in the library'
                                : standbySong?.artist ??
                                    (standbyIdentityAmbiguous
                                        ? 'Incoming queue occurrence is ambiguous'
                                        : 'No verified incoming track'),
                            progress: activeDeckId == 'A' ? progress : standbyProgress,
                            position: activeDeckId == 'A' ? position : standbyPosition,
                            duration: activeDeckId == 'A' ? duration : standbyDuration,
                            profileFuture: activeDeckId == 'A'
                                ? activeProfileFuture
                                : standbyProfileFuture,
                            expectedSongId: activeDeckId == 'A'
                                ? song?.id
                                : standbySong?.id,
                            waveformSourceKey: activeDeckId == 'A'
                                ? song?.filePath
                                : standbySong?.filePath,
                            waveformLoader: activeDeckId == 'A' && song != null
                                ? (startMs, endMs) => _waveformReader.loadVisibleRange(
                                    song, startMs: startMs, endMs: endMs)
                                : activeDeckId != 'A' && standbySong != null
                                    ? (startMs, endMs) =>
                                        _waveformReader.loadVisibleRange(
                                          standbySong,
                                          startMs: startMs,
                                          endMs: endMs,
                                        )
                                    : null,
                          )),
                          SizedBox(width: compact ? 8 : 12),
                          SizedBox(
                            width: compact ? 112 : 190,
                            child: DjConsoleManualControls(compact: compact),
                          ),
                          SizedBox(width: compact ? 8 : 12),
                          Expanded(child: _ConsoleDeck(
                            deck: 'DECK B',
                            active: activeDeckId == 'B', compact: compact,
                            isPlaying: music.isPlaying && activeDeckId == 'B',
                            status: activeDeckId == null
                                ? 'UNMAPPED'
                                : activeDeckId == 'B' ? 'ON AIR' : standbyStatus(),
                            title: activeDeckId == 'B'
                                ? song?.title ?? 'Waiting for track'
                                : standbySong?.title ?? 'Standby deck',
                            artist: activeDeckId == 'B'
                                ? song?.artist ?? 'Select music in the library'
                                : standbySong?.artist ??
                                    (standbyIdentityAmbiguous
                                        ? 'Incoming queue occurrence is ambiguous'
                                        : 'No verified incoming track'),
                            progress: activeDeckId == 'B' ? progress : standbyProgress,
                            position: activeDeckId == 'B' ? position : standbyPosition,
                            duration: activeDeckId == 'B' ? duration : standbyDuration,
                            profileFuture: activeDeckId == 'B'
                                ? activeProfileFuture
                                : standbyProfileFuture,
                            expectedSongId: activeDeckId == 'B'
                                ? song?.id
                                : standbySong?.id,
                            waveformSourceKey: activeDeckId == 'B'
                                ? song?.filePath
                                : standbySong?.filePath,
                            waveformLoader: activeDeckId == 'B' && song != null
                                ? (startMs, endMs) => _waveformReader.loadVisibleRange(
                                    song, startMs: startMs, endMs: endMs)
                                : activeDeckId != 'B' && standbySong != null
                                    ? (startMs, endMs) =>
                                        _waveformReader.loadVisibleRange(
                                          standbySong,
                                          startMs: startMs,
                                          endMs: endMs,
                                        )
                                    : null,
                          )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 15,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 7),
                        Expanded(child: Text(
                          'Visual foundation only. Deck B, track waveforms, cueing, jog and mixer actions '
                          'will activate only when backed by verified Media3 capabilities.',
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                        )),
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
          );
        },
      ),
    );
  }
}

class _ConsoleDeck extends StatefulWidget {
  const _ConsoleDeck({
    required this.deck, required this.active, required this.compact,
    required this.isPlaying,
    required this.status, required this.title, required this.artist, required this.progress,
    required this.position, required this.duration, required this.profileFuture,
    required this.expectedSongId,
    required this.waveformSourceKey,
    required this.waveformLoader,
  });

  final String deck, status, title, artist;
  final bool active, compact, isPlaying;
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
  static const _viewportPolicy = DjWaveformViewportPolicy();

  @override
  void initState() {
    super.initState();
    // A 1.8-second revolution approximates a 33⅓ RPM record. This is
    // presentation-only and never sends jog, seek or transport commands.
    _platterRotation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _syncPlatterMotion();
    _waveformScroll.addListener(_onWaveformScroll);
  }

  @override
  void didUpdateWidget(covariant _ConsoleDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expectedSongId != widget.expectedSongId) {
      _platterRotation.value = 0;
      _requestedStartMs = null;
      _requestedEndMs = null;
      _waveformFuture = null;
      _resetWaveformScrollPending = true;
    }
    if (oldWidget.isPlaying != widget.isPlaying ||
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

  void _syncPlatterMotion() {
    if (widget.isPlaying && widget.active) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          const SizedBox(height: 12),
          Expanded(
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
                        Positioned(bottom: 18, child: Text('PLATTER',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white38, letterSpacing: 2))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
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
        ],
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
