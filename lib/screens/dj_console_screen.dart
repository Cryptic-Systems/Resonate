import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import '../providers/dj_mode_provider.dart';
import '../dj_engine/core/dj_types.dart';
import '../ui/resonate_glass.dart';

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
  String? _profileSongId;
  Future<DjTrackProfile?>? _profileFuture;

  void _ensureProfileFuture(BuildContext context, String? songId) {
    if (_profileSongId == songId) return;
    _profileSongId = songId;
    _profileFuture = songId == null
        ? null
        : context.read<DjModeProvider>().analysis.getProfile(songId);
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
          final duration = music.currentDuration ?? song?.duration ?? Duration.zero;
          final position = music.currentPosition;
          final progress = duration.inMilliseconds <= 0
              ? 0.0
              : (position.inMilliseconds / duration.inMilliseconds)
                  .clamp(0.0, 1.0).toDouble();
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
                            deck: activeDeckId == null ? 'PROGRAM · ID UNKNOWN' : 'DECK A',
                            active: activeDeckId == 'A', compact: compact,
                            status: activeDeckId == null ? 'IDENTITY UNKNOWN' : activeDeckId == 'A' ? 'ON AIR' : 'STANDBY',
                            title: activeDeckId == 'B' ? 'Standby deck' : song?.title ?? 'Waiting for track',
                            artist: activeDeckId == 'B' ? 'Awaiting verified standby metadata' : song?.artist ?? 'Select music in the library',
                            progress: activeDeckId == 'B' ? 0 : progress,
                            position: activeDeckId == 'B' ? Duration.zero : position,
                            duration: activeDeckId == 'B' ? Duration.zero : duration,
                            profileFuture: activeDeckId == 'A' ? _profileFuture : null,
                          )),
                          SizedBox(width: compact ? 8 : 12),
                          SizedBox(
                            width: compact ? 132 : 190,
                            child: _ConsoleMixer(compact: compact),
                          ),
                          SizedBox(width: compact ? 8 : 12),
                          Expanded(child: _ConsoleDeck(
                            deck: activeDeckId == null ? 'STANDBY · UNMAPPED' : 'DECK B',
                            active: activeDeckId == 'B', compact: compact,
                            status: activeDeckId == null ? 'UNMAPPED' : activeDeckId == 'B' ? 'ON AIR' : 'STANDBY',
                            title: activeDeckId == 'B' ? song?.title ?? 'Waiting for track' : 'Standby deck',
                            artist: activeDeckId == 'B' ? song?.artist ?? 'Select music in the library' : 'Incoming track identity will appear here',
                            progress: activeDeckId == 'B' ? progress : 0,
                            position: activeDeckId == 'B' ? position : Duration.zero,
                            duration: activeDeckId == 'B' ? duration : Duration.zero,
                            profileFuture: activeDeckId == 'B' ? _profileFuture : null,
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

class _ConsoleDeck extends StatelessWidget {
  const _ConsoleDeck({
    required this.deck, required this.active, required this.compact,
    required this.status, required this.title, required this.artist, required this.progress,
    required this.position, required this.duration, required this.profileFuture,
  });

  final String deck, status, title, artist;
  final bool active, compact;
  final double progress;
  final Duration position, duration;
  final Future<DjTrackProfile?>? profileFuture;

  String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = active ? const Color(0xFF55D6BE) : const Color(0xFF8290A8);
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
            Text('DECK $deck', style: theme.textTheme.labelLarge?.copyWith(
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
                  constraints: const BoxConstraints(maxWidth: 210, maxHeight: 210),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          const Color(0xFF344353), const Color(0xFF111923), const Color(0xFF080D13),
                        ]),
                        border: Border.all(color: accent.withValues(alpha: .35), width: 2),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .4), blurRadius: 18)],
                      )),
                      for (var i = 0; i < 3; i++)
                        Container(
                          width: 150.0 - i * 30, height: 150.0 - i * 30,
                          decoration: BoxDecoration(shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: .07))),
                        ),
                      Container(
                        width: 58, height: 58,
                        decoration: BoxDecoration(shape: BoxShape.circle,
                          color: const Color(0xFF182431),
                          border: Border.all(color: accent.withValues(alpha: .7), width: 2)),
                        child: Icon(Icons.album, color: accent, size: 30),
                      ),
                      Positioned(bottom: 12, child: Text('PLATTER',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white38, letterSpacing: 2))),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<DjTrackProfile?>(
            future: profileFuture,
            builder: (context, snapshot) {
              final segments = snapshot.data?.waveformSegments ?? const <DjWaveformSegment>[];
              final label = snapshot.connectionState == ConnectionState.waiting
                  ? 'LOADING CACHED PCM PROFILE'
                  : segments.isEmpty
                      ? 'NO SAMPLED PCM · PREVIEW UNAVAILABLE'
                      : 'MEASURED PCM · ${segments.length} WINDOWS · GAPS UNANALYSED';
              return Container(
                height: compact ? 42 : 58,
                decoration: BoxDecoration(
                  color: const Color(0xFF080E15),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Stack(fit: StackFit.expand, children: [
                  CustomPaint(
                    painter: _ConsoleWavePainter(
                      progress: progress,
                      color: accent,
                      segments: segments,
                      durationMs: duration.inMilliseconds,
                    ),
                  ),
                  Positioned(left: 7, top: 4, child: Text(
                    label,
                    style: const TextStyle(fontSize: 7, letterSpacing: .5, color: Colors.white70),
                  )),
                ]),
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

class _ConsoleMixer extends StatelessWidget {
  const _ConsoleMixer({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(compact ? 8 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF151D28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: .09)),
      ),
      child: Column(
        children: [
          Text('MIXER', style: theme.textTheme.labelLarge?.copyWith(
            letterSpacing: 2, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          const SizedBox(height: 8),
          Text('A  —', style: theme.textTheme.labelMedium?.copyWith(color: Colors.white54)),
          const SizedBox(height: 4),
          Text('B  —', style: theme.textTheme.labelMedium?.copyWith(color: Colors.white54)),
          const SizedBox(height: 4),
          Text('LEVEL TELEMETRY NOT CONNECTED',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(fontSize: 8, color: Colors.white38)),
          const Spacer(),
          Icon(Icons.tune_rounded, size: compact ? 25 : 32,
              color: theme.colorScheme.primary),
          const SizedBox(height: 5),
          Text('CROSSFADER', style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1, color: Colors.white70)),
          const SizedBox(height: 8),
          Container(height: 5, decoration: BoxDecoration(
            color: Colors.white12, borderRadius: BorderRadius.circular(8))),
          const SizedBox(height: 12),
          Text('Controls unlock after native transition mapping and safety tests.',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9, color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
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
    required this.durationMs,
  });
  final double progress;
  final Color color;
  final List<DjWaveformSegment> segments;
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
      !identical(old.segments, segments);
}
