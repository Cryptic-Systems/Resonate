import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';

import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../services/dj_session_coordinator.dart';
import '../services/playback_snapshot.dart';
import '../ui/resonate_glass.dart';
import 'dj_suggestion_mix_screen.dart';
import 'dj_transition_studio_screen.dart';

/// Watch-only control-room view for DJ intelligence and Media3 deck state.
///
/// This surface never owns a player and never issues transport or manual deck
/// preparation commands. Hands-on deck operation belongs in DJ Console.
class DjWorkspaceScreen extends StatefulWidget {
  const DjWorkspaceScreen({super.key, this.playerFacing = false, this.onSwitchToPlayer});

  /// Player receives a user-facing mix monitor, never physical deck telemetry
  /// or links into hands-on DJ performance tools.
  final bool playerFacing;
  final Future<void> Function()? onSwitchToPlayer;

  @override
  State<DjWorkspaceScreen> createState() => _DjWorkspaceScreenState();
}

class _DjWorkspaceScreenState extends State<DjWorkspaceScreen> {
  bool _buildingMix = false;
  // DJ Workspace is deliberately observational. Transport and manual deck
  // preparation controls belong to the dedicated DJ Console.
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
    if (_buildingMix || !mounted) return;
    // Acquire the guard before the first await so rapid taps cannot start
    // parallel analysis jobs or push competing result routes.
    setState(() => _buildingMix = true);
    try {
      final dj = context.read<DjModeProvider>();
      await dj.ready;
      if (!mounted) return;
      if (!dj.isEnabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.playerFacing
                  ? 'Enable automatic mixing before preparing a DJ set.'
                  : 'Enable DJ Mode before preparing a DJ set.',
            ),
          ),
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
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(widget.playerFacing ? 'Mix Monitor' : 'DJ Workspace'),
        leading: widget.playerFacing ? null : Builder(
          builder: (context) => IconButton(
            tooltip: 'Switch experience',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: widget.playerFacing ? null : _DjModeDrawer(
        onSwitchToPlayer: widget.onSwitchToPlayer,
      ),
      body: SafeArea(
        child: Consumer2<MusicProvider, DjModeProvider>(
        builder: (context, music, dj, _) {
          final song = music.currentSong;
          final deckState = music.media3ShadowState;
          final djDeckSession = deckState?.djDualDeckMode == true;
          final deckA = deckState?.deckA;
          final deckB = deckState?.deckB;
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
                        Text(
                          widget.playerFacing
                              ? 'Watch Resonate shape the listening session.'
                              : djDeckSession
                                  ? 'Monitor both independent DJ decks.'
                                  : 'Watch the mix unfold.',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          widget.playerFacing
                              ? 'Automatic transition activity and incoming-track preparation, without exposing the performance controls.'
                              : djDeckSession
                                  ? 'Track identity, transport, tempo and output state for Deck A and Deck B.'
                                  : 'Live deck activity, incoming preparation and transitions — observed in real time.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ResonateGlassCard(
        blurEnabled: false,
blurEnabled: false,
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
                          label: widget.playerFacing
                              ? (dj.isEnabled ? 'Automatic mixing on' : 'Automatic mixing off')
                              : djDeckSession
                                  ? 'DJ session active'
                                  : (dj.isEnabled ? 'DJ enabled' : 'DJ disabled'),
                          active: djDeckSession || dj.isEnabled,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (!widget.playerFacing && djDeckSession) ...[
                      Text('Independent deck session',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        'Both physical decks are available for separate track loading and transport.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _WorkspaceDeckSummary(
                              deck: 'A',
                              snapshot: deckA,
                              color: const Color(0xFF55D6BE),
                              clock: _clock,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _WorkspaceDeckSummary(
                              deck: 'B',
                              snapshot: deckB,
                              color: const Color(0xFF8EA7FF),
                              clock: _clock,
                            ),
                          ),
                        ],
                      ),
                    ] else if (song == null) ...[
                      Text('No track playing', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text('Start playback from your library to populate the live session.',
                          style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).maybePop(),
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
                      Semantics(
                        label: 'Playback progress',
                        value: '${(progress * 100).round()} percent',
                        child: LinearProgressIndicator(value: progress),
                      ),
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
              Text(
                widget.playerFacing ? 'AUTOMATIC MIX' : 'LIVE DECK MONITOR',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Builder(builder: (context) {
                final deckState = music.media3ShadowState;
                final reportedDeckId = deckState?.activeDeckId;
                final activeDeckId = reportedDeckId == 'A' || reportedDeckId == 'B'
                    ? reportedDeckId
                    : null;
                final standbyDeckId = activeDeckId == null
                    ? null
                    : activeDeckId == 'A' ? 'B' : 'A';
                final incomingMediaId = deckState?.incomingMediaId;
                final matchingIncomingSongs = incomingMediaId == null
                    ? <Song>[]
                    : music.queue.where((candidate) => candidate.id == incomingMediaId).toList(growable: false);
                // IDs alone cannot distinguish repeated queue occurrences. Only
                // display a track when the visible queue has one unambiguous match.
                final Song? standbySong = matchingIncomingSongs.length == 1
                    ? matchingIncomingSongs.single
                    : null;
                final incomingIdentityAmbiguous = matchingIncomingSongs.length > 1;
                final incomingStatus = deckState?.crossfadeStatus;
                final incomingReady = deckState?.incomingReady == true;
                final incomingIdentityMatches = standbySong != null;
                final standbyDeckReady = activeDeckId != null &&
                    incomingReady &&
                    incomingIdentityMatches &&
                    incomingStatus == 'ready' &&
                    !music.transitionInProgress;
                final standbyStateLabel = music.transitionInProgress
                    ? 'Transition in progress'
                    : standbyDeckReady
                        ? 'Prepared · muted'
                        : incomingStatus == 'preparing'
                            ? 'Preparing incoming track'
                            : incomingIdentityAmbiguous
                                ? 'Duplicate track ID · occurrence ambiguous'
                                : incomingMediaId != null && !incomingIdentityMatches
                                    ? 'Loaded track · identity unverified'
                                    : incomingReady
                                        ? 'Native ready · identity unverified'
                                        : 'Standby idle';
                final underrunsA = deckState?.audioUnderrunCountA;
                final underrunsB = deckState?.audioUnderrunCountB;
                final underruns = (underrunsA ?? 0) + (underrunsB ?? 0);
                final hasDeckTelemetry = deckState != null;
                final activeGain = deckState?.activeDeckVolume;
                final standbyGain = deckState?.standbyDeckVolume;
                const hasLiveSpectrum = false;
                if (widget.playerFacing) {
                  return _PlayerMixMonitorCard(
                    currentSong: song,
                    incomingSong: standbySong,
                    currentProgress: progress,
                    currentPosition: music.currentPosition,
                    currentDuration: duration,
                    isPlaying: music.isPlaying,
                    transitionInProgress: music.transitionInProgress,
                    incomingReady: standbyDeckReady,
                    incomingPreparing: incomingStatus == 'preparing',
                    incomingIdentityAmbiguous: incomingIdentityAmbiguous,
                    incomingUnverified: incomingMediaId != null && standbySong == null,
                    liveSpectrum: null,
                    outgoingGain: activeGain,
                    incomingGain: standbyGain,
                    outgoingEngine: activeDeckId,
                    incomingEngine: standbyDeckId,
                  );
                }
                if (deckState?.djDualDeckMode == true) {
                  return _DjPhysicalDeckMonitorCard(
                    deckA: deckState?.deckA,
                    deckB: deckState?.deckB,
                    crossfaderPosition: deckState?.djCrossfaderPosition ?? 0.5,
                    underrunsA: deckState?.audioUnderrunCountA,
                    underrunsB: deckState?.audioUnderrunCountB,
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ResonateGlassCard(
        blurEnabled: false,
margin: EdgeInsets.zero,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _DeckPerformancePanel(
                            activeSong: song,
                            standbySong: standbySong,
                            activeDeckId: activeDeckId,
                            standbyIdentityLabel: incomingIdentityAmbiguous
                                ? 'Duplicate incoming ID · occurrence ambiguous'
                                : incomingMediaId != null && standbySong == null
                                    ? 'Incoming identity unverified'
                                    : null,
                            activeProgress: progress,
                            activePosition: music.currentPosition,
                            activeDuration: duration,
                            standbyPosition: incomingIdentityMatches
                                ? (deckState?.incomingPosition ?? Duration.zero)
                                : Duration.zero,
                            standbyReady: standbyDeckReady,
                            isPlaying: music.isPlaying,
                            transitionActive: music.transitionInProgress,
                            liveSpectrum: hasLiveSpectrum ? visualization.frequencies : null,
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Icon(
                                Icons.monitor_heart_outlined,
                                color: theme.colorScheme.primary,
                                size: 19,
                              ),
                              const SizedBox(width: 8),
                              Text('ENGINE OBSERVATION',
                                  style: theme.textTheme.labelLarge),
                              const Spacer(),
                              _StatusPill(
                                label: music.transitionInProgress
                                    ? 'Transitioning'
                                    : music.isPlaying
                                        ? 'Playing'
                                        : 'Paused',
                                active: music.isPlaying ||
                                    music.transitionInProgress,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _TelemetryRow(
                            icon: Icons.speaker_group_outlined,
                            label: 'Live output',
                            value: !hasDeckTelemetry || activeDeckId == null
                                ? 'Deck identity / gain unavailable'
                                : activeGain == null
                                    ? 'Deck $activeDeckId · gain unavailable'
                                    : 'Deck $activeDeckId · ${(activeGain * 100).round()}% gain',
                          ),
                          const SizedBox(height: 7),
                          _TelemetryRow(
                            icon: Icons.album_outlined,
                            label: 'Standby',
                            value: '${standbyDeckId == null ? 'Deck identity unavailable' : 'Deck $standbyDeckId'} · $standbyStateLabel',
                            valueColor: standbyDeckReady
                                ? const Color(0xFF8CE6B0)
                                : music.transitionInProgress
                                    ? const Color(0xFFFFC56E)
                                    : null,
                          ),
                          const SizedBox(height: 7),
                          _TelemetryRow(
                            icon: Icons.volume_off_outlined,
                            label: 'Standby gain',
                            value: standbyGain == null
                                ? 'Gain unavailable · standby is designed to remain muted'
                                : '${(standbyGain * 100).round()}% · muted by design',
                          ),
                          const SizedBox(height: 7),
                          _TelemetryRow(
                            icon: Icons.graphic_eq_outlined,
                            label: 'Audio underruns',
                            value: !hasDeckTelemetry || underrunsA == null || underrunsB == null
                                ? 'Telemetry unavailable'
                                : 'Deck A $underrunsA · Deck B $underrunsB',
                            valueColor: underruns > 0
                                ? theme.colorScheme.error
                                : null,
                          ),
                          if (deckState?.lastUnderrunDeck != null) ...[
                            const SizedBox(height: 7),
                            _TelemetryRow(
                              icon: Icons.warning_amber_rounded,
                              label: 'Latest underrun',
                              value: 'Deck ${deckState!.lastUnderrunDeck} · ${deckState.lastUnderrunBufferSizeMs} ms buffer · ${deckState.lastUnderrunElapsedSinceFeedMs} ms since feed',
                              valueColor: theme.colorScheme.error,
                            ),
                          ],
                          if (incomingMediaId != null && standbySong == null) ...[
                            const SizedBox(height: 9),
                            Text(
                              incomingIdentityAmbiguous
                                  ? 'More than one queue occurrence has this media ID. The Workspace will not guess which occurrence is loaded on the standby deck.'
                                  : 'Media3 reports an incoming media item that cannot currently be matched to one track in the visible queue. Its identity is intentionally not guessed.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 10),
                          Text(
                            'This is a watch-only view. Deck preparation, manual cueing and crossfader operation are reserved for DJ Console. Standby remains muted while Media3 owns deck preparation and transitions.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(height: 14),
              if (!widget.playerFacing) ...[
                Text('WORKSPACE TOOLS', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                _WorkspaceAction(
                  icon: Icons.compare_arrows_rounded,
                  title: 'Transition Studio',
                  subtitle: 'Analyze a pair of tracks, edit Mix-In / Mix-Out cues and inspect transition plans.',
                  onTap: _openTransitionStudio,
                ),
                const SizedBox(height: 10),
              ] else ...[
                Text('DJ ASSIST', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
              ],
              _WorkspaceAction(
                icon: Icons.queue_music_rounded,
                title: 'Prepare a DJ set',
                subtitle: 'Build a reviewable library sequence with track-pair transition plans.',
                loading: _buildingMix,
                onTap: _buildingMix ? null : _buildLibraryMix,
              ),
              const SizedBox(height: 18),
              ResonateGlassCard(
        blurEnabled: false,
margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.playerFacing
                            ? 'Playback safety: automatic mixing uses the shared playback-control authority and existing audio session. This monitor does not create or control a second player.'
                            : 'Playback safety: this workspace prepares and monitors DJ decisions; it does not create a second player. Live output remains under the shared playback-control arbiter, and Media3 remains the only playback authority.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      )),
    );
  }
}

class _DjModeDrawer extends StatelessWidget {
  const _DjModeDrawer({required this.onSwitchToPlayer});

  final Future<void> Function()? onSwitchToPlayer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('EXPERIENCE', style: theme.textTheme.labelLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Text(
                'Choose the environment you want to use.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.music_note_rounded),
              title: const Text('Resonate Player'),
              subtitle: const Text('Everyday listening and automation'),
              trailing: const Icon(Icons.arrow_forward_rounded),
              onTap: onSwitchToPlayer == null ? null : () async {
                Navigator.of(context).pop();
                await onSwitchToPlayer!.call();
              },
            ),
            const Divider(height: 20),
            ListTile(
              leading: Icon(Icons.album_rounded, color: theme.colorScheme.primary),
              title: const Text('Resonatix DJ'),
              subtitle: const Text('Current experience'),
              trailing: Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary),
              selected: true,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceDeckSummary extends StatelessWidget {
  const _WorkspaceDeckSummary({
    required this.deck,
    required this.snapshot,
    required this.color,
    required this.clock,
  });

  final String deck;
  final PlaybackDeckSnapshot? snapshot;
  final Color color;
  final String Function(Duration) clock;

  String _formatDeckTime(PlaybackDeckSnapshot value) {
    final duration = value.duration;
    return '${clock(value.position)} / ${duration == null ? '--:--' : clock(duration)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentSnapshot = snapshot;
    final loaded = currentSnapshot?.mediaId != null;
    final timeLabel = currentSnapshot == null || currentSnapshot.mediaId == null
        ? '—:— / —:—'
        : _formatDeckTime(currentSnapshot);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('DECK $deck',
                style: theme.textTheme.labelLarge?.copyWith(color: color)),
            const Spacer(),
            _StatusPill(
              label: !loaded
                  ? 'EMPTY'
                  : currentSnapshot!.isPlaying
                      ? 'PLAYING'
                      : 'LOADED',
              active: currentSnapshot?.isPlaying == true,
            ),
          ]),
          const SizedBox(height: 7),
          Text(
            currentSnapshot?.title ?? 'No track loaded',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          Text(
            currentSnapshot?.artist ?? 'Waiting for track',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 7),
          Text(
            timeLabel,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _DjPhysicalDeckMonitorCard extends StatelessWidget {
  const _DjPhysicalDeckMonitorCard({
    required this.deckA,
    required this.deckB,
    required this.crossfaderPosition,
    required this.underrunsA,
    required this.underrunsB,
  });

  final PlaybackDeckSnapshot? deckA;
  final PlaybackDeckSnapshot? deckB;
  final double crossfaderPosition;
  final int? underrunsA;
  final int? underrunsB;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _deck(BuildContext context, String label, PlaybackDeckSnapshot? deck, Color color) {
    final theme = Theme.of(context);
    final loaded = deck?.mediaId != null;
    final duration = deck?.duration;
    return ResonateGlassCard(
        blurEnabled: false,
margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('DECK $label',
                  style: theme.textTheme.labelLarge?.copyWith(color: color)),
              const Spacer(),
              _StatusPill(
                label: !loaded
                    ? 'EMPTY'
                    : deck!.isPlaying
                        ? 'PLAYING'
                        : 'PAUSED',
                active: deck?.isPlaying == true,
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              deck?.title ?? 'No track loaded',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              deck?.artist ?? 'Waiting for library selection',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: !loaded || duration == null || duration.inMilliseconds <= 0
                  ? 0
                  : (deck!.position.inMilliseconds / duration.inMilliseconds)
                      .clamp(0.0, 1.0).toDouble(),
            ),
            const SizedBox(height: 6),
            Text(
              loaded
                  ? '${_clock(deck!.position)} / ${duration == null ? '--:--' : _clock(duration)}'
                  : '—:— / —:—',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 10),
            _TelemetryRow(
              icon: Icons.speed_rounded,
              label: 'Tempo / key lock',
              value: loaded
                  ? '${deck!.speed.toStringAsFixed(3)}× · pitch ${deck.pitch.toStringAsFixed(3)}×'
                  : 'Unavailable',
            ),
            const SizedBox(height: 6),
            _TelemetryRow(
              icon: Icons.volume_up_outlined,
              label: 'Output gain',
              value: loaded ? '${(deck!.volume * 100).round()}%' : 'Unavailable',
            ),
          ],
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aUnderruns = underrunsA;
    final bUnderruns = underrunsB;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _deck(context, 'A', deckA, const Color(0xFF55D6BE))),
            const SizedBox(width: 10),
            Expanded(child: _deck(context, 'B', deckB, const Color(0xFF8EA7FF))),
          ],
        ),
        const SizedBox(height: 10),
        ResonateGlassCard(
        blurEnabled: false,
margin: EdgeInsets.zero,
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(children: [
                Text('OPERATOR CROSSFADER',
                    style: theme.textTheme.labelLarge),
                const Spacer(),
                Text('${(crossfaderPosition.clamp(0.0, 1.0) * 100).round()}% B',
                    style: theme.textTheme.labelSmall),
              ]),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: crossfaderPosition.clamp(0.0, 1.0).toDouble()),
              const SizedBox(height: 8),
              _TelemetryRow(
                icon: Icons.graphic_eq_rounded,
                label: 'Audio underruns',
                value: aUnderruns == null || bUnderruns == null
                    ? 'Telemetry unavailable'
                    : 'Deck A $aUnderruns · Deck B $bUnderruns',
                valueColor: ((aUnderruns ?? 0) + (bUnderruns ?? 0)) > 0
                    ? theme.colorScheme.error
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                'Monitoring only. Deck transport and the crossfader are operated in DJ Console.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlayerMixMonitorCard extends StatelessWidget {
  const _PlayerMixMonitorCard({
    required this.currentSong,
    required this.incomingSong,
    required this.currentProgress,
    required this.currentPosition,
    required this.currentDuration,
    required this.isPlaying,
    required this.transitionInProgress,
    required this.incomingReady,
    required this.incomingPreparing,
    required this.incomingIdentityAmbiguous,
    required this.incomingUnverified,
    required this.liveSpectrum,
    required this.outgoingGain,
    required this.incomingGain,
    required this.outgoingEngine,
    required this.incomingEngine,
  });

  final Song? currentSong;
  final Song? incomingSong;
  final double currentProgress;
  final Duration currentPosition;
  final Duration currentDuration;
  final bool isPlaying;
  final bool transitionInProgress;
  final bool incomingReady;
  final bool incomingPreparing;
  final bool incomingIdentityAmbiguous;
  final bool incomingUnverified;
  final List<double>? liveSpectrum;
  final double? outgoingGain;
  final double? incomingGain;
  final String? outgoingEngine;
  final String? incomingEngine;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incomingStatus = transitionInProgress
        ? 'Transition in progress'
        : incomingReady
            ? 'Ready for automatic transition'
            : incomingPreparing
                ? 'Preparing incoming track'
                : incomingIdentityAmbiguous
                    ? 'Incoming track occurrence is ambiguous'
                    : incomingUnverified
                        ? 'Incoming track identity is not yet verified'
                        : 'No incoming track prepared';
    return ResonateGlassCard(
        blurEnabled: false,
margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.graphic_eq_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('AUTOMATIC MIX MONITOR', style: theme.textTheme.labelLarge),
            const Spacer(),
            _StatusPill(
              label: transitionInProgress
                  ? 'Transitioning'
                  : isPlaying
                      ? 'Playing'
                      : 'Paused',
              active: isPlaying || transitionInProgress,
            ),
          ]),
          const SizedBox(height: 14),
          Text('NOW PLAYING', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(
            currentSong?.title ?? 'Nothing playing',
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (currentSong != null) ...[
            Text(
              currentSong!.artist,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: currentProgress),
            const SizedBox(height: 5),
            Row(children: [
              Text(_clock(currentPosition), style: theme.textTheme.labelSmall),
              const Spacer(),
              Text(_clock(currentDuration), style: theme.textTheme.labelSmall),
            ]),
          ],
          const SizedBox(height: 12),
          _EngineVolumeMeter(
            label: 'Outgoing · Engine ${outgoingEngine ?? '—'}',
            gain: outgoingGain,
            color: const Color(0xFF55D6BE),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Text('INCOMING MIX', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(
            incomingSong?.title ??
                (incomingUnverified || incomingIdentityAmbiguous
                    ? 'Track details unavailable'
                    : 'No incoming track'),
            style: theme.textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (incomingSong != null)
            Text(
              incomingSong!.artist,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 6),
          Text(incomingStatus, style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          _EngineVolumeMeter(
            label: 'Incoming · Engine ${incomingEngine ?? '—'}',
            gain: incomingGain,
            color: const Color(0xFF8EA7FF),
          ),
          if (liveSpectrum != null && liveSpectrum!.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 38,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final value in liveSpectrum!.take(48))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: FractionallySizedBox(
                          heightFactor: value.clamp(0.04, 1.0).toDouble(),
                          alignment: Alignment.bottomCenter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}


class _EngineVolumeMeter extends StatelessWidget {
  const _EngineVolumeMeter({
    required this.label,
    required this.gain,
    required this.color,
  });

  final String label;
  final double? gain;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = (gain ?? 0).clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.labelSmall)),
            Text(
              gain == null ? '—' : '${(value * 100).round()}%',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: value),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 90),
          builder: (context, animated, _) => ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: gain == null ? 0 : animated,
              minHeight: 8,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      ],
    );
  }
}

class _DeckPerformancePanel extends StatelessWidget {
  const _DeckPerformancePanel({
    required this.activeSong, required this.standbySong,
    required this.activeDeckId, required this.standbyIdentityLabel, required this.activeProgress,
    required this.activePosition, required this.activeDuration,
    required this.standbyPosition, required this.standbyReady,
    required this.isPlaying, required this.transitionActive,
    required this.liveSpectrum,
  });

  final Song? activeSong;
  final Song? standbySong;
  final String? activeDeckId;
  final String? standbyIdentityLabel;
  final double activeProgress;
  final Duration activePosition;
  final Duration activeDuration;
  final Duration standbyPosition;
  final bool standbyReady;
  final bool isPlaying;
  final bool transitionActive;
  final List<double>? liveSpectrum;

  @override
  Widget build(BuildContext context) {
    final activeColor = const Color(0xFF62D6FF);
    final standbyColor = const Color(0xFFB18CFF);
    final standbyId = activeDeckId == null ? null : activeDeckId == 'A' ? 'B' : 'A';
    final standbyDuration = standbySong?.duration ?? Duration.zero;
    final standbyProgress = standbyDuration.inMilliseconds <= 0 ? 0.0 :
      (standbyPosition.inMilliseconds / standbyDuration.inMilliseconds).clamp(0.0, 1.0).toDouble();
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xF0101B2C), Color(0xF0171329)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [BoxShadow(color: activeColor.withValues(alpha: 0.08), blurRadius: 24)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.graphic_eq_rounded, color: Color(0xFF8FE5FF), size: 18),
          const SizedBox(width: 8),
          Text('DECK ARRAY', style: theme.textTheme.labelLarge?.copyWith(
            color: Colors.white, letterSpacing: 1.5, fontWeight: FontWeight.w800)),
          const Spacer(),
          _DeckLiveBadge(active: isPlaying, transitioning: transitionActive),
        ]),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final activeDeck = _DeckVisualTile(
              deckLabel: 'DECK ${activeDeckId ?? '—'}',
              role: activeDeckId == null ? 'IDENTITY UNKNOWN' : 'ON AIR',
              song: activeSong,
              accent: activeColor,
              progress: activeProgress,
              duration: activeDuration,
              position: activePosition,
              isActive: true,
              isReady: activeSong != null,
              isPlaying: isPlaying,
              spectrum: liveSpectrum,
            );
            final standbyDeck = _DeckVisualTile(
              deckLabel: 'DECK ${standbyId ?? '—'}',
              role: standbyId == null ? 'IDENTITY UNKNOWN' : 'STANDBY',
              song: standbySong,
              accent: standbyColor,
              progress: standbyProgress,
              duration: standbyDuration,
              position: standbyPosition,
              isActive: false,
              isReady: standbyReady,
              isPlaying: false,
              unresolvedIdentityLabel: standbyIdentityLabel,
            );

            // Keep both decks side by side on normal screens, but give each
            // deck the full card width on compact windows to preserve readable
            // track labels and usable spectrum bars without horizontal squeeze.
            if (constraints.maxWidth < 360) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  activeDeck,
                  const SizedBox(height: 8),
                  standbyDeck,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: activeDeck),
                const SizedBox(width: 8),
                Expanded(child: standbyDeck),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.compare_arrows_rounded,
            color: transitionActive ? const Color(0xFFFFC56E) : Colors.white54, size: 18),
          const SizedBox(width: 7),
          Expanded(child: Text(
            transitionActive ? 'NATIVE TRANSITION · DECK PROMOTION IN PROGRESS' :
            standbyReady ? 'STANDBY PREPARED · MUTED AND MONITORED' :
            'DUAL-DECK MONITOR · STANDBY IS MUTED',
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: transitionActive ? const Color(0xFFFFD18B) : Colors.white70,
              letterSpacing: 0.55, fontWeight: FontWeight.w700))),
          AnimatedContainer(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 420), width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: transitionActive ? const Color(0xFFFFC56E) :
                standbyReady ? const Color(0xFF8CE6B0) : Colors.white30,
              boxShadow: [BoxShadow(
                color: (transitionActive ? const Color(0xFFFFC56E) :
                  standbyReady ? const Color(0xFF8CE6B0) : Colors.transparent).withValues(alpha: 0.55),
                blurRadius: 9)],
            )),
        ]),
      ]),
    );
  }
}

class _DeckLiveBadge extends StatelessWidget {
  const _DeckLiveBadge({required this.active, required this.transitioning});
  final bool active;
  final bool transitioning;

  @override
  Widget build(BuildContext context) {
    final color = transitioning ? const Color(0xFFFFC56E) :
      active ? const Color(0xFF8CE6B0) : Colors.white54;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.38))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(
          color: color, shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6)])),
        const SizedBox(width: 6),
        Text(transitioning ? 'BLENDING' : active ? 'LIVE' : 'MONITOR',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
      ]),
    );
  }
}

class _DeckVisualTile extends StatelessWidget {
  const _DeckVisualTile({
    required this.deckLabel, required this.role, required this.song,
    required this.accent, required this.progress, required this.duration,
    required this.position, required this.isActive, required this.isReady, required this.isPlaying,
    this.spectrum,
    this.unresolvedIdentityLabel,
  });
  final String deckLabel, role;
  final Song? song;
  final Color accent;
  final double progress;
  final Duration duration;
  final Duration position;
  final bool isActive, isReady, isPlaying;
  final List<double>? spectrum;
  final String? unresolvedIdentityLabel;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return (seconds ~/ 60).toString() + ':' + (seconds % 60).toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    final liveSpectrum = spectrum;
    final title = song?.title ?? (isActive ? 'No active track' : unresolvedIdentityLabel ?? 'Awaiting incoming track');
    final artist = song?.artist ?? (isActive ? 'Start playback to activate' : unresolvedIdentityLabel != null ? 'Track occurrence not verified' : 'Media3 standby monitor');
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 420),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isActive ? 0.075 : 0.035),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: isReady ? 0.62 : 0.20),
          width: isActive ? 1.25 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(deckLabel, style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: accent, letterSpacing: 1, fontWeight: FontWeight.w900)),
          const Spacer(),
          Text(role, style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white60, fontSize: 9, letterSpacing: 0.7)),
        ]),
        const SizedBox(height: 8),
        AspectRatio(aspectRatio: 1.9, child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(fit: StackFit.expand, children: [
            DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [accent.withValues(alpha: 0.30), const Color(0xFF101321), const Color(0xFF241B3B)]))),
            Positioned(right: -12, top: -18, child: Icon(Icons.album_rounded,
              size: 94, color: accent.withValues(alpha: 0.14))),
            Center(child: Icon(isActive ? Icons.graphic_eq_rounded : Icons.album_rounded,
              size: 34, color: accent.withValues(alpha: song == null ? 0.35 : 0.92))),
            Positioned(left: 7, bottom: 6, child: Text(
              isActive
                  ? (song == null ? 'NO ACTIVE TRACK' : 'OUTPUT')
                  : song == null
                      ? (unresolvedIdentityLabel == null ? 'AWAITING TRACK' : 'IDENTITY UNVERIFIED')
                      : isReady
                          ? 'MUTED · READY'
                          : 'MUTED · PREPARING',
              style: const TextStyle(color: Colors.white70, fontSize: 8,
                fontWeight: FontWeight.w900, letterSpacing: 1.2))),
          ]))),
        const SizedBox(height: 8),
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Colors.white, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white60)),
        const SizedBox(height: 8),
        Text(
          liveSpectrum == null || liveSpectrum.isEmpty
              ? 'SIGNAL GUIDE · LIVE BANDS UNAVAILABLE'
              : liveSpectrum.any((value) => value.isFinite && value > 0.002)
                  ? 'LIVE OUTPUT · 32-BAND SPECTRUM'
                  : 'LIVE SPECTRUM · LEVELS AT FLOOR',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white38, fontSize: 8, letterSpacing: 0.8)),
        const SizedBox(height: 3),
        SizedBox(height: 58, width: double.infinity, child: _DeckWaveform(
          seed: song?.id ?? deckLabel, progress: progress, color: accent,
          spectrum: liveSpectrum, animate: isPlaying && isActive &&
              (liveSpectrum == null || liveSpectrum.isEmpty))),
        const SizedBox(height: 3),
        Row(children: [
          Text(_clock(position),
            style: const TextStyle(color: Colors.white70, fontSize: 10)),
          const Spacer(),
          Text(_clock(duration), style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ]),
      ]),
    );
  }
}

