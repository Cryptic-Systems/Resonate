import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../dj_engine/core/dj_types.dart';
import '../dj_engine/intelligence/dj_transition_brain.dart';
import '../models/song.dart';
import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../providers/music_provider.dart';
import '../services/dj_transition_preset_store.dart';
import '../services/dj_cue_snapper.dart';
import '../services/media3_playback_client.dart';
import '../ui/resonate_glass.dart';

/// Pair-based cue editor. Saved markers are consumed by the DJ profiles used
/// by the live playback transition brain.
class DjTransitionStudioScreen extends StatefulWidget {
  const DjTransitionStudioScreen({super.key});
  @override
  State<DjTransitionStudioScreen> createState() => _DjTransitionStudioScreenState();
}

class _DjTransitionStudioScreenState extends State<DjTransitionStudioScreen> {
  static const _brain = DjTransitionBrain();
  Song? _outgoing, _incoming;
  DjTrackProfile? _profileA, _profileB;
  List<DjTransitionCandidate> _candidates = const [];
  DjTransitionCandidate? _recommended;
  DjTransitionKind? _preferredKind;
  bool _hasSavedPreset = false;
  bool _repeatSameTrack = false;
  bool _snapCues = true;
  int _outCue = 0, _inCue = 0, _fadeMs = 6500;
  bool _busy = false, _saving = false;
  bool _audioPreviewActive = false;
  bool _audioPreviewStarting = false;
  int _previewGeneration = 0;
  MusicProvider? _previewProvider;
  String? _status, _error;

  int _duration(Song? song, DjTrackProfile? profile) {
    final ms = song?.duration.inMilliseconds ?? 0;
    return ms > 0 ? ms : (profile?.durationMs ?? 0);
  }
  String _clock(int ms) {
    final seconds = (ms ~/ 1000).clamp(0, 1 << 30);
    return (seconds ~/ 60).toString() + ':' + (seconds % 60).toString().padLeft(2, '0');
  }

