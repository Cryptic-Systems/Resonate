import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/intelligence_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../navigation/shell_nav.dart';
import '../ui/resonate_glass.dart';
import '../widgets/driving_suggestion_banner.dart';
import '../widgets/evolving_mix_card.dart';
import '../widgets/mode_shelf_card.dart';

class DiscoveryScreen extends StatelessWidget {
  const DiscoveryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<IntelligenceProvider, LibraryProvider>(
      builder: (context, intelligence, library, _) {
        final recommendations = intelligence.recommendations.skip(1).toList();
        final songs = library.allSongs;
        return ResonateGlassScaffold(
          title: const Text('Discovery'),
          body: RefreshIndicator(
            onRefresh: intelligence.refreshRecommendations,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  'Explore music for the way you want to listen.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 14),
                const DrivingSuggestionBanner(),
                const SizedBox(height: 12),
                const ModeShelfCard(),
                const SizedBox(height: 12),
                const EvolvingMixCard(),
                const SizedBox(height: 20),
                Text('MORE MUSIC FOR THIS MOMENT',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                if (!intelligence.isEnabled)
                  const ResonateGlassCard(
                    blurEnabled: false,
                    child: ListTile(
                      leading: Icon(Icons.auto_awesome_outlined),
                      title: Text('Intelligence is off'),
                      subtitle: Text('Your player remains fully manual. Enable Intelligence in Settings to receive personalised recommendations.'),
                    ),
                  )
                else if (recommendations.isEmpty)
                  const ResonateGlassCard(
                    blurEnabled: false,
                    child: ListTile(
                      leading: Icon(Icons.headphones_rounded),
                      title: Text('Let Resonate get to know your taste'),
                      subtitle: Text('Finishes, skips and song-to-song choices become local signals for future suggestions.'),
                    ),
                  )
                else
                  ...recommendations.map((item) => _DiscoveryRecommendationTile(
                        song: item.song,
                        reason: item.reason,
                        confidence: item.confidenceLabel,
                        songs: songs,
                      )),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DiscoveryRecommendationTile extends StatefulWidget {
  const _DiscoveryRecommendationTile({
    required this.song,
    required this.reason,
    required this.confidence,
    required this.songs,
  });

  final Song song;
  final String reason;
  final String confidence;
  final List<Song> songs;

  @override
  State<_DiscoveryRecommendationTile> createState() =>
      _DiscoveryRecommendationTileState();
}

class _DiscoveryRecommendationTileState
    extends State<_DiscoveryRecommendationTile> {
  bool _loading = false;

  Future<void> _play() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final music = context.read<MusicProvider>();
      final index = widget.songs.indexWhere((song) => song.id == widget.song.id);
      final queue = index >= 0
          ? widget.songs.sublist(index)
          : <Song>[widget.song];
      final started = await music.playSong(widget.song, queue: queue, startIndex: 0);
      if (mounted && started) openShellPlayer(context);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ResonateGlassCard(
      blurEnabled: false,
      margin: const EdgeInsets.only(bottom: 9),
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.music_note_rounded)),
        title: Text(widget.song.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${widget.song.artist}\n${widget.confidence} • ${widget.reason}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Consumer<LibraryProvider>(
              builder: (_, library, __) {
                final liked = library.isFavoriteSync(widget.song.id);
                return IconButton(
                  tooltip: liked ? 'Unlike' : 'Like',
                  icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                  onPressed: _loading ? null : () => library.toggleFavorite(widget.song),
                );
              },
            ),
            _loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Play recommendation',
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: _play,
                  ),
          ],
        ),
        onTap: _loading ? null : _play,
      ),
    );
  }
}