class _DeckWaveform extends StatefulWidget {
  const _DeckWaveform({required this.seed, required this.progress,
    required this.color, required this.animate, this.spectrum});
  final String seed;
  final double progress;
  final Color color;
  final bool animate;
  final List<double>? spectrum;

  @override
  State<_DeckWaveform> createState() => _DeckWaveformState();
}

class _DeckWaveformState extends State<_DeckWaveform> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  }

  void _syncAnimationPreference() {
    final shouldAnimate =
        widget.animate && !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimationPreference();
  }

  @override
  void didUpdateWidget(covariant _DeckWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimationPreference();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress.clamp(0.0, 1.0).toDouble();
    final liveSpectrum = widget.spectrum;
    final hasLiveBands = liveSpectrum != null && liveSpectrum.isNotEmpty;
    final hasLiveActivity = liveSpectrum?.any(
          (value) => value.isFinite && value > 0.002) ??
        false;
    return Semantics(
      image: true,
      label: '${!hasLiveBands
          ? 'Illustrative signal guide; live spectrum bands are unavailable.'
          : hasLiveActivity
              ? 'Live 32-band audio output spectrum.'
              : 'Live 32-band audio output spectrum; current levels are at the floor.'} '
          'Playback position ${(progress * 100).round()} percent.',
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _DeckWaveformPainter(
              seed: widget.seed,
              progress: progress,
              color: widget.color,
              phase: _controller.value,
              spectrum: widget.spectrum,
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckWaveformPainter extends CustomPainter {
  _DeckWaveformPainter({required this.seed, required this.progress,
    required this.color, required this.phase, this.spectrum});
  final String seed;
  final double progress, phase;
  final Color color;
  final List<double>? spectrum;

  int get _seedValue => seed.codeUnits.fold<int>(17,
    (value, unit) => (value * 31 + unit) & 0x7fffffff);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const count = 76;
    final center = size.height / 2;
    // Keep the complete bar train inside narrow deck tiles instead of
    // forcing a minimum bar width that can overflow small layouts.
    final gap = math.min(1.35, math.max(0.35, size.width / (count * 5)));
    final barWidth = (size.width - (count - 1) * gap) / count;
    final seedValue = _seedValue;
    final bands = spectrum;
    final hasLiveSpectrum = bands != null && bands.isNotEmpty;
    final bandCount = bands?.length ?? 0;
    final gridPaint = Paint()..color = Colors.white.withValues(alpha: 0.10)..strokeWidth = 0.7;
    for (var beat = 0; beat <= 8; beat++) {
      final x = size.width * beat / 8;
      canvas.drawLine(Offset(x, 2), Offset(x, size.height - 2), gridPaint);
    }
    for (var i = 0; i < count; i++) {
      final x = i * (barWidth + gap);
      double amplitude = 0;
      if (hasLiveSpectrum) {
        final sourcePosition = i * (bandCount - 1) / (count - 1);
        final lower = sourcePosition.floor();
        final upper = math.min(lower + 1, bandCount - 1);
        final blend = sourcePosition - lower;
        final lowerValue = bands[lower];
        final upperValue = bands[upper];
        final a = lowerValue.isFinite ? lowerValue.clamp(0.0, 1.0).toDouble() : 0.0;
        final b = upperValue.isFinite ? upperValue.clamp(0.0, 1.0).toDouble() : 0.0;
        amplitude = a + (b - a) * blend;
      }
      final envelope = hasLiveSpectrum
          ? math.sqrt(amplitude)
          : 0.25 + 0.75 * math.pow(
              (math.sin((i / count) * math.pi * 2.6 + seedValue % 13) + 1) / 2,
              0.75).toDouble();
      final texture = hasLiveSpectrum
          ? 1.0
          : 0.52 + 0.48 * math.sin(i * 1.71 + seedValue * 0.001).abs();
      final pulse = hasLiveSpectrum
          ? 1.0
          : 1 + 0.055 * math.sin(phase * math.pi * 2 + i * 0.12);
      final height = (hasLiveSpectrum
          ? 2.0 + size.height * 0.84 * envelope
          : size.height * 0.78 * envelope * texture * pulse)
          .clamp(2.0, size.height - 3);
      final played = i / count <= progress;
      final paint = Paint()..color = color.withValues(
        alpha: hasLiveSpectrum ? (0.35 + amplitude * 0.65) : played ? 0.98 : 0.30,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x + barWidth / 2, center),
          width: barWidth.clamp(0.35, 4).toDouble(), height: height.toDouble()),
        const Radius.circular(2)), paint);
    }
    final playheadX = size.width * progress;
    final playheadPaint = Paint()..color = Colors.white..strokeWidth = 1.4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    canvas.drawLine(Offset(playheadX, 0), Offset(playheadX, size.height), playheadPaint);
    canvas.drawCircle(Offset(playheadX, 3), 2.2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _DeckWaveformPainter old) =>
    old.seed != seed || old.progress != progress || old.color != color ||
    old.phase != phase || !listEquals(old.spectrum, spectrum);
}

class _TelemetryRow extends StatelessWidget {
  const _TelemetryRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 9),
        SizedBox(
          width: 104,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              color: valueColor ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
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
        blurEnabled: false,
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
