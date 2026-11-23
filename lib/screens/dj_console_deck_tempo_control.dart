import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import 'dj_console_tempo_policy.dart';

/// One physical deck's bounded tempo control. It translates physical A/B
/// identity into the current native active/standby roles on every build and
/// every commit; it never caches a logical role across promotion.
class DjConsoleDeckTempoControl extends StatefulWidget {
  const DjConsoleDeckTempoControl({
    super.key,
    required this.physicalDeckId,
    required this.compact,
  });

  final String physicalDeckId;
  final bool compact;

  @override
  State<DjConsoleDeckTempoControl> createState() =>
      _DjConsoleDeckTempoControlState();
}

class _DjConsoleDeckTempoControlState
    extends State<DjConsoleDeckTempoControl> {
  double? _previewPercent;
  bool? _keyLockEnabled;
  bool _busy = false;

  Future<void> _apply(
    BuildContext context, {
    required MusicProvider music,
    required double percent,
    required bool keyLock,
  }) async {
    if (_busy) return;
    final state = music.media3ShadowState;
    if (state == null ||
        (state.activeDeckId != 'A' && state.activeDeckId != 'B')) {
      return;
    }
    final isActive = widget.physicalDeckId == state.activeDeckId;
    final activeSpeed = state.activeDeckSpeed;
    final activePitch = state.activeDeckPitch;
    final standbySpeed = state.standbyDeckSpeed;
    final standbyPitch = state.standbyDeckPitch;
    if (activeSpeed == null ||
        activePitch == null ||
        standbySpeed == null ||
        standbyPitch == null) {
      return;
    }
    final parameters = DjConsoleTempoPolicy.parametersFor(
      percent: percent,
      keyLockEnabled: keyLock,
    );
    if (parameters == null) return;

    setState(() => _busy = true);
    try {
      await music.setPreparedManualDjDeckParameters(
        activeSpeed: isActive ? parameters.speed : activeSpeed,
        activePitch: isActive ? parameters.pitch : activePitch,
        standbySpeed: isActive ? standbySpeed : parameters.speed,
        standbyPitch: isActive ? standbyPitch : parameters.pitch,
      );
      if (!mounted) return;
      setState(() {
        _previewPercent = null;
        _keyLockEnabled = keyLock;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tempo update was not applied: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.physicalDeckId == 'A'
        ? const Color(0xFF55D6BE)
        : const Color(0xFF8EA7FF);
    return Consumer<MusicProvider>(
      builder: (context, music, _) {
        final state = music.media3ShadowState;
        final activeDeckId = state?.activeDeckId;
        final roleKnown = activeDeckId == 'A' || activeDeckId == 'B';
        final isActive = roleKnown && activeDeckId == widget.physicalDeckId;
        final speed = isActive
            ? state?.activeDeckSpeed
            : state?.standbyDeckSpeed;
        final pitch = isActive
            ? state?.activeDeckPitch
            : state?.standbyDeckPitch;
        final telemetryValid = speed != null &&
            pitch != null &&
            speed.isFinite &&
            pitch.isFinite &&
            speed >= 0.5 &&
            speed <= 2.0 &&
            pitch >= 0.5 &&
            pitch <= 2.0;
        final percent = telemetryValid
            ? (((speed! - 1.0) * 100.0)
                .clamp(-6.0, 6.0).toDouble())
            : 0.0;
        final keyLock = _keyLockEnabled ??
            (telemetryValid
                ? (pitch! - 1.0).abs() <= 0.001
                : true);
        final shownPercent = (_previewPercent ?? percent)
            .clamp(-6.0, 6.0).toDouble();
        final canWrite = !_busy &&
            telemetryValid &&
            roleKnown &&
            music.hasPreparedManualDjDeck &&
            music.manualDjPreparedDeck != null &&
            music.media3ProviderSessionActive &&
            music.isPlaying &&
            !music.transitionInProgress &&
            state?.crossfadeStatus == 'ready';
        final label = isActive ? 'ON AIR' : 'STANDBY';
        final textStyle = theme.textTheme.labelSmall?.copyWith(
          color: Colors.white70,
          fontSize: widget.compact ? 8 : 9,
          letterSpacing: .7,
        );

        return Container(
          margin: const EdgeInsets.only(top: 7),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 5 : 9,
            vertical: widget.compact ? 3 : 6,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF0A121B),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withValues(alpha: .24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('TEMPO', style: textStyle?.copyWith(
                    color: accent, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  Text(
                    telemetryValid
                        ? '${shownPercent >= 0 ? '+' : ''}${shownPercent.toStringAsFixed(1)}%'
                        : '—',
                    style: textStyle?.copyWith(
                      fontFeatures: const [],
                      fontWeight: FontWeight.w900,
                      color: telemetryValid ? Colors.white : Colors.white38,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(roleKnown ? label : 'UNMAPPED',
                    style: textStyle?.copyWith(color: Colors.white38)),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: widget.compact ? 5 : 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  min: DjConsoleTempoPolicy.minPercent,
                  max: DjConsoleTempoPolicy.maxPercent,
                  divisions: 120,
                  value: shownPercent,
                  onChanged: canWrite
                      ? (value) => setState(() => _previewPercent = value)
                      : null,
                  onChangeEnd: canWrite
                      ? (value) => _apply(
                            context,
                            music: music,
                            percent: value,
                            keyLock: keyLock,
                          )
                      : null,
                ),
              ),
              Row(
                children: [
                  Text('KEY LOCK', style: textStyle),
                  const Spacer(),
                  Transform.scale(
                    scale: widget.compact ? .72 : .82,
                    child: Switch.adaptive(
                      value: keyLock,
                      onChanged: canWrite
                          ? (value) => _apply(
                                context,
                                music: music,
                                percent: shownPercent,
                                keyLock: value,
                              )
                          : null,
                    ),
                  ),
                ],
              ),
              if (!canWrite)
                Text(
                  !roleKnown
                      ? 'DECK ID UNAVAILABLE'
                      : !telemetryValid
                          ? 'WAITING FOR NATIVE READBACK'
                          : 'PREPARE DECK B TO UNLOCK',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle?.copyWith(
                    color: Colors.white38,
                    fontSize: widget.compact ? 7 : 8,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
