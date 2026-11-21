import 'dart:math' as math;

import 'crossfade_frame_progress.dart';

/// Deterministic timing policy and fade-curve math for crossfade execution.
///
/// This class deliberately does not own audio players or execute handoffs;
/// MusicProvider remains responsible for validating ownership and performing
/// the transition. Keeping timing calculations pure makes them testable without
/// invoking native audio engines.
class CrossfadeOrchestrator {
  const CrossfadeOrchestrator._();

  /// Computes the existing eased, equal-power A/B gains for one fade frame.
  /// Keeps the curve deterministic and independent of native audio players.
  static CrossfadeGains gains({
    required int elapsedMs,
    required int totalMs,
    required String fadeType,
  }) {
    final linear = CrossfadeFrameProgress.calculate(
      elapsedMs: elapsedMs,
      totalMs: totalMs,
    ).fraction;
    final eased = switch (fadeType) {
      'ease_in' => linear * linear,
      'ease_out' => 1.0 - ((1.0 - linear) * (1.0 - linear)),
      'ease_in_out' => linear < 0.5
          ? 2.0 * linear * linear
          : 1.0 - ((-2.0 * linear + 2.0) * (-2.0 * linear + 2.0)) / 2.0,
      _ => linear,
    };
    final outT = math.pow(eased, 1.28).toDouble().clamp(0.0, 1.0);
    final inT = math.pow(eased, 0.92).toDouble().clamp(0.0, 1.0);
    return CrossfadeGains(
      outgoing: math.cos(outT * (math.pi / 2.0)),
      incoming: math.sin(inT * (math.pi / 2.0)),
    );
  }

  /// Prepares the standby deck early enough to reach analyzed DJ mix points.
  static bool shouldPreloadForApprovedCue({
    required int positionMs,
    required int cueMs,
    int preloadLeadMs = 10000,
  }) {
    if (positionMs < 0 || cueMs < 0 || preloadLeadMs < 0) return false;
    final preloadAtMs = math.max(0, cueMs - preloadLeadMs);
    return positionMs >= preloadAtMs && positionMs < cueMs;
  }

  /// Starts the approved transition at its reviewed outgoing cue position.
  static bool shouldStartAtApprovedCue({
    required int positionMs,
    required int cueMs,
  }) =>
      positionMs >= 0 && cueMs >= 0 && positionMs >= cueMs;

  static CrossfadeTiming timing({
    required int configuredDurationMs,
    required bool djActive,
  }) {
    final effectiveFadeMs = djActive
        ? configuredDurationMs.clamp(500, 6500).toInt()
        : configuredDurationMs;
    final startMarginMs = (1200 + (effectiveFadeMs ~/ 10))
        .clamp(1500, 3000)
        .toInt();

    final preloadWindowMs = djActive
        ? math.max(35000, configuredDurationMs + 10000)
            .clamp(10000, 45000)
            .toInt()
        : (configuredDurationMs + 10000).clamp(10000, 28000).toInt();

    return CrossfadeTiming(
      effectiveFadeMs: effectiveFadeMs,
      preloadWindowMs: preloadWindowMs,
      fadeArmWindowMs: configuredDurationMs + 2000,
      triggerWindowMs: (effectiveFadeMs + startMarginMs).clamp(2000, 16000).toInt(),
    );
  }
}

class CrossfadeTiming {
  const CrossfadeTiming({
    required this.effectiveFadeMs,
    required this.preloadWindowMs,
    required this.fadeArmWindowMs,
    required this.triggerWindowMs,
  });

  final int effectiveFadeMs;
  final int preloadWindowMs;
  final int fadeArmWindowMs;
  final int triggerWindowMs;
}

/// Per-frame gains for the outgoing and incoming engines.
class CrossfadeGains {
  const CrossfadeGains({required this.outgoing, required this.incoming});

  final double outgoing;
  final double incoming;
}
