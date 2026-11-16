import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../navigation/shell_nav.dart';
import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../providers/playlist_provider.dart';
import 'dj_auto_select_service.dart';

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
      await _playDj(context, library.allSongs, scopeLabel: 'entire library');
    } else if (scope is Playlist) {
      final songs = await playlists.songsFor(scope.id);
      if (!context.mounted) return;
      await _playDj(context, songs, scopeLabel: scope.name);
    }
  }

  static Future<void> fromPlaylist(
    BuildContext context,
    List<Song> songs, {
    required String playlistName,
  }) async {
    if (songs.isEmpty) return;
    final useDj = await _askForDjShuffle(context);
    if (!context.mounted || useDj == null) return;
    if (useDj) {
      await _playDj(context, songs, scopeLabel: playlistName);
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
    required String scopeLabel,
  }) async {
    if (source.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This collection has no playable tracks.')),
      );
      return;
    }

    final dj = context.read<DjModeProvider>();
    final result = await DjAutoSelectService(analysis: dj.analysis).arrange(source);
    if (!context.mounted) return;

    final music = context.read<MusicProvider>();
    if (!result.usedDjArrangement) {
      // Low-confidence analysis never forces an arbitrary musical order.
      // Keep every track and use the established ordinary shuffle path.
      await music.setShuffleEnabled(true);
      final shuffled = List<Song>.of(source)..shuffle(math.Random());
      final ok = await music.playSong(
        shuffled.first,
        queue: shuffled,
        startIndex: 0,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Not enough reliable DJ analysis for $scopeLabel yet '
            '(${(result.analysisCoverage * 100).round()}% covered). '
            'Playing a regular shuffle instead.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      if (ok) openShellPlayer(context);
      return;
    }

    // MusicProvider intentionally randomizes an incoming queue while shuffle
    // is enabled. Turn that flag off so the DJ-arranged order is authoritative.
    await music.setShuffleEnabled(false);
    final ok = await music.playSong(
      result.songs.first,
      queue: result.songs,
      startIndex: 0,
    );
    if (!context.mounted) return;
    if (ok) {
      openShellPlayer(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'DJ arranged ${result.songs.length} tracks from $scopeLabel.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to start DJ-arranged playback.')),
      );
    }
  }
}
