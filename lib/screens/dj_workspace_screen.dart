import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';

import '../navigation/shell_nav.dart';
import '../providers/audio_visualization_provider.dart';
import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../services/dj_session_coordinator.dart';
import '../ui/resonate_glass.dart';
import 'dj_suggestion_mix_screen.dart';
import 'dj_transition_studio_screen.dart';

/// Dedicated entry point for DJ preparation and live-session awareness.
///
/// This surface never owns a player. Manual deck transitions are delegated
/// to MusicProvider and must hold the shared playback-control arbiter while
/// Media3 prepares and promotes the incoming deck.
class DjWorkspaceScreen extends StatefulWidget {
  const DjWorkspaceScreen({super.key});

  @override
  State<DjWorkspaceScreen> createState() => _DjWorkspaceScreenState();
}

class _DjWorkspaceScreenState extends State<DjWorkspaceScreen> {
  bool _buildingMix = false;
  bool _manualTransitionBusy = false;
  bool _manualDeckPrepared = false;
  bool _manualCueDirty = false;
  int? _selectedDeckBIndex;
  double _manualFadeMs = 5000;
  double _manualCueMs = 0;
  MusicProvider? _musicProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _musicProvider ??= context.read<MusicProvider>();
  }

  @override
  void dispose() {
    final provider = _musicProvider;
    if (provider != null) unawaited(provider.cancelPreparedManualDjDeck());
    super.dispose();
  }

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _openTransitionStudio() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DjTransitionStudioScreen()),
    );
  }

  Future<void> _prepareManualDeck(int incomingQueueIndex) async {
    if (_manualTransitionBusy) return;
    setState(() {
      _manualTransitionBusy = true;
      _manualDeckPrepared = false;
      _manualCueDirty = false;
    });
    final provider = context.read<MusicProvider>();
    try {
      await provider.prepareManualDjDeck(
        incomingQueueIndex: incomingQueueIndex,
        incomingStartPosition: Duration(milliseconds: _manualCueMs.round()),
      );
      if (!mounted) {
        // The route may have been dismissed while native standby preparation
        // was in flight. Retire any lease acquired after dispose() ran.
        await provider.cancelPreparedManualDjDeck();
        return;
      }
      setState(() => _manualDeckPrepared = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deck B is prepared and ready.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _manualDeckPrepared = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deck B could not be prepared: $error')),
      );
    } finally {
      if (mounted) setState(() => _manualTransitionBusy = false);
    }
  }

  Future<void> _applyManualCue() async {
    if (_manualTransitionBusy || !_manualDeckPrepared) return;
    setState(() => _manualTransitionBusy = true);
    try {
      await context.read<MusicProvider>().cuePreparedManualDjDeck(
        Duration(milliseconds: _manualCueMs.round()),
      );
      if (!mounted) return;
      setState(() => _manualCueDirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deck B cue point updated.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _manualDeckPrepared = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deck B cue update failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _manualTransitionBusy = false);
    }
  }

  Future<void> _cancelPreparedDeck() async {
    if (_manualTransitionBusy) return;
    setState(() => _manualTransitionBusy = true);
    try {
      await context.read<MusicProvider>().cancelPreparedManualDjDeck();
      if (!mounted) return;
      setState(() {
        _manualDeckPrepared = false;
        _manualCueDirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deck B preparation cancelled; playback control released.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not cancel Deck B preparation: $error')),
      );
    } finally {
      if (mounted) setState(() => _manualTransitionBusy = false);
    }
  }

  Future<void> _selectIncomingTrack(int? value) async {
    if (value == null || _manualTransitionBusy) return;
    setState(() {
      _manualTransitionBusy = true;
      _manualDeckPrepared = false;
      _manualCueDirty = false;
    });
    try {
      // Retire the old standby and release its interactive lease before
      // allowing another prepare operation to start.
      await context.read<MusicProvider>().cancelPreparedManualDjDeck();
      if (!mounted) return;
      setState(() {
        _selectedDeckBIndex = value;
        _manualCueMs = 0;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change the incoming track: $error')),
      );
    } finally {
      if (mounted) setState(() => _manualTransitionBusy = false);
    }
  }

  Future<void> _crossfadePreparedDeck() async {
    if (_manualTransitionBusy || !_manualDeckPrepared || _manualCueDirty) return;
    setState(() => _manualTransitionBusy = true);
    try {
      await context.read<MusicProvider>().crossfadePreparedManualDjDeck(
        duration: Duration(milliseconds: _manualFadeMs.round()),
      );
      if (!mounted) return;
      setState(() => _manualDeckPrepared = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Manual DJ transition completed.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _manualDeckPrepared = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Manual DJ transition was not completed: $error')),
      );
    } finally {
      if (mounted) setState(() => _manualTransitionBusy = false);
    }
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
      body: Consumer3<MusicProvider, DjModeProvider, AudioVisualizationProvider>(
        builder: (context, music, dj, visualization, _) {
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
              Text('MANUAL DECK CONTROL', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Builder(builder: (context) {
                final manualDeckPrepared = music.hasPreparedManualDjDeck;
                final deckState = music.media3ShadowState;
                final activeDeckId = deckState?.activeDeckId ?? "A";
                final standbyDeckId = activeDeckId == "A" ? "B" : "A";
                // Keep the selector aligned with Media3's exact queue
                // eligibility rule. The native adapter filters empty paths;
                // exposing those rows here would let the operator select an
                // occurrence that can never become a standby deck.
                final targets = music.queue.asMap().entries
                    .where((entry) =>
                        entry.key != music.queueIndex &&
                        entry.value.filePath.trim().isNotEmpty)
                    .toList(growable: false);
                final selectedIndex = targets.any(
                  (entry) => entry.key == _selectedDeckBIndex,
                )
                    ? _selectedDeckBIndex
                    : (targets.isEmpty ? null : targets.first.key);
                final selectedSong = selectedIndex == null
                    ? null
                    : music.queue[selectedIndex];
                final cueMaxMs = selectedSong == null ||
                        selectedSong.duration <= Duration.zero
                    ? 0
                    : (selectedSong.duration.inMilliseconds - 1).clamp(0, 1 << 31);
                final cueValueMs = _manualCueMs.clamp(0.0, cueMaxMs.toDouble());
                final incomingMediaId = deckState?.incomingMediaId;
                final incomingStatus = deckState?.crossfadeStatus;
                final incomingReady = deckState?.incomingReady == true;
                final incomingIdentityMatches = selectedSong != null &&
                    incomingMediaId == selectedSong.id;
                // Readiness is a conjunction, not a single stale telemetry bit:
                // the selected occurrence, native media identity, and native
                // standby state must all agree before the UI calls Deck B ready.
                final incomingDeckReady = incomingReady &&
                    incomingIdentityMatches &&
                    incomingStatus == "ready" &&
                    !music.transitionInProgress;
                final standbyStateLabel = incomingIdentityMatches
                    ? incomingDeckReady
                        ? "Ready"
                        : incomingStatus == "preparing"
                            ? "Loaded · preparing"
                            : incomingStatus == "ready"
                                ? "Loaded · verifying"
                                : music.transitionInProgress
                                    ? "Transitioning"
                                    : "Not ready"
                    : incomingMediaId != null
                        ? "Different track loaded"
                        : incomingStatus == "preparing"
                            ? "Preparing"
                            : incomingReady
                                ? "Ready · identity unknown"
                                : "Empty";
                return ResonateGlassCard(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DeckPerformancePanel(
                        activeSong: song,
                        standbySong: selectedSong,
                        activeDeckId: activeDeckId,
                        activeProgress: progress,
                        activePosition: music.currentPosition,
                        activeDuration: duration,
                        standbyPosition: incomingIdentityMatches
                            ? (deckState?.incomingPosition ?? Duration.zero)
                            : Duration.zero,
                        standbyReady: incomingDeckReady,
                        isPlaying: music.isPlaying,
                        transitionActive: music.transitionInProgress,
                        liveSpectrum: visualization.frequencies,
                      ),
                      const SizedBox(height: 14),
                      Row(children: [
                        const Icon(Icons.speaker_group_rounded),
                        const SizedBox(width: 8),
                        Text('LIVE OUTPUT · DECK $activeDeckId', style: theme.textTheme.labelLarge),
                        const Spacer(),
                        const _StatusPill(label: 'Live output', active: true),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        song?.title ?? 'No active track',
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        song?.artist ?? 'Start playback to arm the decks.',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Divider(height: 22),
                      Row(children: [
                        const Icon(Icons.queue_music_rounded),
                        const SizedBox(width: 8),
                        Text('STANDBY · DECK $standbyDeckId', style: theme.textTheme.labelLarge),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        'Standby: $standbyStateLabel · Gain ${((deckState?.standbyDeckVolume ?? 0.0) * 100).round()}%',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        'Live gain: ${((deckState?.activeDeckVolume ?? 1.0) * 100).round()}%',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        'Underruns · Deck A ${deckState?.audioUnderrunCountA ?? 0} / Deck B ${deckState?.audioUnderrunCountB ?? 0}',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        'Audio sessions · Live ${deckState?.audioSessionId ?? '—'} / Standby ${deckState?.standbyAudioSessionId ?? '—'}',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (deckState?.lastUnderrunDeck != null)
                        Text(
                          'Last underrun · Deck ${deckState!.lastUnderrunDeck} · ${deckState.lastUnderrunBufferSizeFrames} frames (${deckState.lastUnderrunBufferSizeMs} ms) · ${deckState.lastUnderrunElapsedSinceFeedMs} ms since feed',
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (incomingMediaId != null) ...[
                        Text(
                          incomingIdentityMatches
                              ? 'Loaded: ${selectedSong!.title} · ${selectedSong.artist}'
                              : 'Loaded media ID differs from the selected track.',
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (incomingIdentityMatches)
                          Text(
                            'Standby position: ${(deckState?.incomingPosition.inMilliseconds ?? 0) ~/ 1000}s',
                            style: theme.textTheme.bodySmall,
                          ),
                      ] else if (incomingReady)
                        Text(
                          'Native standby reports ready, but its media identity is unavailable; selected-track readiness is not confirmed.',
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 8),
                      if (targets.isEmpty)
                        Text(
                          music.queue.length <= 1
                              ? 'Add another playable track to the active queue to prepare Deck B.'
                              : 'No other playable queue entries are available for Deck B.',
                          style: theme.textTheme.bodySmall,
                        )
                      else
                        DropdownButtonFormField<int>(
                          value: selectedIndex,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Incoming queue track',
                            border: OutlineInputBorder(),
                          ),
                          items: targets.map((entry) => DropdownMenuItem<int>(
                            value: entry.key,
                            child: Text(
                              '${entry.value.title} · ${entry.value.artist}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          )).toList(growable: false),
                          onChanged: _manualTransitionBusy
                              ? null
                              : (value) => unawaited(_selectIncomingTrack(value)),
                        ),
                      const SizedBox(height: 12),
                      Row(children: [
                        Text('Deck B cue-in', style: theme.textTheme.labelMedium),
                        const Spacer(),
                        Text(
                          cueMaxMs == 0
                              ? 'Start of track'
                              : '${(cueValueMs / 1000).toStringAsFixed(2)} s',
                          style: theme.textTheme.labelMedium,
                        ),
                      ]),
                      Slider(
                        value: cueValueMs,
                        min: 0,
                        max: cueMaxMs > 0 ? cueMaxMs.toDouble() : 1,
                        label: 'Deck B cue-in',
                        semanticFormatterCallback: (value) =>
                            '${(value / 1000).toStringAsFixed(2)} seconds',
                        onChanged: _manualTransitionBusy || cueMaxMs == 0
                            ? null
                            : (value) => setState(() {
                                _manualCueMs = value;
                                if (manualDeckPrepared) _manualCueDirty = true;
                              }),
                      ),
                      const SizedBox(height: 14),
                      Row(children: [
                        Text('Crossfade duration', style: theme.textTheme.labelMedium),
                        const Spacer(),
                        Text(
                          '${(_manualFadeMs / 1000).toStringAsFixed(2)} s',
                          style: theme.textTheme.labelMedium,
                        ),
                      ]),
                      Slider(
                        value: _manualFadeMs,
                        min: 250,
                        max: 15000,
                        divisions: 59,
                        label: 'Crossfade duration',
                        semanticFormatterCallback: (value) =>
                            '${(value / 1000).toStringAsFixed(2)} seconds',
                        onChanged: _manualTransitionBusy
                            ? null
                            : (value) => setState(() => _manualFadeMs = value),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: selectedIndex == null ||
                                  !music.isPlaying ||
                                  _manualTransitionBusy ||
                                  music.transitionInProgress
                              ? null
                              : () => _prepareManualDeck(selectedIndex),
                          icon: _manualTransitionBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.queue_music_rounded),
                          label: Text(
                            _manualTransitionBusy
                                ? 'Preparing Deck B…'
                                : manualDeckPrepared
                                    ? 'Re-prepare Deck B'
                                    : 'Prepare Deck B',
                          ),
                        ),
                      ),
                      if (manualDeckPrepared) ...[
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _manualTransitionBusy || !_manualCueDirty
                                ? null
                                : _applyManualCue,
                            icon: const Icon(Icons.my_location_rounded),
                            label: Text(
                              _manualCueDirty
                                  ? 'Apply updated cue point'
                                  : 'Cue point applied',
                            ),
                          ),
                        ),
                      ],
                      if (manualDeckPrepared) ...[
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _manualTransitionBusy ? null : _cancelPreparedDeck,
                            icon: const Icon(Icons.cancel_outlined),
                            label: const Text('Cancel Deck B preparation'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: !manualDeckPrepared ||
                                  _manualCueDirty ||
                                  !music.isPlaying ||
                                  _manualTransitionBusy ||
                                  music.transitionInProgress
                              ? null
                              : _crossfadePreparedDeck,
                          icon: _manualTransitionBusy && manualDeckPrepared
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.swap_horiz_rounded),
                          label: Text(
                            _manualTransitionBusy && manualDeckPrepared
                                ? 'Transition in progress…'
                                : 'Crossfade prepared Deck B',
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Prepare loads the incoming occurrence on muted Media3 standby. You can adjust and apply its cue before starting the crossfade. Each live operation takes the interactive playback lease; native Media3 remains responsible for the gain envelope and deck promotion.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                );
              }),
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

class _DeckPerformancePanel extends StatelessWidget {
  const _DeckPerformancePanel({
    required this.activeSong, required this.standbySong,
    required this.activeDeckId, required this.activeProgress,
    required this.activePosition, required this.activeDuration,
    required this.standbyPosition, required this.standbyReady,
    required this.isPlaying, required this.transitionActive,
    required this.liveSpectrum,
  });

  final Song? activeSong;
  final Song? standbySong;
  final String activeDeckId;
  final double activeProgress;
  final Duration activePosition;
  final Duration activeDuration;
  final Duration standbyPosition;
  final bool standbyReady;
  final bool isPlaying;
  final bool transitionActive;
  final List<double> liveSpectrum;

  @override
  Widget build(BuildContext context) {
    final activeColor = const Color(0xFF62D6FF);
    final standbyColor = const Color(0xFFB18CFF);
    final standbyId = activeDeckId == 'A' ? 'B' : 'A';
    final standbyDuration = standbySong?.duration ?? Duration.zero;
    final standbyProgress = standbyDuration.inMilliseconds <= 0 ? 0.0 :
      (standbyPosition.inMilliseconds / standbyDuration.inMilliseconds).clamp(0.0, 1.0).toDouble();
    final theme = Theme.of(context);
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
              deckLabel: 'DECK ' + activeDeckId,
              role: 'ON AIR',
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
              deckLabel: 'DECK ' + standbyId,
              role: 'STANDBY',
              song: standbySong,
              accent: standbyColor,
              progress: standbyProgress,
              duration: standbyDuration,
              position: standbyPosition,
              isActive: false,
              isReady: standbyReady,
              isPlaying: false,
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
            standbyReady ? 'STANDBY ARMED · READY FOR OPERATOR HANDOFF' :
            'DUAL-DECK MONITOR · STANDBY IS MUTED',
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: transitionActive ? const Color(0xFFFFD18B) : Colors.white70,
              letterSpacing: 0.55, fontWeight: FontWeight.w700))),
          AnimatedContainer(
            duration: const Duration(milliseconds: 420), width: 8, height: 8,
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
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
  });
  final String deckLabel, role;
  final Song? song;
  final Color accent;
  final double progress;
  final Duration duration;
  final Duration position;
  final bool isActive, isReady, isPlaying;
  final List<double>? spectrum;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    return (seconds ~/ 60).toString() + ':' + (seconds % 60).toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    final liveSpectrum = spectrum;
    final title = song?.title ?? (isActive ? 'No active track' : 'Choose incoming track');
    final artist = song?.artist ?? (isActive ? 'Start playback to activate' : 'Deck is empty');
    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
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
              isReady ? (isActive ? 'OUTPUT' : 'MUTED') : 'EMPTY',
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
          liveSpectrum == null
              ? 'SIGNAL MAP · VISUAL GUIDE'
              : liveSpectrum.any((value) => value.isFinite && value > 0.002)
                  ? 'LIVE OUTPUT · 32-BAND SPECTRUM'
                  : 'LIVE SPECTRUM · LEVELS AT FLOOR',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white38, fontSize: 8, letterSpacing: 0.8)),
        const SizedBox(height: 3),
        SizedBox(height: 58, width: double.infinity, child: _DeckWaveform(
          seed: song?.id ?? deckLabel, progress: progress, color: accent,
          spectrum: liveSpectrum, animate: isPlaying && isActive && liveSpectrum == null)),
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
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _DeckWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
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
    final hasLiveActivity = liveSpectrum?.any(
          (value) => value.isFinite && value > 0.002) ??
        false;
    return Semantics(
      image: true,
      label: '${liveSpectrum == null
          ? 'Illustrative signal guide, not measured audio waveform data.'
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
