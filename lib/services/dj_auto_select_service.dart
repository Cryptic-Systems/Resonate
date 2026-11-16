import 'dart:math' as math;

import '../models/dj_analysis.dart';
import '../models/song.dart';
import 'dj_analysis_service.dart';

/// Produces a queue order for an explicitly requested DJ-arranged shuffle.
///
/// This is deliberately separate from playback and from DJ transition
/// execution. It only orders the selected scope; MusicProvider remains the
/// sole owner of playback and queue state.
class DjAutoSelectResult {
  const DjAutoSelectResult({
    required this.songs,
    required this.usedDjArrangement,
    required this.analysisCoverage,
    this.reason,
  });

  final List<Song> songs;
  final bool usedDjArrangement;
  final double analysisCoverage;
  final String? reason;
}

class DjAutoSelectService {
  DjAutoSelectService({DjAnalysisService? analysis})
      : _analysis = analysis ?? DjAnalysisService();

  final DjAnalysisService _analysis;

  Future<DjAutoSelectResult> arrange(
    List<Song> songs, {
    math.Random? random,
  }) async {
    final analyses = <String, DjAnalysis>{};
    for (final song in songs) {
      final analysis = await _analysis.getAnalysis(song.id);
      if (analysis != null && !analysis.isStale) {
        analyses[song.id] = analysis;
      }
    }
    return arrangeWithAnalysis(songs, analyses, random: random);
  }

  /// Pure ordering core, exposed so scoring and confidence gates are testable.
  DjAutoSelectResult arrangeWithAnalysis(
    List<Song> songs,
    Map<String, DjAnalysis> analyses, {
    math.Random? random,
  }) {
    final rng = random ?? math.Random();
    final input = List<Song>.of(songs);
    if (input.length < 2) {
      return DjAutoSelectResult(
        songs: input,
        usedDjArrangement: false,
        analysisCoverage: input.isEmpty ? 0 : 1,
        reason: 'not_enough_tracks',
      );
    }

    final usable = input.where((song) {
      final a = analyses[song.id];
      return a != null && !a.isStale && _trackConfidence(a) >= 0.25;
    }).length;
    final coverage = usable / input.length;
    final minimumUsable = math.min(3, input.length);
    if (usable < minimumUsable || coverage < 0.50) {
      input.shuffle(rng);
      return DjAutoSelectResult(
        songs: input,
        usedDjArrangement: false,
        analysisCoverage: coverage,
        reason: 'insufficient_analysis_confidence',
      );
    }

    final remaining = List<Song>.of(input)..shuffle(rng);
    final ordered = <Song>[remaining.removeAt(0)];
    while (remaining.isNotEmpty) {
      final previous = ordered.last;
      Song? best;
      var bestScore = double.negativeInfinity;
      for (final candidate in remaining) {
        final musical = _pairScore(
          analyses[previous.id],
          analyses[candidate.id],
        );
        final sameArtist = _sameMetadata(previous.artist, candidate.artist);
        final sameAlbum = _sameMetadata(previous.album, candidate.album);
        final diversity = (sameArtist ? -0.10 : 0.035) +
            (sameAlbum ? -0.035 : 0.015);
        // Tiny random tie-break prevents the same library from always
        // producing an identical order when musical scores are equivalent.
        final score = musical + diversity + rng.nextDouble() * 0.025;
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      ordered.add(best!);
      remaining.remove(best);
    }

    return DjAutoSelectResult(
      songs: ordered,
      usedDjArrangement: true,
      analysisCoverage: coverage,
    );
  }

  static double _trackConfidence(DjAnalysis a) {
    var availableWeight = 0.0;
    var confidence = 0.0;
    if (a.hasUsableBpm) {
      availableWeight += 0.55;
      confidence += 0.55 * a.bpmConfidence.clamp(0.0, 1.0);
    }
    if (a.hasUsableKey) {
      availableWeight += 0.25;
      confidence += 0.25 * 0.70;
    }
    if (a.hasUsableEnergy) {
      availableWeight += 0.20;
      confidence += 0.20 * 0.65;
    }
    return availableWeight == 0 ? 0 : confidence / availableWeight;
  }

  static double _pairScore(DjAnalysis? a, DjAnalysis? b) {
    if (a == null || b == null || a.isStale || b.isStale) return 0.5;
    var weighted = 0.0;
    var weight = 0.0;

    if (a.hasUsableBpm && b.hasUsableBpm) {
      final confidence = math.min(a.bpmConfidence, b.bpmConfidence)
          .clamp(0.0, 1.0);
      final tempo = _tempoCompatibility(a.bpm!, b.bpm!);
      final w = 0.55 * confidence;
      weighted += tempo * w;
      weight += w;
    }

    if (a.hasUsableKey && b.hasUsableKey) {
      final harmonic = _harmonicCompatibility(
        a.keyRoot!,
        a.keyMode!,
        b.keyRoot!,
        b.keyMode!,
      );
      weighted += harmonic * 0.25;
      weight += 0.25;
    }

    if (a.hasUsableEnergy && b.hasUsableEnergy) {
      final energy = 1.0 - (a.energy! - b.energy!).abs().clamp(0.0, 1.0);
      weighted += energy * 0.20;
      weight += 0.20;
    }

    return weight < 0.18 ? 0.5 : weighted / weight;
  }

  static double _tempoCompatibility(double a, double b) {
    final ratios = <double>[b / a, (b * 2) / a, b / (a * 2)];
    final difference = ratios
        .map((ratio) => (ratio - 1.0).abs())
        .reduce(math.min);
    return (1.0 - difference / 0.18).clamp(0.0, 1.0);
  }

  static double _harmonicCompatibility(
    int rootA,
    String modeA,
    int rootB,
    String modeB,
  ) {
    final semitones = (rootA - rootB).abs() % 12;
    final circleDistance = math.min(
      (semitones * 7) % 12,
      12 - ((semitones * 7) % 12),
    );
    if (semitones == 0 && modeA == modeB) return 1.0;
    if (semitones == 0) return 0.88;
    if (semitones == 7 || semitones == 5) return 0.90;
    if (semitones == 3 || semitones == 9) return 0.82;
    return (0.72 - circleDistance * 0.055).clamp(0.30, 0.72);
  }

  static bool _sameMetadata(String a, String b) {
    final left = a.trim().toLowerCase();
    final right = b.trim().toLowerCase();
    return left.isNotEmpty &&
        right.isNotEmpty &&
        left != 'unknown artist' &&
        left != 'unknown album' &&
        left == right;
  }
}
