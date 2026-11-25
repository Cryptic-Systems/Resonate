import 'package:flutter/material.dart';
import '../ui/resonate_glass.dart';
import 'package:provider/provider.dart';
import '../models/intelligence_recommendation.dart';
import '../models/song.dart';
import '../providers/intelligence_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../services/playback_authority.dart';
import '../widgets/autopilot_home_card.dart';
import 'discovery_screen.dart';
import '../widgets/resonate_logo.dart';
import '../widgets/resonate_mode_chip.dart';
import '../widgets/experience_mode_chip.dart';
import '../widgets/mode_player_density.dart';
import '../modes/providers/mode_provider.dart';
import '../navigation/shell_nav.dart';

String _homeFormatClock(int ms) {
  final totalSec = (ms / 1000).floor().clamp(0, 24 * 3600);
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String _homeFormatHours(int ms) {
  final minutes = Duration(milliseconds: ms).inMinutes;
  if (minutes < 60) return '${minutes}m';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

class HomeDashboard extends StatelessWidget {
  const HomeDashboard();

  List<Widget> _recommendations(IntelligenceProvider intelligence, List<dynamic> songs) {
    if (!intelligence.isEnabled) {
      return const [ResonateGlassCard(padding: EdgeInsets.zero, child: ListTile(leading: Icon(Icons.auto_awesome_outlined), title: Text('Intelligence is off'), subtitle: Text('Your player remains fully manual. Enable it from Settings when you want local anticipation.')))];
    }
    final recommendations = intelligence.recommendations.skip(1).toList();
    if (recommendations.isEmpty) {
      return const [ResonateGlassCard(padding: EdgeInsets.zero, child: ListTile(leading: Icon(Icons.headphones_rounded), title: Text('Let Resonate get to know your taste'), subtitle: Text('Finishes, skips and song-to-song choices become local signals for future decisions.')))];
    }
    return recommendations.map<Widget>((item) => _RecommendationTile(item: item, songs: songs)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final intelligence = context.watch<IntelligenceProvider>();
    final songs = library.allSongs;
    return ResonateGlassScaffold(
      title: const ResonateLogo(size: 58, full: true, showWord: false),
      actions: const [ExperienceModeChip(dense: true), ResonateModeChip(dense: true)],
      body: RefreshIndicator(
        onRefresh: intelligence.refreshRecommendations,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
          children: [
            AutopilotHomeCard(songCount: songs.length),
            const SizedBox(height: 16),
            ResonateGlassCard(
              blurEnabled: false,
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.explore_rounded, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 9),
                    Text('Discover your next listen', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 7),
                  Text(
                    intelligence.isEnabled
                        ? 'Explore recommendations, evolving mixes and listening experiences shaped around your current context.'
                        : 'Explore your library through listening modes, mixes and personalised discovery.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const DiscoveryScreen()),
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('Open Discovery'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const ResonateGlassCard(
              blurEnabled: false,
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(Icons.library_music_rounded),
                title: Text('Your music stays organised in Library'),
                subtitle: Text('Browse your collection, playlists, favourites and listening history there.'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      );
}

class _SessionCard extends StatelessWidget {
  final IntelligenceProvider intelligence;

  const _SessionCard({required this.intelligence});

  @override
  Widget build(BuildContext context) {
    return ResonateGlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your listening flow', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(width: 42, height: 24, child: _LearningWaveDots()),
            const SizedBox(width: 10),
            Expanded(child: Text(intelligence.sessionSummary)),
          ]),
          if (intelligence.sessionArtists.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Current flow: ${intelligence.sessionArtists.take(3).join(' • ')}'),
          ],
        ]),
      ),
    );
  }
}

class _LearningWaveDots extends StatefulWidget {
  const _LearningWaveDots();

  @override
  State<_LearningWaveDots> createState() => _LearningWaveDotsState();
}

class _LearningWaveDotsState extends State<_LearningWaveDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(3, (index) {
            final phase = (_controller.value + index * .18) % 1.0;
            final wave = (0.5 + 0.5 * mathSin(phase * 6.283185307)).clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(0, -6 * wave),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
              ),
            );
          }),
        ),
      );
}

double mathSin(double value) {
  // Small local sine approximation keeps this animation dependency-free.
  var x = value;
  while (x > 3.1415926535) x -= 6.283185307;
  while (x < -3.1415926535) x += 6.283185307;
  final x2 = x * x;
  return x * (1 - x2 / 6 + (x2 * x2) / 120 - (x2 * x2 * x2) / 5040);
}

class _RecommendationTile extends StatefulWidget {
  final IntelligenceRecommendation item;
  final List<dynamic> songs;

  const _RecommendationTile({required this.item, required this.songs});

  @override
  State<_RecommendationTile> createState() => _RecommendationTileState();
}

class _RecommendationTileState extends State<_RecommendationTile> {
  bool _loading = false;

  Future<void> _play() async {
    if (_loading) return;
    setState(() => _loading = true);
    final music = context.read<MusicProvider>();
    final index = widget.songs.indexWhere((song) => song.id == widget.item.song.id);
    try {
      final list = widget.songs.whereType<Song>().toList();
      final q = index >= 0 && index < list.length ? list.sublist(index) : <Song>[widget.item.song];
      await music.playSong(widget.item.song, queue: q, startIndex: 0);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LibraryProvider>(
      builder: (context, library, _) {
        final liked = library.isFavoriteSync(widget.item.song.id);
        final confidence = (widget.item.confidence.clamp(0.0, 1.0) * 100).round();
        final confidenceText = '${widget.item.confidenceLabel} • $confidence%';
        return ResonateGlassCard(
          // Live BackdropFilter blur on every recommendation card is expensive
          // during scrolling, particularly on low-end Android devices.
          blurEnabled: false,
          padding: EdgeInsets.zero,
          margin: const EdgeInsets.only(bottom: 9),
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.music_note_rounded)),
            title: Text(widget.item.song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${widget.item.song.artist}\n$confidenceText • ${widget.item.reason}', maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: liked ? 'Unlike' : 'Like', icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded), onPressed: _loading ? null : () => library.toggleFavorite(widget.item.song)),
              _loading ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : IconButton(icon: const Icon(Icons.play_arrow_rounded), onPressed: _play),
            ]),
            onTap: _loading ? null : _play,
          ),
        );
      },
    );
  }
}
