import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/audio_visualization_provider.dart';
import 'ask_resonate_controller.dart';

/// Persistent floating entry for Ask Resonate.
///
/// Place once in the shell [Stack] so it survives tab switches.
class AskResonateOrb extends StatefulWidget {
  const AskResonateOrb({super.key});

  @override
  State<AskResonateOrb> createState() => _AskResonateOrbState();
}

class _AskResonateOrbState extends State<AskResonateOrb> {
  final GlobalKey _orbKey = GlobalKey();

  void _capturePosition() {
    final box = _orbKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final pos = box.localToGlobal(Offset.zero) +
        Offset(box.size.width / 2, box.size.height / 2);
    context.read<AskResonateController>().updateOrbGlobalPosition(pos);
  }

  void _open() {
    _capturePosition();
    context.read<AskResonateController>().open();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<AskResonateController>();
    final viz = context.watch<AudioVisualizationProvider>();
    final lowBandEnergy =
        viz.enabled && viz.orbAudioReactive && viz.frequencies.isNotEmpty
            ? math
                .sqrt(viz.frequencies.take(6).fold<double>(0, (sum, value) => sum + value) / 6)
                .clamp(0.0, 1.0)
                .toDouble()
            : 0.0;
    final audioScale =
        1.0 + (lowBandEnergy * viz.sensitivity * 0.48).clamp(0.0, 0.32).toDouble();
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    if (ctrl.isOpen) return const SizedBox.shrink();

    final reactiveBands = viz.enabled && viz.orbAudioReactive
        ? List<double>.unmodifiable(viz.frequencies)
        : const <double>[];

    Widget orb = Material(
      key: _orbKey,
      color: Colors.transparent,
      elevation: 0,
      child: CustomPaint(
        size: const Size(82, 82),
        painter: _OrbWaveEdgePainter(
          color: scheme.secondary,
          bands: reduceMotion ? const <double>[] : reactiveBands,
          sensitivity: viz.sensitivity,
        ),
        child: SizedBox(
          width: 82,
          height: 82,
          child: Center(
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.secondary.withValues(alpha: 0.95),
                    scheme.primary.withValues(alpha: 0.90),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 1,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: CustomPaint(
                  size: const Size(32, 32),
                  painter: _OrbSpectrumPainter(
                    color: Colors.white,
                    bands: reactiveBands.take(7).toList(growable: false),
                    sensitivity: reduceMotion ? 0.0 : viz.sensitivity,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    orb = Transform.scale(scale: reduceMotion ? 1.0 : audioScale, child: orb);

    return Positioned(
      right: 18,
      bottom: 16,
      child: Semantics(
        button: true,
        label: 'Ask Resonate',
        hint: 'Opens the Resonate companion.',
        onTap: _open,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: orb,
        ),
      ),
    );
  }
}


/// Audio-reactive perimeter. Low-frequency FFT bins are distributed around
/// the circumference and interpolated into a smooth, asymmetric wave contour.
class _OrbWaveEdgePainter extends CustomPainter {
  const _OrbWaveEdgePainter({
    required this.color,
    required this.bands,
    required this.sensitivity,
  });

  final Color color;
  final List<double> bands;
  final double sensitivity;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const baseRadius = 30.0;
    final usableBands = bands.take(12).toList(growable: false);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.88)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    const samples = 144;
    for (var i = 0; i <= samples; i++) {
      final angle = (i / samples) * math.pi * 2 - math.pi / 2;
      final bandPosition = (i / samples) * usableBands.length;
      final lower = bandPosition.floor();
      final fraction = bandPosition - lower;
      final a = usableBands.isEmpty
          ? 0.0
          : usableBands[lower % usableBands.length];
      final b = usableBands.isEmpty
          ? 0.0
          : usableBands[(lower + 1) % usableBands.length];
      final first = a.isFinite ? a.clamp(0.0, 1.0).toDouble() : 0.0;
      final second = b.isFinite ? b.clamp(0.0, 1.0).toDouble() : 0.0;
      final energy = first + (second - first) * fraction;
      // Keep the contour lively and bass-forward, with enough travel to read
      // as waves rather than a uniformly expanding halo.
      final displacement = math.sqrt(energy) *
          (2.0 + sensitivity.clamp(0.1, 1.0) * 7.0);
      final radius = baseRadius + displacement;
      final point = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbWaveEdgePainter oldDelegate) {
    if (oldDelegate.color != color ||
        oldDelegate.sensitivity != sensitivity ||
        oldDelegate.bands.length != bands.length) {
      return true;
    }
    for (var i = 0; i < bands.length; i++) {
      if (oldDelegate.bands[i] != bands[i]) return true;
    }
    return false;
  }
}

/// Compact FFT mark: its seven strokes are driven by the same measured bands
/// as the main visualizer. No independent animation or idle pulse is used.
class _OrbSpectrumPainter extends CustomPainter {
  const _OrbSpectrumPainter({
    required this.color,
    required this.bands,
    required this.sensitivity,
  });

  final Color color;
  final List<double> bands;
  final double sensitivity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.96)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.8;
    const count = 7;
    final slot = size.width / (count + 1);
    for (var i = 0; i < count; i++) {
      final raw = i < bands.length && bands[i].isFinite
          ? bands[i].clamp(0.0, 1.0)
          : 0.0;
      final energy = raw <= 0.0
          ? 0.0
          : math.sqrt(raw) * (0.45 + sensitivity * 1.1);
      final height = (3.0 + energy.clamp(0.0, 1.0) * size.height * 0.62)
          .clamp(3.0, size.height * 0.82).toDouble();
      final x = slot * (i + 1);
      canvas.drawLine(
        Offset(x, (size.height + height) / 2),
        Offset(x, (size.height - height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OrbSpectrumPainter oldDelegate) {
    if (oldDelegate.color != color ||
        oldDelegate.sensitivity != sensitivity ||
        oldDelegate.bands.length != bands.length) {
      return true;
    }
    for (var i = 0; i < bands.length; i++) {
      if (oldDelegate.bands[i] != bands[i]) return true;
    }
    return false;
  }
}
