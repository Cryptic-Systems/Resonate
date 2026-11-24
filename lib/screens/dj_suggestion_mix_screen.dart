import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../dj_engine/core/dj_types.dart';
import '../providers/dj_mode_provider.dart';
import '../navigation/shell_nav.dart';
import '../providers/music_provider.dart';
import '../models/song.dart';
import '../services/dj_session_coordinator.dart';

/// Review surface for a proposed DJ sequence. Reordering changes only this
/// proposal; playback is handed off only after the user explicitly approves.
class DjSuggestionMixScreen extends StatefulWidget {
  const DjSuggestionMixScreen({
    super.key,
    required this.initialMix,
    required this.coordinator,
    required this.scopeLabel,
  });

  final DjSuggestionMix initialMix;
  final DjSessionCoordinator coordinator;
  final String scopeLabel;

  @override
  State<DjSuggestionMixScreen> createState() => _DjSuggestionMixScreenState();
}

class _DjSuggestionMixScreenState extends State<DjSuggestionMixScreen> {
  late DjSuggestionMix _mix;
  bool _approving = false;

  @override
  void initState() {
    super.initState();
    _mix = widget.initialMix;
  }

  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final songs = List<Song>.of(_mix.orderedSongs);
    final moved = songs.removeAt(oldIndex);
    songs.insert(newIndex, moved);
    try {
      final updated = widget.coordinator.reorder(
        mix: _mix,
        orderedSongIds: songs.map((song) => song.id).toList(),
        policy: context.read<DjModeProvider>().policy,
      );
      setState(() => _mix = updated);
    } on Object catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not reorder this mix: $error')),
      );
    }
  }

  Future<void> _approveAndPlay() async {
    if (_approving || _mix.orderedSongs.isEmpty) return;
    setState(() => _approving = true);
    MusicProvider? music;
    try {
      final djMode = context.read<DjModeProvider>();
      await djMode.ready;
      if (!djMode.isEnabled) {
        if (!mounted) return;
        setState(() => _approving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('DJ Mode was turned off. Enable it again to start this mix.')),
        );
        return;
      }
      final approved = widget.coordinator.approve(_mix);
      music = context.read<MusicProvider>();
      if (music!.isDjDualDeckSessionActive) {
        // In Resonatix DJ, approval stages the first pair on the independent
        // physical decks. It must never route this workflow through Player's
        // canonical queue or start playback without the operator.
        await music.loadDjDeck('A', <Song>[approved.songs.first]);
        if (approved.songs.length > 1) {
          await music.loadDjDeck('B', <Song>[approved.songs[1]]);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('DJ set approved. The first two tracks are staged on Deck A and Deck B; start them from DJ Console.'),
          ),
        );
        openShellPlayer(context);
        return;
      }
      music!.setApprovedDjTransitions({
        for (final transition in approved.transitions)
          '${transition.outgoingSongId}\u0000${transition.incomingSongId}': transition.plan,
      });
      // DJ order remains authoritative for this queue while the saved
      // global Shuffle preference remains untouched.
      final started = await music.playSong(
        approved.songs.first,
        queue: approved.songs,
        startIndex: 0,
        preserveQueueOrder: true,
      );
      if (!started) {
        music.setApprovedDjTransitions(const {});
        if (!mounted) return;
        setState(() => _approving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Resonate could not start this mix.')),
        );
        return;
      }
      if (!mounted) return;
      openShellPlayer(context);
    } catch (error) {
      music?.setApprovedDjTransitions(const {});
      if (!mounted) return;
      setState(() => _approving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not approve this mix: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDjSession = context.watch<MusicProvider>().isDjDualDeckSessionActive;
    final transitionsByOutgoing = {
      for (final transition in _mix.transitions)
        transition.outgoingSongId: transition,
    };
    final fallbackCount = _mix.fallbackTransitionCount;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suggestion Mix'),
        actions: [
          IconButton(
            tooltip: 'Discard suggestion',
            onPressed: _approving ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.scopeLabel,
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_mix.orderedSongs.length} tracks • '
                          '${(_mix.analysisCoverage * 100).round()}% analysis coverage',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        _InfoPanel(
                          icon: _mix.usedDjArrangement
                              ? Icons.auto_awesome_rounded
                              : Icons.shuffle_rounded,
                          title: _mix.usedDjArrangement
                              ? 'DJ arrangement ready to review'
                              : 'Standard shuffle fallback',
                          message: _mix.usedDjArrangement
                              ? 'Resonate used the available musical analysis and listening signals. Drag tracks to change the sequence; transition guidance will be recalculated.'
                              : 'There is not enough reliable analysis for a confident DJ arrangement yet. This shuffled sequence is still reviewable, and no playback has started.',
                        ),
                        if (fallbackCount > 0) ...[
                          const SizedBox(height: 8),
                          _InfoPanel(
                            icon: Icons.info_outline_rounded,
                            title: '$fallbackCount conservative transition(s)',
                            message: 'Some adjacent pairs lack sufficient confidence for a DJ-specific transition. They remain marked as safe fallbacks.',
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Icon(Icons.drag_indicator_rounded, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              'Hold and drag to reorder',
                              style: theme.textTheme.labelMedium,
                            ),
                            const Spacer(),
                            Text(
                              'Revision ${_mix.revision}',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SliverReorderableList(
                  itemCount: _mix.orderedSongs.length,
                  onReorder: _reorder,
                  itemBuilder: (context, index) {
                    final song = _mix.orderedSongs[index];
                    final transition = transitionsByOutgoing[song.id];
                    return _SuggestionTrackTile(
                      key: ValueKey(song.id),
                      index: index,
                      song: song,
                      transition: transition,
                      isLast: index == _mix.orderedSongs.length - 1,
                    );
                  },
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 20)),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _approving || _mix.orderedSongs.isEmpty
                      ? null
                      : _approveAndPlay,
                  icon: _approving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline_rounded),
                  label: Text(
                    _approving
                        ? (isDjSession ? 'Staging decks…' : 'Starting mix…')
                        : (isDjSession
                            ? 'Approve & stage first two decks'
                            : 'Approve & play mix'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionTrackTile extends StatelessWidget {
  const _SuggestionTrackTile({
    super.key,
    required this.index,
    required this.song,
    required this.transition,
    required this.isLast,
  });

  final int index;
  final Song song;
  final DjSessionTransition? transition;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = transition?.plan;
    final candidate = plan?.candidate;
    return Padding(
      key: ValueKey(song.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                child: Text('${index + 1}'),
              ),
              title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle_rounded),
                ),
              ),
            ),
            if (!isLast && plan != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      plan.fallback ? Icons.shield_outlined : Icons.graphic_eq_rounded,
                      size: 17,
                      color: plan.fallback
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            plan.fallback
                                ? _fallbackLabel(plan.reason)
                                : '${_kindLabel(candidate?.kind)} transition',
                            style: theme.textTheme.labelMedium,
                          ),
                          if (candidate != null)
                            Text(
                              '${_formatDuration(candidate.durationMs)} blend • '
                              '${(candidate.confidence * 100).round()}% confidence',
                              style: theme.textTheme.bodySmall,
                            ),
                          if (candidate != null && candidate.risks.isNotEmpty)
                            Text(
                              'Considerations: ${candidate.risks.map((risk) => risk.name).join(', ')}',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _fallbackLabel(String reason) {
    switch (reason) {
      case 'insufficient_analysis_confidence':
        return 'Conservative fallback • analysis incomplete';
      case 'invalid_track_profile':
        return 'Conservative fallback • profile unavailable';
      case 'invalid_execution_timeline':
        return 'Conservative fallback • timing not validated';
      case 'insufficient_playable_duration':
        return 'Conservative fallback • short remaining material';
      default:
        return 'Conservative fallback';
    }
  }

  static String _kindLabel(DjTransitionKind? kind) {
    switch (kind) {
      case DjTransitionKind.outroIntro:
        return 'Outro / intro';
      case DjTransitionKind.phraseBlend:
        return 'Phrase-aligned';
      case DjTransitionKind.breakdownDrop:
        return 'Breakdown / drop';
      case DjTransitionKind.beatBlend:
        return 'Beat-aligned';
      case DjTransitionKind.energyBridge:
        return 'Energy bridge';
      case DjTransitionKind.safeCrossfade:
      case null:
        return 'Crossfade';
    }
  }

  static String _formatDuration(int milliseconds) {
    final seconds = (milliseconds / 1000).round();
    return '${seconds}s';
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(message, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
