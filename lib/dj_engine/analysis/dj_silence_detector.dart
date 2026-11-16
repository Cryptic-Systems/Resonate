import 'dart:math' as math;

/// A short RMS measurement from decoded PCM.
///
/// [rms] is linear amplitude normalized to 0..1 (not a dB value). Samples
/// should be evenly spaced and represent roughly 50–250 ms of audio.
class DjRmsSample {
  const DjRmsSample({
    required this.timeMs,
    required this.rms,
    this.windowMs = 100,
  });

  final int timeMs;
  final double rms;
  final int windowMs;
}

/// A sustained near-digital-silence region. This is evidence for a later
/// transition planner; it does not itself start, stop, or seek playback.
class DjSilenceSegment {
  const DjSilenceSegment({
    required this.startMs,
    required this.endMs,
    required this.minimumDbfs,
    required this.confidence,
  });

  final int startMs;
  final int endMs;
  final double minimumDbfs;
  final double confidence;

  int get durationMs => math.max(0, endMs - startMs);
}

/// Conservative silence detector for musical PCM.
///
/// This deliberately detects near-silence, not merely a quiet musical
/// breakdown. It uses a track-relative threshold with fixed dBFS bounds,
/// separate enter/exit thresholds (hysteresis), a minimum hold duration, and
/// by default only examines the final 35% of a track. Missing/weak RMS evidence
/// produces no candidate rather than an aggressive guess.
class DjSilenceDetector {
  const DjSilenceDetector({
    this.minimumDurationMs = 2000,
    this.monitorFromFraction = 0.65,
    this.minimumReferenceDbfs = -42.0,
  });

  final int minimumDurationMs;
  final double monitorFromFraction;
  final double minimumReferenceDbfs;

  List<DjSilenceSegment> detect(
    List<DjRmsSample> samples, {
    required int durationMs,
  }) {
    if (durationMs <= 0 || samples.isEmpty || minimumDurationMs <= 0) {
      return const [];
    }

    final valid = samples
        .where((sample) =>
            sample.timeMs >= 0 &&
            sample.timeMs < durationMs &&
            sample.windowMs > 0 &&
            sample.rms.isFinite &&
            sample.rms >= 0)
        .toList()
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    if (valid.length < 4) return const [];

    // Estimate the programme level from the upper quartile. Excluding the
    // quietest frames prevents a long silent tail from lowering its own gate.
    final levels = valid
        .map((sample) => _toDbfs(sample.rms))
        .where((db) => db > -72.0)
        .toList()
      ..sort();
    if (levels.length < 4) return const [];
    final referenceDbfs = levels[(levels.length * 0.75).floor()
        .clamp(0, levels.length - 1)
        .toInt()];
    if (referenceDbfs < minimumReferenceDbfs) return const [];

    // Keep the gate conservative across differently mastered material.
    final enterDbfs = (referenceDbfs - 32.0).clamp(-60.0, -48.0).toDouble();
    final exitDbfs = math.min(-38.0, enterDbfs + 8.0);
    final monitorFromMs =
        (durationMs * monitorFromFraction.clamp(0.0, 1.0)).round();

    final candidates = <DjSilenceSegment>[];
    int? candidateStart;
    var minimumSeen = 0.0;

    void closeCandidate(int endMs) {
      if (candidateStart == null) return;
      final start = candidateStart!;
      final end = math.max(start, endMs).toInt();
      final heldMs = end - start;
      if (heldMs >= minimumDurationMs) {
        final depth = (enterDbfs - minimumSeen).clamp(0.0, 24.0);
        final durationScore =
            (heldMs / (minimumDurationMs * 2.0)).clamp(0.0, 1.0);
        final depthScore = (depth / 12.0).clamp(0.0, 1.0);
        final confidence =
            (0.55 + durationScore * 0.25 + depthScore * 0.20)
                .clamp(0.0, 1.0)
                .toDouble();
        candidates.add(DjSilenceSegment(
          startMs: start,
          endMs: end,
          minimumDbfs: minimumSeen,
          confidence: confidence,
        ));
      }
      candidateStart = null;
    }

    for (final sample in valid) {
      final dbfs = _toDbfs(sample.rms);
      if (sample.timeMs < monitorFromMs) continue;

      if (candidateStart == null) {
        if (dbfs <= enterDbfs) {
          candidateStart = sample.timeMs;
          minimumSeen = dbfs;
        }
      } else if (dbfs <= exitDbfs) {
        minimumSeen = math.min(minimumSeen, dbfs);
      } else {
        closeCandidate(sample.timeMs);
      }
    }
    if (candidateStart != null) {
      final last = valid.last;
      closeCandidate(math.min(durationMs, last.timeMs + last.windowMs));
    }

    return candidates;
  }

  static double _toDbfs(double rms) {
    if (rms <= 0) return -120.0;
    return 20.0 * math.log(rms) / math.ln10;
  }
}
