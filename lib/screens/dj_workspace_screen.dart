import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation/shell_nav.dart';
import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../services/dj_session_coordinator.dart';
import '../ui/resonate_glass.dart';
import 'dj_suggestion_mix_screen.dart';
import 'dj_transition_studio_screen.dart';

/// Dedicated entry point for DJ preparation and live-session awareness.
///
/// This surface deliberately does not own a player or mutate deck state:
/// Media3 remains the playback authority and DJ controllers must use the
/// shared playback-control arbiter before making live-output changes.
class DjWorkspaceScreen extends StatefulWidget {
  const DjWorkspaceScreen({super.key});

  @override
  State<DjWorkspaceScreen> createState() => _DjWorkspaceScreenState();
}

class _DjWorkspaceScreenState extends State<DjWorkspaceScreen> {
  bool _buildingMix = false;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _openTransitionStudio() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DjTransitionStudioScreen()),
    );
  }

  Future<void> _buildLibraryMix() async {
    if (_buildingMix) return;
    final dj = context.read<DjModeProvider>();
    await dj.ready;
    if (!mounted) return;
    if (!dj.isEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enable DJ Mode before preparing a DJ set.')),
      );
      return;
    }

    final songs = context.read<LibraryProvider>().allSongs
        .where((song) => song.filePath.trim().isNotEmpty)
        .toList(growable: false);
    if (songs.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least two available tracks to prepare a DJ set.')),
      );
      return;
    }

    setState(() => _buildingMix = true);
    try {
      final coordinator = DjSessionCoordinator(analysis: dj.analysis);
      final mix = await coordinator.create(
        songs: songs,
        scope: DjSessionScope.library,
        policy: dj.policy,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DjSuggestionMixScreen(
            initialMix: mix,
            coordinator: coordinator,
            scopeLabel: 'Music library',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare a DJ set: $error')),
      );
    } finally {
      if (mounted) setState(() => _buildingMix = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ResonateGlassScaffold(
      title: const Text('DJ Workspace'),
      body: Consumer2<MusicProvider, DjModeProvider>(
        builder: (context, music, dj, _) {
          final song = music.currentSong;
          final duration = music.currentDuration ?? song?.duration ?? Duration.zero;
          final progress = duration.inMilliseconds <= 0
              ? 0.0
              : (music.currentPosition.inMilliseconds / duration.inMilliseconds)
                  .clamp(0.0, 1.0)
                  .toDouble();

          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
            children: [
              Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, color: theme.colorScheme.primary, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Prepare. Perform. Stay in control.',
                            style: theme.textTheme.titleMedium),
                        Text('DJ intelligence works alongside the existing Media3 playback engine.',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ResonateGlassCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.album_rounded),
                        const SizedBox(width: 8),
                        Text('LIVE SESSION', style: theme.textTheme.labelLarge),
                        const Spacer(),
                        _StatusPill(
                          label: dj.isEnabled ? 'DJ enabled' : 'DJ disabled',
                          active: dj.isEnabled,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (song == null) ...[
                      Text('No track playing', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text('Start playback from your library to populate the live session.',
                          style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => context.read<ShellNav>().goToTab(1),
                        icon: const Icon(Icons.library_music_rounded),
                        label: const Text('Open library'),
                      ),
                    ] else ...[
                      Text(song.title, style: theme.textTheme.titleLarge,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(song.artist, style: theme.textTheme.bodyMedium,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(_clock(music.currentPosition),
                              style: theme.textTheme.labelSmall),
                          const Spacer(),
                          Text(_clock(duration), style: theme.textTheme.labelSmall),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            music.isPlaying ? Icons.play_circle_rounded : Icons.pause_circle_rounded,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              music.transitionInProgress
                                  ? 'Transition in progress'
                                  : music.isPlaying
                                      ? 'Playback active'
                                      : 'Playback paused',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      if (music.lastDjStrategy != null) ...[
                        const SizedBox(height: 6),
                        Text('Last DJ strategy: ${music.lastDjStrategy}',
                            style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text('WORKSPACE TOOLS', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              _WorkspaceAction(
                icon: Icons.compare_arrows_rounded,
                title: 'Transition Studio',
                subtitle: 'Analyze a pair of tracks, edit Mix-In / Mix-Out cues and inspect transition plans.',
                onTap: _openTransitionStudio,
              ),
              const SizedBox(height: 10),
              _WorkspaceAction(
                icon: Icons.queue_music_rounded,
                title: 'Prepare a DJ set',
                subtitle: 'Build a reviewable library sequence with track-pair transition plans.',
                loading: _buildingMix,
                onTap: _buildingMix ? null : _buildLibraryMix,
              ),
              const SizedBox(height: 18),
              ResonateGlassCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Playback safety: this workspace prepares and monitors DJ decisions; it does not create a second player. Live output remains under the shared playback-control arbiter, and Media3 remains the only playback authority.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WorkspaceAction extends StatelessWidget {
  const _WorkspaceAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ResonateGlassCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: loading
            ? const SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.green : Theme.of(context).colorScheme.outline;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color, fontWeight: FontWeight.w700,
        )),
      ),
    );
  }
}
