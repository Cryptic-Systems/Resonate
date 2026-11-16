import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../navigation/shell_nav.dart';
import '../screens/dj_suggestion_mix_screen.dart';
import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import 'database_helper.dart';
import '../providers/playlist_provider.dart';
import 'dj_auto_select_service.dart';
import 'dj_session_coordinator.dart';

/// Shared opt-in DJ shuffle flow for Library and playlist surfaces.
class DjShuffleFlow {
  const DjShuffleFlow._();

  static Future<void> fromLibrary(BuildContext context) async {
    final library = context.read<LibraryProvider>();
    final visibleSongs = library.filteredSongs.isNotEmpty ||
            library.searchQuery.isNotEmpty ||
            library.filterBy != 'all'
        ? library.filteredSongs
        : library.allSongs;
    if (visibleSongs.isEmpty) return;

    final useDj = await _askForDjShuffle(context);
    if (!context.mounted || useDj == null) return;
    if (!useDj) {
      await _playRegular(context, visibleSongs);
      return;
    }

    final playlists = context.read<PlaylistProvider>();
    if (playlists.playlists.isEmpty) await playlists.loadPlaylists();
    if (!context.mounted) return;

    final scope = await showDialog<Object>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose DJ shuffle scope'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.library_music_rounded),
                title: const Text('Entire library'),
                subtitle: Text('${library.allSongs.length} tracks'),
                onTap: () => Navigator.pop(dialogContext, 'library'),
              ),
              const Divider(),
              if (playlists.playlists.isEmpty)
                const ListTile(
                  title: Text('No playlists yet'),
                  subtitle: Text('Create a playlist to DJ-arrange a smaller collection.'),
                ),
              for (final playlist in playlists.playlists)
                ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.songIds.length} tracks'),
                  onTap: () => Navigator.pop(dialogContext, playlist),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!context.mounted || scope == null) return;

    if (scope == 'library') {
      await _playDj(
        context,
        library.allSongs,
        scope: DjSessionScope.library,
        scopeLabel: 'Entire library',
      );
    } else if (scope is Playlist) {
      final songs = await playlists.songsFor(scope.id);
      if (!context.mounted) return;
      await _playDj(
          context,
          songs,
          scope: DjSessionScope.playlist,
          scopeId: scope.id,
          scopeLabel: scope.name,
        );
    }
  }

  static Future<void> fromPlaylist(
    BuildContext context,
    List<Song> songs, {
    required String playlistName,
    required String playlistId,
  }) async {
    if (songs.isEmpty) return;
    final useDj = await _askForDjShuffle(context);
    if (!context.mounted || useDj == null) return;
    if (useDj) {
      await _playDj(
        context,
        songs,
        scope: DjSessionScope.playlist,
        scopeId: playlistId,
        scopeLabel: playlistName,
      );
    } else {
      await _playRegular(context, songs);
    }
  }

  static Future<bool?> _askForDjShuffle(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('DJ-arranged shuffle?'),
        content: const Text(
          'Let Resonate arrange the selected tracks using available tempo, '
          'key and energy analysis? If you decline, ordinary random shuffle '
          'will work exactly as usual.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Regular shuffle'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.graphic_eq_rounded),
            label: const Text('DJ arrange'),
          ),
        ],
      ),
    );
  }

  static Future<void> _playRegular(
    BuildContext context,
    List<Song> source,
  ) async {
    final songs = List<Song>.of(source)..shuffle(math.Random());
    if (songs.isEmpty) return;
    final music = context.read<MusicProvider>();
    await music.setShuffleEnabled(true);
    final ok = await music.playSong(songs.first, queue: songs, startIndex: 0);
    if (!context.mounted) return;
    if (ok) {
      openShellPlayer(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to start shuffle playback.')),
      );
    }
  }

  static Future<void> _playDj(
    BuildContext context,
    List<Song> source, {
    required DjSessionScope scope,
    String? scopeId,
    required String scopeLabel,
  }) async {
    if (source.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This collection has no playable tracks.')),
      );
      return;
    }

    try {
      final dj = context.read<DjModeProvider>();
      final database = DatabaseHelper();
      final history = await database.getRecentListeningEvents(limit: 500);
      final favoriteSongs = await database.getFavoriteSongs();
      if (!context.mounted) return;
      final signals = DjListeningSignal.fromHistory(
        history,
        favorites: favoriteSongs.map((song) => song.id).toSet(),
      );
      final coordinator = DjSessionCoordinator(analysis: dj.analysis);
      final mix = await coordinator.create(
        songs: source,
        scope: scope,
        scopeId: scopeId,
        listeningSignals: signals,
        policy: dj.policy,
      );
      if (!context.mounted) return;

      // Creating a Suggestion Mix is deliberately side-effect free with
      // respect to playback. The review screen owns the explicit approval.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DjSuggestionMixScreen(
            initialMix: mix,
            coordinator: coordinator,
            scopeLabel: scopeLabel,
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare a DJ suggestion: $error')),
      );
    }
  }
}