  Future<Song?> _choose(String title, {String? excludeId}) async {
    final songs = context.read<LibraryProvider>().allSongs.where((s) => s.id != excludeId).toList();
    final search = TextEditingController();
    return showModalBottomSheet<Song>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (context, refresh) {
        final q = search.text.toLowerCase().trim();
        final rows = q.isEmpty ? songs : songs.where((s) =>
          s.title.toLowerCase().contains(q) || s.artist.toLowerCase().contains(q) ||
          s.album.toLowerCase().contains(q)).toList();
        return SafeArea(child: SizedBox(
          height: MediaQuery.of(context).size.height * .78,
          child: Column(children: [
            Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                TextField(controller: search, autofocus: true,
                  onChanged: (_) => refresh(() {}),
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search title, artist or album', border: OutlineInputBorder())),
              ])),
            Expanded(child: rows.isEmpty ? const Center(child: Text('No matching library tracks'))
              : ListView.builder(itemCount: rows.length, itemBuilder: (_, i) {
                  final s = rows[i];
                  return ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.music_note_rounded)),
                    title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(_clock(s.duration.inMilliseconds)),
                    onTap: () => Navigator.pop(sheet, s));
                })),
          ])));
      }),
    ).whenComplete(search.dispose);
  }

  Future<void> _pick(bool outgoing) async {
    await _stopAudioPreview();
    final song = await _choose(_repeatSameTrack ? 'Choose track to repeat' :
      (outgoing ? 'Choose outgoing track' : 'Choose incoming track'),
      excludeId: _repeatSameTrack ? null : (outgoing ? _incoming?.id : _outgoing?.id));
    if (song == null || !mounted) return;
    setState(() {
      if (_repeatSameTrack) {
        _outgoing = song; _incoming = song; _profileA = null; _profileB = null;
      } else if (outgoing) { _outgoing = song; _profileA = null; }
      else { _incoming = song; _profileB = null; }
      _candidates = const []; _recommended = null; _preferredKind = null; _hasSavedPreset = false; _status = null; _error = null;
    });
  }

  Future<DjTrackProfile?> _loadProfile(Song song) async {
    final service = context.read<DjModeProvider>().analysis;
    final cached = await service.getProfile(song.id);
    if (cached != null) return cached;
    await service.analyzeSong(song, force: true);
    return service.getProfile(song.id);
  }

  Future<void> _analyze() async {
    await _stopAudioPreview();
    if (!mounted) return;
    final a = _outgoing, b = _incoming;
    if (a == null || b == null || _busy) return;
    setState(() { _busy = true; _status = 'Analyzing outgoing track…'; _error = null; });
    try {
      final pa = await _loadProfile(a);
      if (!mounted) return;
      setState(() => _status = 'Analyzing incoming track…');
      final pb = await _loadProfile(b);
      if (!mounted) return;
      if (pa == null || pb == null) {
        setState(() {
          _profileA = pa; _profileB = pb; _status = null;
          _error = 'A complete DJ profile is not available for both tracks yet. Library analysis may still be processing; playback will use its safe crossfade.';
        });
        return;
      }
      final saved = await DjTransitionPresetStore.get(a.id, b.id);
      if (!mounted) return;
      final usable = saved?.isUsableFor(
        outgoingPositionMs: 0,
        outgoingDurationMs: pa.durationMs ?? (a.duration.inMilliseconds > 0 ? a.duration.inMilliseconds : null),
        incomingDurationMs: pb.durationMs ?? (b.duration.inMilliseconds > 0 ? b.duration.inMilliseconds : null),
      ) ?? false;
      setState(() {
        _profileA = pa; _profileB = pb;
        _hasSavedPreset = usable;
        _outCue = usable ? saved!.outgoingCueMs :
          (pa.transitions.bestOutroMs ?? (pa.durationMs ?? a.duration.inMilliseconds).clamp(0, 1 << 30));
        _inCue = usable ? saved!.incomingCueMs : (pb.transitions.bestIntroMs ?? 0);
        _fadeMs = usable ? saved!.durationMs : 6500;
        _preferredKind = usable ? saved!.preferredKind : null;
        _status = usable ? 'Loaded your saved settings for this track pair.' : null;
      });
      _rebuild();
    } catch (e) {
      if (mounted) setState(() { _status = null; _error = 'Analysis failed: ' + e.toString(); });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _rebuild() {
    final pa = _profileA, pb = _profileB;
    if (pa == null || pb == null) return;
    final pair = DjTransitionPreset(
      outgoingSongId: _outgoing!.id,
      incomingSongId: _incoming!.id,
      outgoingCueMs: _outCue,
      incomingCueMs: _inCue,
      durationMs: _fadeMs,
      preferredKind: _preferredKind,
    );
    final a = pair.applyOutgoing(pa), b = pair.applyIncoming(pb);
    final policy = context.read<DjModeProvider>().policy;
    final rows = _brain.generate(outgoing: a, incoming: b, outgoingPositionMs: 0,
      preferredDurationMs: _fadeMs, maxDurationMs: 15000, policy: policy)
      ..sort((x, y) => y.score.compareTo(x.score));
    final preferred = _preferredKind == null ? <DjTransitionCandidate>[] :
      rows.where((c) => c.kind == _preferredKind && policy.acceptsCandidate(c)).toList();
    final best = preferred.isNotEmpty ? preferred.first :
      _brain.choose(outgoing: a, incoming: b, outgoingPositionMs: 0,
        preferredDurationMs: _fadeMs, maxDurationMs: 15000, policy: policy);
    setState(() { _candidates = rows; _recommended = best; });
  }

  Future<void> _save() async {
    final a = _profileA, b = _profileB;
    if (a == null || b == null || _saving) return;
    final da = _duration(_outgoing, a), db = _duration(_incoming, b);
    if (_outCue < 0 || _inCue < 0 || (da > 0 && _outCue >= da) || (db > 0 && _inCue >= db)) {
      setState(() => _error = 'Cue points must be inside their track durations.'); return;
    }
    if (_repeatSameTrack && da > 0) {
      final remainingMs = da - _outCue;
      if (remainingMs < _fadeMs + 1200 || remainingMs > 30000) {
        setState(() => _error = 'For repeat-one, Mix-Out must be within the final 30 seconds and leave at least 1.2 seconds beyond the blend duration.');
        return;
      }
    }
    setState(() { _saving = true; _error = null; });
    try {
      await DjTransitionPresetStore.save(DjTransitionPreset(
        outgoingSongId: _outgoing!.id,
        incomingSongId: _incoming!.id,
        outgoingCueMs: _outCue,
        incomingCueMs: _inCue,
        durationMs: _fadeMs,
        preferredKind: _preferredKind,
      ));
      if (!mounted) return;
      setState(() {
        _hasSavedPreset = true;
        _status = _repeatSameTrack
          ? 'Repeat preset saved. DJ repeat-one will prefer these cues when safe.'
          : 'Pair preset saved. DJ playback will prefer these cues and strategy when safe.';
      });
      _rebuild();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save cue points: ' + e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _playAudioPreview() async {
    final candidate = _recommended;
    final outgoing = _outgoing, incoming = _incoming;
    if (candidate == null || outgoing == null || incoming == null ||
        _audioPreviewStarting || _audioPreviewActive) return;
    final provider = context.read<MusicProvider>();
    final generation = ++_previewGeneration;
    // Register ownership before awaiting the native command. If the screen is
    // popped while Media3 is preparing, dispose can now still stop this session.
    _previewProvider = provider;
    _audioPreviewActive = true;
    _audioPreviewStarting = true;
    if (mounted) {
      setState(() {
        _status = 'Preparing synchronized audio preview…';
        _error = null;
      });
    }
    try {
      await provider.previewDjTransition(
        outgoingUri: Media3QueueItem.fromSong(outgoing).uri,
        incomingUri: Media3QueueItem.fromSong(incoming).uri,
        outgoingStart: Duration(milliseconds: candidate.outgoingStartMs),
        incomingStart: Duration(milliseconds: candidate.incomingStartMs),
        duration: Duration(milliseconds: candidate.durationMs),
      );
      // A stop, track change, or route disposal may have happened while the
      // platform command was in flight. Issue a final stop after it completes
      // so a late native prepare cannot resurrect an abandoned audition.
      if (!mounted || generation != _previewGeneration) {
        await provider.stopDjTransitionPreview();
        return;
      }
      setState(() => _status =
        'Audible preview started. It stops automatically when the blend finishes.');
    } catch (e) {
      if (generation == _previewGeneration) {
        _audioPreviewActive = false;
        _previewProvider = null;
        if (mounted) setState(() => _error = 'Could not start audible preview: $e');
      }
      // A failed/partially completed platform start must not leave either
      // preview deck or its temporary duck gain active.
      try {
        await provider.stopDjTransitionPreview();
      } catch (_) {
        // Preserve the original start error for the operator.
      }
    } finally {
      // Keep a second audition from racing an older in-flight native prepare.
      // Stop invalidates its generation, but this operation owns the start lock
      // until its platform Future has settled.
      _audioPreviewStarting = false;
    }
  }

  Future<void> _stopAudioPreview() async {
    ++_previewGeneration;
    final provider = _previewProvider;
    _audioPreviewActive = false;
    _previewProvider = null;
    if (provider == null) return;
    try {
      await provider.stopDjTransitionPreview();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not stop audible preview: $e');
    }
  }

  void _showPreview() {
    final candidate = _recommended;
    final outgoing = _outgoing, incoming = _incoming;
    if (candidate == null || outgoing == null || incoming == null) return;
    final outDuration = _duration(outgoing, _profileA);
    final inDuration = _duration(incoming, _profileB);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Transition preview'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_kind(candidate.kind), style: Theme.of(dialogContext).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(outgoing.title + ' → ' + incoming.title,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(dialogContext).textTheme.bodySmall),
              const SizedBox(height: 12),
              Text('Synchronized blend window · ' + (candidate.durationMs / 1000).toStringAsFixed(1) + ' s',
                style: Theme.of(dialogContext).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text('Both preview decks start at their own cue; the highlighted regions show the shared audition interval.',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              _previewLane('OUTGOING', candidate.outgoingStartMs, outDuration,
                candidate.durationMs, Theme.of(dialogContext).colorScheme.primary),
              const SizedBox(height: 12),
              _previewLane('INCOMING', candidate.incomingStartMs, inDuration,
                candidate.durationMs, Theme.of(dialogContext).colorScheme.tertiary),
              const SizedBox(height: 14),
              Text('Mix-Out ' + _clock(candidate.outgoingStartMs) + ' · Mix-In ' +
                _clock(candidate.incomingStartMs)),
              const SizedBox(height: 6),
              Text('Overall score ' + (candidate.score * 100).round().toString() +
                '% · Analysis confidence ' + (candidate.confidence * 100).round().toString() + '%'),
              const SizedBox(height: 14),
              _scoreBreakdown(candidate),
              if (candidate.risks.isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('Risk checks: ' + candidate.risks.map((r) => r.name).join(', '),
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(dialogContext).colorScheme.error)),
              ),
              const SizedBox(height: 12),
              Text('Audition uses the isolated Media3 preview decks. Canonical playback continues and its position and queue state are not changed.',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
        actions: [
          TextButton.icon(onPressed: _playAudioPreview, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play audio')),
          TextButton.icon(onPressed: _stopAudioPreview, icon: const Icon(Icons.stop_rounded), label: const Text('Stop')),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
        ],
      ),
    ).whenComplete(() => unawaited(_stopAudioPreview()));
  }

  Widget _previewLane(String label, int cueMs, int trackDurationMs,
      int blendDurationMs, Color color) {
    final startFraction = trackDurationMs > 0
        ? (cueMs / trackDurationMs).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final endFraction = trackDurationMs > 0
        ? ((cueMs + blendDurationMs) / trackDurationMs).clamp(0.0, 1.0).toDouble()
        : startFraction;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label + ' · ' + _clock(cueMs) + ' → ' +
        _clock(cueMs + blendDurationMs), style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 5),
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final left = width * startFraction;
        final blendWidth = (width * endFraction - left).clamp(0.0, width - left);
        return SizedBox(height: 14, child: Stack(children: [
          Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ))),
          if (blendWidth > 0)
            Positioned(left: left, top: 0, bottom: 0, width: blendWidth,
              child: DecoratedBox(decoration: BoxDecoration(
                color: color.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(4),
              ))),
          Positioned(left: (left - 1).clamp(0.0, (width - 2).clamp(0.0, width)),
            top: 0, bottom: 0,
            child: Container(width: 2, color: color)),
          if (blendWidth > 0)
            Positioned(left: (left + blendWidth - 1).clamp(0.0, (width - 2).clamp(0.0, width)),
              top: 0, bottom: 0,
              child: Container(width: 2, color: color.withValues(alpha: 0.8))),
        ]));
      }),
    ]);
  }

  @override
  void dispose() {
    final provider = _previewProvider;
    if (_audioPreviewActive && provider != null) {
      unawaited(provider.stopDjTransitionPreview());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final da = _duration(_outgoing, _profileA), db = _duration(_incoming, _profileB);
    return ResonateGlassScaffold(title: const Text('DJ Transition Studio'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Text(_repeatSameTrack ? 'Shape how a track repeats' : 'Shape how two tracks meet',
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(_repeatSameTrack
          ? 'Design a clean self-transition using the track’s outro, intro, beat grid and energy. Repeat settings stay separate from global analysis.'
          : 'Compare beat, phrase, energy, harmonic and structure compatibility. Edit pair-specific cues without changing either track’s global analysis.',
          style: theme.textTheme.bodyMedium),
        const SizedBox(height: 18),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: _repeatSameTrack,
          title: const Text('Configure repeat-one transition'),
          subtitle: const Text('Design the handoff from this track back into itself.'),
          onChanged: (enabled) {
            unawaited(_stopAudioPreview());
            setState(() {
              _repeatSameTrack = enabled;
              if (enabled && _outgoing != null) _incoming = _outgoing;
              if (!enabled && identical(_outgoing, _incoming)) _incoming = null;
              _profileA = null; _profileB = null; _candidates = const [];
              _recommended = null; _preferredKind = null; _hasSavedPreset = false;
              _status = null; _error = null;
            });
          },
        ),
        _track(_repeatSameTrack ? 'REPEATING TRACK' : 'OUTGOING',
          _repeatSameTrack ? 'Choose the track whose next play should blend in' : 'The track being mixed out',
          _outgoing, () => _pick(true)),
        if (!_repeatSameTrack) ...[
          const SizedBox(height: 10),
          Center(child: Icon(Icons.south_rounded, color: theme.colorScheme.primary)),
          const SizedBox(height: 10),
          _track('INCOMING', 'The track being mixed in', _incoming, () => _pick(false)),
        ] else if (_outgoing != null) ...[
          const SizedBox(height: 8),
          Text('The same analyzed track supplies both decks. Mix-Out and Mix-In remain independently editable.',
            style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _busy || _outgoing == null || _incoming == null ? null : _analyze,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_awesome_rounded),
          label: Text(_busy ? 'Analyzing pair…' : 'Analyze transition pair')),
        if (_status != null) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text(_status!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary))),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error))),
        if (_profileA != null && _profileB != null) ...[
          const SizedBox(height: 24), _heading('Track structure'),
          _timeline('OUTGOING', _outgoing, _profileA!, _outCue, da,
            Theme.of(context).colorScheme.primary, outgoing: true),
          const SizedBox(height: 10),
          _timeline('INCOMING', _incoming, _profileB!, _inCue, db,
            Theme.of(context).colorScheme.tertiary, outgoing: false),
          const SizedBox(height: 24), _heading('Mix points'),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _snapCues,
            title: const Text('Snap to analyzed markers'),
            subtitle: const Text('Uses confident beats, phrase boundaries and safe mix points; free positioning remains available.'),
            onChanged: (value) => setState(() => _snapCues = value),
          ),
          _cue('Mix-Out', 'Outgoing · ' + _clock(_outCue), _outCue, da, (v) { unawaited(_stopAudioPreview()); final cue = _snapCues ? DjCueSnapper.snap(_profileA!, v, da, outgoing: true) : v; setState(() => _outCue = cue); _rebuild(); }),
          _cue('Mix-In', 'Incoming · ' + _clock(_inCue), _inCue, db, (v) { unawaited(_stopAudioPreview()); final cue = _snapCues ? DjCueSnapper.snap(_profileB!, v, db, outgoing: false) : v; setState(() => _inCue = cue); _rebuild(); }),
          const SizedBox(height: 10),
          _overlapWindow(da, db),
          const SizedBox(height: 8), _heading('Blend duration'),
          Text((_fadeMs / 1000).toStringAsFixed(1) + ' seconds'),
          Slider(value: _fadeMs.toDouble(), min: 2000, max: 15000, divisions: 26,
            label: (_fadeMs / 1000).toStringAsFixed(1) + ' s',
            onChanged: (v) { unawaited(_stopAudioPreview()); setState(() => _fadeMs = v.round()); _rebuild(); }),
          const SizedBox(height: 12), _heading('Transition analysis'),
          if (_recommended != null) _recommendation(_recommended!),
          const SizedBox(height: 10),
          for (final candidate in _candidates) _candidate(candidate),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _recommended == null ? null : _showPreview,
              icon: const Icon(Icons.visibility_rounded),
              label: const Text('Preview transition'),
            )),
            const SizedBox(width: 10),
            Expanded(child: FilledButton.icon(onPressed: _saving ? null : _save,
              icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_rounded),
              label: Text(_saving ? 'Saving…' : (_repeatSameTrack ? 'Save repeat preset' : 'Save pair preset')))),
          ]),
          if (_hasSavedPreset) Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving ? null : () async {
                await DjTransitionPresetStore.delete(_outgoing!.id, _incoming!.id);
                if (!mounted) return;
                setState(() {
                   _hasSavedPreset = false;
                   _preferredKind = null;
                   _status = _repeatSameTrack ? 'Repeat preset removed.' : 'Pair preset removed.';
                 });
                _rebuild();
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(_repeatSameTrack ? 'Remove repeat preset' : 'Remove pair preset'),
            )),
          const SizedBox(height: 8),
          Text('Pair cues are stored separately from global track analysis. The selected strategy is a preference; playback still applies confidence and risk checks.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ]));
  }

  Widget _track(String label, String hint, Song? song, VoidCallback tap) =>
    ResonateGlassCard(margin: EdgeInsets.zero, padding: EdgeInsets.zero,
      child: ListTile(onTap: tap,
        leading: const CircleAvatar(child: Icon(Icons.album_rounded)),
        title: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.1)),
        subtitle: Text(song == null ? hint : song.title + ' · ' + song.artist, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right_rounded)));

  Widget _heading(String text) => Padding(padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)));

  void _moveTimelineCue({required bool outgoing, required double dx,
      required double width, required int durationMs}) {
    if (width <= 0 || durationMs <= 0) return;
    final requested = (dx.clamp(0.0, width) / width * durationMs).round();
    final profile = outgoing ? _profileA : _profileB;
    if (profile == null) return;
    final cue = _snapCues
        ? DjCueSnapper.snap(profile, requested, durationMs, outgoing: outgoing)
        : requested.clamp(0, durationMs).toInt();
    unawaited(_stopAudioPreview());
    setState(() {
      if (outgoing) { _outCue = cue; } else { _inCue = cue; }
    });
    _rebuild();
  }

  Widget _timeline(String label, Song? song, DjTrackProfile profile,
      int cueMs, int durationMs, Color accent, {required bool outgoing}) {
    final duration = durationMs > 0 ? durationMs : 1;
    final bpm = profile.beatGrid.usable
        ? profile.beatGrid.bpm!.toStringAsFixed(1)
        : '—';
    final confidence = (profile.analysisConfidence.clamp(0.0, 1.0) * 100).round();
    return ResonateGlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800, letterSpacing: 1.0))),
            Text('${bpm} BPM · ${confidence}% analysis',
              style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: 3),
          Text(song?.title ?? 'Track',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _moveTimelineCue(outgoing: outgoing,
              dx: details.localPosition.dx, width: constraints.maxWidth, durationMs: duration),
            onHorizontalDragUpdate: (details) => _moveTimelineCue(outgoing: outgoing,
              dx: details.localPosition.dx, width: constraints.maxWidth, durationMs: duration),
            child: SizedBox(
              height: 88,
              width: double.infinity,
              child: CustomPaint(
                painter: _DjTimelinePainter(
                  profile: profile,
                  durationMs: duration,
                  cueMs: cueMs.clamp(0, duration).toInt(),
                  accent: accent,
                  baseline: Theme.of(context).colorScheme.outlineVariant,
                  surface: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
          )),
          const SizedBox(height: 5),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('0:00', style: Theme.of(context).textTheme.labelSmall),
            Text('Mix cue · ${_clock(cueMs)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: accent, fontWeight: FontWeight.w700)),
            Text(_clock(duration), style: Theme.of(context).textTheme.labelSmall),
          ]),
          if (profile.beatGrid.usable)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${profile.beatGrid.beatsPerBar}/4 beat grid'
                '${profile.beatGrid.phraseConfidence >= 0.6 ? ' · phrase markers available' : ''}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _overlapWindow(int outgoingDuration, int incomingDuration) {
    final fade = _fadeMs;
    final outEnd = (_outCue + fade).clamp(0, outgoingDuration).toInt();
    final inEnd = (_inCue + fade).clamp(0, incomingDuration).toInt();
    return ResonateGlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Synchronized blend window', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Both lanes represent the same ${_clock(fade)} blend interval, positioned at their independent track cues.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        _overlapLane('OUT', _outCue, outEnd, outgoingDuration, Theme.of(context).colorScheme.primary),
        const SizedBox(height: 9),
        _overlapLane('IN', _inCue, inEnd, incomingDuration, Theme.of(context).colorScheme.tertiary),
        const SizedBox(height: 8),
        Text('Mix-Out ${_clock(_outCue)} → ${_clock(outEnd)}  ·  Mix-In ${_clock(_inCue)} → ${_clock(inEnd)}', style: Theme.of(context).textTheme.labelSmall),
      ]),
    );
  }

  Widget _overlapLane(String label, int start, int end, int duration, Color color) {
    final safeDuration = duration > 0 ? duration : 1;
    return Row(children: [
      SizedBox(width: 30, child: Text(label, style: Theme.of(context).textTheme.labelSmall)),
      Expanded(child: LayoutBuilder(builder: (context, constraints) {
        final left = constraints.maxWidth * (start / safeDuration).clamp(0.0, 1.0);
        final right = constraints.maxWidth * (end / safeDuration).clamp(0.0, 1.0);
        return SizedBox(height: 12, child: Stack(children: [
          Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)))),
          Positioned(left: left, width: (right - left).clamp(0.0, constraints.maxWidth - left).toDouble(), top: 0, bottom: 0, child: DecoratedBox(decoration: BoxDecoration(color: color.withOpacity(0.72), borderRadius: BorderRadius.circular(5)))),
        ]));
      })),
    ]);
  }

  Widget _cue(String title, String subtitle, int value, int duration, ValueChanged<int> changed) {
    final max = (duration > 0 ? duration : 1).toDouble();
    return ResonateGlassCard(margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        Slider(value: value.toDouble().clamp(0, max).toDouble(), min: 0, max: max, onChanged: (v) => changed(v.round())),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('0:00'), Text(_clock(max.round()))]),
      ]));
  }

  Widget _recommendation(DjTransitionCandidate c) => ResonateGlassCard(
    margin: EdgeInsets.zero, padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.auto_awesome_rounded, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text('Recommended · ' + _kind(c.kind),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _metric('Score', c.score)),
        Expanded(child: _metric('Confidence', c.confidence)),
        Expanded(child: Text((c.durationMs / 1000).toStringAsFixed(1) + ' s')),
      ]),
      const SizedBox(height: 10),
      Text('Mix-Out ' + _clock(c.outgoingStartMs) + ' → Mix-In ' + _clock(c.incomingStartMs)),
      const SizedBox(height: 14),
      _scoreBreakdown(c),
      if (c.risks.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10),
        child: Text('Risks: ' + c.risks.map((r) => r.name).join(', '),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error))),
    ]));

  Widget _scoreBreakdown(DjTransitionCandidate candidate) {
    const labels = <String, String>{
      'tempo': 'Tempo compatibility',
      'harmonic': 'Harmonic compatibility',
      'energy': 'Energy trajectory',
      'spectrum': 'Frequency balance',
      'phrase': 'Phrase alignment',
      'structure': 'Track structure',
      'silence': 'Outgoing silence safety',
    };
    const explanations = <String, String>{
      'tempo': 'BPM relationship and beat-grid compatibility',
      'harmonic': 'Key compatibility when harmonic mixing is enabled',
      'energy': 'How the outgoing and incoming energy curves connect',
      'spectrum': 'Bass, midrange and high-frequency compatibility',
      'phrase': 'Confidence in phrase and bar alignment',
      'structure': 'Intro, outro and section-boundary evidence',
      'silence': 'Silence or near-silence around the outgoing cue',
    };
    final order = labels.keys.where(candidate.scores.containsKey).toList();
    if (order.isEmpty) {
      return Text('Detailed scoring evidence is unavailable for this candidate.',
        style: Theme.of(context).textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Why this blend', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final key in order)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(labels[key]!,
                    style: Theme.of(context).textTheme.bodySmall)),
                  Text('${(candidate.scores[key]!.clamp(0.0, 1.0) * 100).round()}%',
                    style: Theme.of(context).textTheme.labelMedium),
                ]),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: candidate.scores[key]!.isFinite
                        ? candidate.scores[key]!.clamp(0.0, 1.0).toDouble()
                        : 0.0,
                    minHeight: 5,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 2),
                Text(explanations[key]!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        Text('These are the transition engine’s component scores, not independent probabilities. Overall score and confidence remain separate.',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _metric(String label, double value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text((value * 100).round().toString() + '%', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
    Text(label, style: Theme.of(context).textTheme.bodySmall),
  ]);

  Widget _candidate(DjTransitionCandidate c) {
    final accepted = context.read<DjModeProvider>().policy.acceptsCandidate(c);
    final selected = _preferredKind == c.kind ||
        (_preferredKind == null && c.kind == _recommended?.kind);
    final colors = Theme.of(context).colorScheme;
    final details = 'Score ' + (c.score * 100).round().toString() +
        '% · Confidence ' + (c.confidence * 100).round().toString() +
        '% · ' + _clock(c.outgoingStartMs) + ' → ' + _clock(c.incomingStartMs);
    return ResonateGlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.zero,
      child: ListTile(
        enabled: accepted,
        onTap: accepted ? () {
          unawaited(_stopAudioPreview());
          setState(() {
            _preferredKind = c.kind;
            _outCue = c.outgoingStartMs;
            _inCue = c.incomingStartMs;
            _fadeMs = c.durationMs.clamp(2000, 15000);
          });
          _rebuild();
        } : null,
        leading: Icon(
          !accepted ? Icons.lock_outline_rounded :
              selected ? Icons.check_circle_rounded : Icons.graphic_eq_rounded,
          color: !accepted ? colors.onSurfaceVariant :
              selected ? colors.primary : null,
        ),
        title: Text(_kind(c.kind)),
        subtitle: Text(accepted ? details :
          '$details · Unavailable under the current DJ safety policy'),
        trailing: Text((c.durationMs / 1000).toStringAsFixed(1) + 's'),
      ),
    );
  }

  String _kind(DjTransitionKind kind) => switch (kind) {
    DjTransitionKind.outroIntro => 'Outro → Intro',
    DjTransitionKind.phraseBlend => 'Phrase blend',
    DjTransitionKind.breakdownDrop => 'Breakdown → Drop',
    DjTransitionKind.beatBlend => 'Beat blend',
    DjTransitionKind.energyBridge => 'Energy bridge',
    DjTransitionKind.safeCrossfade => 'Safe crossfade',
  };
}


