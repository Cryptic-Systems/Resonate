import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../dj_engine/core/dj_types.dart';
import '../dj_engine/intelligence/dj_transition_brain.dart';
import '../models/song.dart';
import '../providers/dj_mode_provider.dart';
import '../providers/library_provider.dart';
import '../services/dj_transition_preset_store.dart';
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
  int _outCue = 0, _inCue = 0, _fadeMs = 6500;
  bool _busy = false, _saving = false;
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
    final song = await _choose(outgoing ? 'Choose outgoing track' : 'Choose incoming track',
      excludeId: outgoing ? _incoming?.id : _outgoing?.id);
    if (song == null || !mounted) return;
    setState(() {
      if (outgoing) { _outgoing = song; _profileA = null; }
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
    setState(() { _saving = true; _error = null; });
    try {
      await DjTransitionPresetStore.save(DjTransitionPreset(
        outgoingSongId: a.id,
        incomingSongId: b.id,
        outgoingCueMs: _outCue,
        incomingCueMs: _inCue,
        durationMs: _fadeMs,
        preferredKind: _preferredKind,
      ));
      if (!mounted) return;
      setState(() {
        _hasSavedPreset = true;
        _status = 'Pair preset saved. DJ playback will prefer these cues and strategy when safe.';
      });
      _rebuild();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save cue points: ' + e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showPreview() {
    final candidate = _recommended;
    if (candidate == null) return;
    final outDuration = _duration(_outgoing, _profileA);
    final inDuration = _duration(_incoming, _profileB);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Transition preview'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_kind(candidate.kind), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Outgoing cue ' + _clock(candidate.outgoingStartMs) + ' · Incoming cue ' + _clock(candidate.incomingStartMs)),
          const SizedBox(height: 16),
          _previewLane('OUTGOING', candidate.outgoingStartMs, outDuration, Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          _previewLane('INCOMING', candidate.incomingStartMs, inDuration, Theme.of(context).colorScheme.tertiary),
          const SizedBox(height: 14),
          Text('Blend ' + (candidate.durationMs / 1000).toStringAsFixed(1) + ' s · Score ' +
            (candidate.score * 100).round().toString() + '% · Confidence ' +
            (candidate.confidence * 100).round().toString() + '%'),
          if (candidate.risks.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Risk checks: ' + candidate.risks.map((r) => r.name).join(', '),
              style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(height: 10),
          Text('Visual timing preview only. It does not interrupt or start playback.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  Widget _previewLane(String label, int cueMs, int durationMs, Color color) {
    final fraction = durationMs > 0 ? (cueMs / durationMs).clamp(0.0, 1.0) : 0.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label + ' · ' + _clock(cueMs), style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 5),
      LayoutBuilder(builder: (context, constraints) {
        final left = constraints.maxWidth * fraction;
        return SizedBox(height: 12, child: Stack(children: [
          Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ))),
          Positioned(left: 0, top: 0, bottom: 0, width: left,
            child: DecoratedBox(decoration: BoxDecoration(color: color.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8)))),
          Positioned(left: (left - 1).clamp(0.0, constraints.maxWidth - 2), top: 0, bottom: 0,
            child: Container(width: 2, color: color)),
        ]));
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final da = _duration(_outgoing, _profileA), db = _duration(_incoming, _profileB);
    return ResonateGlassScaffold(title: const Text('DJ Transition Studio'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Text('Shape how two tracks meet',
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Compare beat, phrase, energy, harmonic and structure compatibility. Edit pair-specific cues without changing either track’s global analysis.',
          style: theme.textTheme.bodyMedium),
        const SizedBox(height: 18),
        _track('OUTGOING', 'The track being mixed out', _outgoing, () => _pick(true)),
        const SizedBox(height: 10),
        Center(child: Icon(Icons.south_rounded, color: theme.colorScheme.primary)),
        const SizedBox(height: 10),
        _track('INCOMING', 'The track being mixed in', _incoming, () => _pick(false)),
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
          const SizedBox(height: 24), _heading('Mix points'),
          _cue('Mix-Out', 'Outgoing · ' + _clock(_outCue), _outCue, da, (v) { setState(() => _outCue = v); _rebuild(); }),
          _cue('Mix-In', 'Incoming · ' + _clock(_inCue), _inCue, db, (v) { setState(() => _inCue = v); _rebuild(); }),
          const SizedBox(height: 8), _heading('Blend duration'),
          Text((_fadeMs / 1000).toStringAsFixed(1) + ' seconds'),
          Slider(value: _fadeMs.toDouble(), min: 2000, max: 15000, divisions: 26,
            label: (_fadeMs / 1000).toStringAsFixed(1) + ' s',
            onChanged: (v) { setState(() => _fadeMs = v.round()); _rebuild(); }),
          const SizedBox(height: 12), _heading('Transition analysis'),
          if (_recommended != null) _recommendation(_recommended!),
          const SizedBox(height: 10),
          for (final candidate in _candidates) _candidate(candidate),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _recommended == null ? null : _showPreview,
              icon: const Icon(Icons.visibility_rounded),
              label: const Text('Preview timing'),
            )),
            const SizedBox(width: 10),
            Expanded(child: FilledButton.icon(onPressed: _saving ? null : _save,
              icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_rounded),
              label: Text(_saving ? 'Saving…' : 'Save pair preset'))),
          ]),
          if (_hasSavedPreset) Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving ? null : () async {
                await DjTransitionPresetStore.delete(a.id, b.id);
                if (!mounted) return;
                setState(() { _hasSavedPreset = false; _preferredKind = null; _status = 'Pair preset removed.'; });
                _rebuild();
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Remove pair preset'),
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
      if (c.risks.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text('Risks: ' + c.risks.map((r) => r.name).join(', '),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error))),
    ]));

  Widget _metric(String label, double value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text((value * 100).round().toString() + '%', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
    Text(label, style: Theme.of(context).textTheme.bodySmall),
  ]);

  Widget _candidate(DjTransitionCandidate c) => ResonateGlassCard(
    margin: const EdgeInsets.only(bottom: 8), padding: EdgeInsets.zero,
    child: ListTile(
      onTap: () {
        setState(() {
          _preferredKind = c.kind;
          _outCue = c.outgoingStartMs;
          _inCue = c.incomingStartMs;
          _fadeMs = c.durationMs.clamp(2000, 15000);
        });
        _rebuild();
      },
      leading: Icon(c.kind == _recommended?.kind ? Icons.check_circle_rounded : Icons.graphic_eq_rounded,
        color: c.kind == _recommended?.kind ? Theme.of(context).colorScheme.primary : null),
      title: Text(_kind(c.kind)),
      subtitle: Text('Score ' + (c.score * 100).round().toString() + '% · Confidence ' +
        (c.confidence * 100).round().toString() + '% · ' + _clock(c.outgoingStartMs) + ' → ' + _clock(c.incomingStartMs)),
      trailing: Text((c.durationMs / 1000).toStringAsFixed(1) + 's')));

  String _kind(DjTransitionKind kind) => switch (kind) {
    DjTransitionKind.outroIntro => 'Outro → Intro',
    DjTransitionKind.phraseBlend => 'Phrase blend',
    DjTransitionKind.breakdownDrop => 'Breakdown → Drop',
    DjTransitionKind.beatBlend => 'Beat blend',
    DjTransitionKind.energyBridge => 'Energy bridge',
    DjTransitionKind.safeCrossfade => 'Safe crossfade',
  };
}
