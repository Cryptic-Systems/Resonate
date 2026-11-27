import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import 'dj_console_manual_controls_policy.dart';

/// Operator-facing Deck B controls backed by MusicProvider's Media3 handoff
/// contract. This widget never creates a player or writes deck gain directly.
class DjConsoleManualControls extends StatefulWidget {
  const DjConsoleManualControls({super.key, required this.compact});

  final bool compact;

  @override
  State<DjConsoleManualControls> createState() => _DjConsoleManualControlsState();
}

class _DjConsoleManualControlsState extends State<DjConsoleManualControls> {
  bool _busy = false;
  double? _cuePreviewMs;
  String? _cuePreviewSongId;
  int? _cuePreviewQueueIndex;
  int _crossfadeSeconds = 4;

  Future<void> _run(
    BuildContext context,
    Future<void> Function(MusicProvider music) action,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(context.read<MusicProvider>());
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('DJ Console: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseAndPrepare(BuildContext context, MusicProvider music) async {
    final candidates = DjConsoleManualControlsPolicy.incomingCandidates(
      music.queue,
      currentQueueIndex: music.queueIndex,
    );
    if (candidates.isEmpty) return;

    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Prepare incoming deck'),
        content: SizedBox(
          width: 420,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, row) {
              final index = candidates[row];
              final song = music.queue[index];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.album_outlined),
                title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(dialogContext).pop(index),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await _run(context, (provider) async {
      await provider.prepareManualDjDeck(incomingQueueIndex: selected);
      if (!mounted) return;
      setState(() {
        _cuePreviewMs = null;
        _cuePreviewSongId = null;
        _cuePreviewQueueIndex = null;
      });
    });
  }

  Future<void> _setCue(BuildContext context, Duration position) async {
    final prepared = context.read<MusicProvider>().manualDjPreparedDeck;
    if (prepared == null) return;
    await _run(context, (provider) async {
      await provider.cuePreparedManualDjDeck(position);
      if (mounted) {
        setState(() {
          _cuePreviewMs = null;
          _cuePreviewSongId = null;
          _cuePreviewQueueIndex = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    return Consumer<MusicProvider>(
      builder: (context, music, _) {
        final prepared = music.manualDjPreparedDeck;
        final durationMs = prepared?.incomingSong.duration.inMilliseconds ?? 0;
        final cueMs = prepared?.cuePosition.inMilliseconds ?? 0;
        final preview = prepared != null &&
                DjConsoleManualControlsPolicy.matchesCuePreview(
                  previewSongId: _cuePreviewSongId,
                  previewQueueIndex: _cuePreviewQueueIndex,
                  preparedSongId: prepared.incomingSong.id,
                  preparedQueueIndex: prepared.incomingQueueIndex,
                )
            ? _cuePreviewMs
            : null;
        final sliderValue = (preview ?? cueMs.toDouble())
            .clamp(0.0, durationMs > 0 ? durationMs.toDouble() : 1.0).toDouble();
        final canPrepare = music.media3ProviderSessionActive &&
            music.isPlaying &&
            DjConsoleManualControlsPolicy.incomingCandidates(
              music.queue,
              currentQueueIndex: music.queueIndex,
            ).isNotEmpty &&
            prepared == null &&
            !_busy;
        final canPerform = prepared != null &&
            music.hasPreparedManualDjDeck && music.isPlaying && !_busy;
        final textStyle = theme.textTheme.labelSmall?.copyWith(
          color: Colors.white70, fontSize: compact ? 8 : 10,
        );

        return Container(
          padding: EdgeInsets.all(compact ? 7 : 11),
          decoration: BoxDecoration(
            color: const Color(0xFF151D28),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: .10)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('DECK B', textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  letterSpacing: compact ? 1 : 2, fontWeight: FontWeight.w900)),
              const SizedBox(height: 5),
              Text(prepared == null ? 'STANDBY CONTROL' : 'PREPARED · MUTED',
                textAlign: TextAlign.center,
                style: textStyle?.copyWith(
                  color: prepared == null ? Colors.white54 : const Color(0xFF55D6BE),
                  fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              if (prepared == null) ...[
                Icon(Icons.album_outlined, size: compact ? 24 : 30, color: Colors.white54),
                const SizedBox(height: 8),
                Text(
                  music.media3ProviderSessionActive
                      ? music.isPlaying ? 'Choose an incoming track' : 'Resume playback to prepare'
                      : 'Start Media3 playback first',
                  textAlign: TextAlign.center, style: textStyle),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: canPrepare ? () => _chooseAndPrepare(context, music) : null,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 4 : 10, vertical: compact ? 8 : 10)),
                  child: Text(_busy ? 'WAIT' : compact ? 'LOAD' : 'PREPARE DECK B',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: compact ? 8 : 10)),
                ),
              ] else ...[
                Text(prepared.incomingSong.title,
                  maxLines: compact ? 2 : 3, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800, fontSize: compact ? 9 : 11)),
                if (!compact) ...[
                  const SizedBox(height: 2),
                  Text(prepared.incomingSong.artist, maxLines: 1,
                    overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                    style: textStyle),
                ],
                const SizedBox(height: 8),
                Text('CUE POSITION', textAlign: TextAlign.center, style: textStyle),
                Slider(
                  min: 0,
                  max: durationMs > 0 ? durationMs.toDouble() : 1,
                  value: sliderValue,
                  onChanged: durationMs > 0 && !_busy
                      ? (value) => setState(() {
                            _cuePreviewSongId = prepared.incomingSong.id;
                            _cuePreviewQueueIndex = prepared.incomingQueueIndex;
                            _cuePreviewMs = value;
                          })
                      : null,
                  onChangeEnd: durationMs > 0 && !_busy
                      ? (value) => _setCue(context, Duration(milliseconds: value.round()))
                      : null,
                ),
                Text(
                  '${_clock(Duration(milliseconds: sliderValue.round()))} / ${_clock(prepared.incomingSong.duration)}',
                  textAlign: TextAlign.center, style: textStyle),
                const SizedBox(height: 6),
                if (!compact)
                  DropdownButtonFormField<int>(
                    value: _crossfadeSeconds,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Fade duration',
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                    items: const [2, 4, 6, 8, 10, 12, 15]
                        .map((seconds) => DropdownMenuItem(
                              value: seconds, child: Text('$seconds seconds')))
                        .toList(growable: false),
                    onChanged: _busy ? null : (value) {
                      if (value != null) setState(() => _crossfadeSeconds = value);
                    },
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: canPerform
                      ? () => _run(context, (provider) =>
                          provider.crossfadePreparedManualDjDeck(
                            duration: Duration(seconds: _crossfadeSeconds)))
                      : null,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                  label: Text(_busy ? 'WORKING' : compact ? 'MIX' : 'PERFORM HANDOFF',
                    style: TextStyle(fontSize: compact ? 8 : 10)),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _run(context,
                    (provider) => provider.cancelPreparedManualDjDeck()),
                  child: Text('CANCEL DECK B',
                    style: TextStyle(fontSize: compact ? 8 : 9)),
                ),
              ],
              const SizedBox(height: 6),
              Text('Media3 equal-power transition', textAlign: TextAlign.center,
                style: textStyle?.copyWith(
                  color: Colors.white38, fontSize: compact ? 7 : 8)),
            ],
          ),
        );
      },
    );
  }

  String _clock(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 1 << 30);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