class _DjTimelinePainter extends CustomPainter {
  const _DjTimelinePainter({
    required this.profile,
    required this.durationMs,
    required this.cueMs,
    required this.accent,
    required this.baseline,
    required this.surface,
  });

  final DjTrackProfile profile;
  final int durationMs;
  final int cueMs;
  final Color accent;
  final Color baseline;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || durationMs <= 0) return;
    double xFor(int ms) =>
        (ms.clamp(0, durationMs) / durationMs) * size.width;
    final trackRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    canvas.drawRRect(trackRect, Paint()..color = surface.withOpacity(0.55));

    for (final section in profile.sections) {
      if (section.endMs <= section.startMs ||
          section.endMs <= 0 || section.startMs >= durationMs) continue;
      final rect = Rect.fromLTRB(
        xFor(section.startMs), 0, xFor(section.endMs), size.height,
      );
      canvas.drawRect(rect, Paint()..color = accent.withOpacity(
        (0.035 + section.confidence.clamp(0.0, 1.0) * 0.075).toDouble(),
      ));
    }

    final energy = profile.energyCurve
        .where((point) => point.timeMs >= 0 && point.timeMs <= durationMs)
        .toList(growable: false);
    if (energy.length > 1) {
      final path = Path();
      for (var i = 0; i < energy.length; i++) {
        final point = energy[i];
        final x = xFor(point.timeMs);
        final value = point.value.isFinite
            ? point.value.clamp(0.0, 1.0).toDouble()
            : 0.5;
        final y = size.height * (0.82 - value * 0.66);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, Paint()
        ..color = accent.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round);
      final fill = Path.from(path)
        ..lineTo(xFor(energy.last.timeMs), size.height)
        ..lineTo(xFor(energy.first.timeMs), size.height)
        ..close();
      canvas.drawPath(fill, Paint()..color = accent.withOpacity(0.10));
    } else {
      canvas.drawLine(
        Offset(0, size.height * 0.58),
        Offset(size.width, size.height * 0.58),
        Paint()..color = accent.withOpacity(0.25)..strokeWidth = 1.5,
      );
    }

    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      Paint()..color = baseline.withOpacity(0.65)..strokeWidth = 1,
    );

    final beats = profile.beatGrid.beatMs;
    final stride = beats.length > 180 ? (beats.length / 180).ceil() : 1;
    for (var i = 0; i < beats.length; i += stride) {
      final beat = beats[i];
      if (beat < 0 || beat > durationMs) continue;
      final isDownbeat = profile.beatGrid.downbeatMs.contains(beat);
      final x = xFor(beat);
      canvas.drawLine(
        Offset(x, isDownbeat ? 2 : size.height * 0.68),
        Offset(x, size.height - 2),
        Paint()
          ..color = (isDownbeat ? accent : baseline).withOpacity(
            isDownbeat ? 0.75 : 0.42,
          )
          ..strokeWidth = isDownbeat ? 1.35 : 0.7,
      );
    }

    // Confidence-qualified safe windows and risk evidence are distinct from
    // the neutral beat grid so the operator can see why a cue may be unsafe.
    final safePoints = [
      ...profile.transitions.safeMixIns.where((p) => p.confidence >= 0.6),
      ...profile.transitions.safeMixOuts.where((p) => p.confidence >= 0.6),
    ];
    for (final point in safePoints) {
      if (point.timeMs < 0 || point.timeMs > durationMs) continue;
      final x = xFor(point.timeMs);
      canvas.drawCircle(Offset(x, size.height - 5), 2.4, Paint()..color = Colors.greenAccent.withOpacity(0.9));
    }
    for (final point in profile.transitions.riskyPoints) {
      if (point.confidence < 0.55 || point.timeMs < 0 || point.timeMs > durationMs) continue;
      final x = xFor(point.timeMs);
      canvas.drawLine(Offset(x, 2), Offset(x, size.height - 2), Paint()..color = Colors.redAccent.withOpacity(0.8)..strokeWidth = 1.5);
    }

    final intro = profile.transitions.bestIntroMs;
    final outro = profile.transitions.bestOutroMs;
    for (final marker in [intro, outro]) {
      if (marker == null || marker < 0 || marker > durationMs) continue;
      final x = xFor(marker);
      canvas.drawLine(
        Offset(x, 1),
        Offset(x, size.height - 1),
        Paint()
          ..color = baseline.withOpacity(0.85)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    final cueX = xFor(cueMs);
    canvas.drawLine(
      Offset(cueX, 0),
      Offset(cueX, size.height),
      Paint()
        ..color = accent
        ..strokeWidth = 2.2,
    );
    canvas.drawCircle(
      Offset(cueX, 5),
      3.2,
      Paint()..color = accent,
    );
  }

  @override
  bool shouldRepaint(covariant _DjTimelinePainter oldDelegate) =>
      oldDelegate.profile != profile ||
      oldDelegate.durationMs != durationMs ||
      oldDelegate.cueMs != cueMs ||
      oldDelegate.accent != accent ||
      oldDelegate.baseline != baseline ||
      oldDelegate.surface != surface;
}
