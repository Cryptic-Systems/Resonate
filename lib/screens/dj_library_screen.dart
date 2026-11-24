import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../ui/resonate_glass.dart';

/// DJ-specific library browser. Selecting a track loads only the chosen
/// physical deck; it never invokes Player's canonical queue/play command.
class DjLibraryScreen extends StatefulWidget {
  const DjLibraryScreen({super.key});

  @override
  State<DjLibraryScreen> createState() => _DjLibraryScreenState();
}

class _DjLibraryScreenState extends State<DjLibraryScreen> {
  final TextEditingController _search = TextEditingController();
  String _targetDeck = 'A';
  String? _loadingSongId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadSong(Song song, MusicProvider music) async {
    if (_loadingSongId != null) return;
    setState(() => _loadingSongId = song.id);
    try {
      await music.loadDjDeck(_targetDeck, <Song>[song]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded “${song.title}” into Deck $_targetDeck. Press Play on the Console when ready.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load Deck $_targetDeck: $error')),
      );
    } finally {
      if (mounted) setState(() => _loadingSongId = null);
    }
  }

  Future<void> _prepareSession(MusicProvider music) async {
    try {
      await music.enableDjDualDeckMode();
      await music.clearDjDeck('A');
      await music.clearDjDeck('B');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('DJ deck session is unavailable: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ResonateGlassScaffold(
      title: const Text('DJ Library'),
      actions: [
        IconButton(
          tooltip: 'Refresh library',
          onPressed: () => context.read<LibraryProvider>().loadAllSongs(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: Consumer2<LibraryProvider, MusicProvider>(
        builder: (context, library, music, _) {
          final state = music.media3ShadowState;
          final ready = state?.djDualDeckMode == true;
          final query = _search.text.trim().toLowerCase();
          final songs = library.allSongs.where((song) {
            if (query.isEmpty) return true;
            return song.title.toLowerCase().contains(query) ||
                song.artist.toLowerCase().contains(query) ||
                song.album.toLowerCase().contains(query);
          }).toList(growable: false);

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 76, 16, 24),
            children: [
              ResonateGlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('INDEPENDENT DECK LOADING',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Text(
                      'Choose a destination deck, then load a track from the shared library. The other deck and the saved Player queue are kept separate.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _DeckTargetCard(
                            deck: 'A',
                            selected: _targetDeck == 'A',
                            title: state?.deckA?.title ?? 'Empty deck',
                            onTap: () => setState(() => _targetDeck = 'A'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _DeckTargetCard(
                            deck: 'B',
                            selected: _targetDeck == 'B',
                            title: state?.deckB?.title ?? 'Empty deck',
                            onTap: () => setState(() => _targetDeck = 'B'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!ready) ...[
                      Text(
                        'The persistent DJ deck session is not active yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _loadingSongId == null
                            ? () => _prepareSession(music)
                            : null,
                        icon: const Icon(Icons.sync_rounded),
                        label: const Text('Initialize DJ decks'),
                      ),
                    ] else
                      Row(
                        children: [
                          Icon(Icons.check_circle_rounded,
                              color: theme.colorScheme.primary, size: 17),
                          const SizedBox(width: 7),
                          Text('DJ deck session ready',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'Search tracks, artists or albums',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('YOUR MUSIC',
                      style: theme.textTheme.labelLarge),
                  const Spacer(),
                  Text('${songs.length} tracks',
                      style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 8),
              if (!library.isInitialized)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (songs.isEmpty)
                ResonateGlassCard(
                  child: Column(
                    children: [
                      const Icon(Icons.library_music_outlined, size: 34),
                      const SizedBox(height: 8),
                      Text(
                        query.isEmpty
                            ? 'Your library is empty'
                            : 'No tracks match this search',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        query.isEmpty
                            ? 'Scan or add music to the shared Resonate library first.'
                            : 'Try another title, artist or album.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              else
                ResonateGlassCard(
                  padding: EdgeInsets.zero,
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: songs.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 64),
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      final loading = _loadingSongId == song.id;
                      final playable = song.filePath.trim().isNotEmpty;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.surfaceContainerHigh,
                          child: const Icon(Icons.music_note_rounded),
                        ),
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: SizedBox(
                          width: 92,
                          child: FilledButton(
                            onPressed: ready && playable && _loadingSongId == null
                                ? () => _loadSong(song, music)
                                : null,
                            child: loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Text('LOAD $_targetDeck'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DeckTargetCard extends StatelessWidget {
  const _DeckTargetCard({
    required this.deck,
    required this.selected,
    required this.title,
    required this.onTap,
  });

  final String deck;
  final bool selected;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerLow,
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DECK $deck',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                )),
            const SizedBox(height: 5),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(selected ? 'LOAD TARGET' : 'SELECT DECK',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                )),
          ],
        ),
      ),
    );
  }
}
