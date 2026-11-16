import 'dart:math' as math;

import '../models/dj_analysis.dart';
import '../models/listening_event.dart';
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

/// Lightweight, privacy-local listening preference signal derived from the
/// user's own playback history. Positive values indicate affinity; negative
/// values indicate repeated early skips or overexposure.
class DjListeningSignal {
  const DjListeningSignal({
    this.completionRatio = 0.5,
    this.skipRatio = 0,
    this.recentPlayCount = 0,
    this.favorite = false,
  });

  final double completionRatio;
  final double skipRatio;
  final int recentPlayCount;
  final bool favorite;

  double get preferenceScore {
    final completion = (completionRatio - 0.5) * 0.34;
    final skips = skipRatio * 0.42;
    final overplay = math.min(recentPlayCount, 6) * 0.035;
    final favoriteBoost = favorite ? 0.12 : 0.0;
    return (completion - skips - overplay + favoriteBoost)
        .clamp(-0.45, 0.30)
        .toDouble();
  }

  static Map<String, DjListeningSignal> fromHistory(
    List<ListeningEvent> events, {
    Set<String> favorites = const {},
  }) {
    final grouped = <String, List<ListeningEvent>>{};
    for (final event in events) {
      grouped.putIfAbsent(event.songId, () => []).add(event);
    }
    final result = <String, DjListeningSignal>{};
    for (final entry in grouped.entries) {
      final rows = entry.value;
      final skipped = rows.where((event) => event.skipped).length;
      final finishedCount = rows.where((event) => event.endedAt != null).length;
      final completionRatio = finishedCount == 0
          ? 0.5
          : rows.fold<double>(0, (sum, event) => sum +
              event.completionRatio.clamp(0.0, 1.0).toDouble()) / rows.length;
      final skipRatio = finishedCount == 0 ? 0.0 : skipped / finishedCount;
      result[entry.key] = DjListeningSignal(
        completionRatio: completionRatio,
        skipRatio: skipRatio,
        recentPlayCount: rows.length,
        favorite: favorites.contains(entry.key),
      );
    }
    for (final id in favorites) {
      result.putIfAbsent(id, () => const DjListeningSignal(favorite: true));
    }
    return result;
  }
}

class DjAutoSelectService {
  DjAutoSelectService({DjAnalysisService? analysis})
      : _analysis = analysis ?? DjAnalysisService();

  final DjAnalysisService _analysis;

  Future<DjAutoSelectResult> arrange(
    List<Song> songs, {
    math.Random? random,
    Map<String, DjListeningSignal> listeningSignals = const {},
  }) async {
    final analyses = <String, DjAnalysis>{};
    for (final song in songs) {
      final analysis = await _analysis.getAnalysis(song.id);
      if (analysis != null && !analysis.isStale && _matchesSong(song, analysis)) {
        analyses[song.id] = analysis;
      }
    }
    return arrangeWithAnalysis(
      songs,
      analyses,
      random: random,
      listeningSignals: listeningSignals,
    );
  }

  /// Pure ordering core, exposed so scoring and confidence gates are testable.
  DjAutoSelectResult arrangeWithAnalysis(
    List<Song> songs,
    Map<String, DjAnalysis> analyses, {
    math.Random? random,
    Map<String, DjListeningSignal> listeningSignals = const {},
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
      return a != null && !a.isStale && _matchesSong(song, a) && _trackConfidence(a) >= 0.25;
    }).length;
    final coverage = usable / input.length;
    final minimumUsable = math.min(3, input.length);
    if (usable < minimumUsable || coverage < 0.50) {
      // DJ was explicitly requested, so improve the next attempt without
      // blocking this playback start. Bound the warm-up to avoid scanning an
      // entire large library in one user interaction.
      var scheduled = 0;
      for (final song in input) {
        final analysis = analyses[song.id];
        if (analysis == null ||
            analysis.isStale ||
            !_matchesSong(song, analysis) ||
            _trackConfidence(analysis) < 0.25) {
          _analysis.scheduleAnalyze(song);
          scheduled++;
          if (scheduled >= 12) break;
        }
      }
      input.shuffle(rng);
      return DjAutoSelectResult(
        songs: input,
        usedDjArrangement: false,
        analysisCoverage: coverage,
        reason: 'insufficient_analysis_confidence',
      );
    }

    final remaining = List<Song>.of(input)..shuffle(rng);
    final energyValues = input
        .map((song) => analyses[song.id])
        .whereType<DjAnalysis>()
        .where((analysis) => analysis.hasUsableEnergy)
        .map((analysis) => analysis.energy!)
        .toList();
    final minEnergy = energyValues.isEmpty
        ? null
        : energyValues.reduce((a, b) => math.min(a, b).toDouble());
    final maxEnergy = energyValues.isEmpty
        ? null
        : energyValues.reduce((a, b) => math.max(a, b).toDouble());

    // Start with the gentlest analyzed track. This gives the set a deliberate
    // opening instead of allowing a random high-energy track to dictate the
    // entire progression.
    Song? opening;
    var openingScore = double.negativeInfinity;
    for (final candidate in remaining) {
      final analysis = analyses[candidate.id];
      final energy = analysis != null && analysis.hasUsableEnergy
          ? analysis.energy!
          : double.infinity;
      final preference = listeningSignals[candidate.id]?.preferenceScore ?? 0.0;
      final score = (energy.isFinite ? -energy : -2.0) +
          preference * 0.12 +
          rng.nextDouble() * 0.002;
      if (score > openingScore) {
        openingScore = score;
        opening = candidate;
      }
    }
    final ordered = <Song>[opening!];
    remaining.remove(opening);

    while (remaining.isNotEmpty) {
      final previous = ordered.last;
      final nextPosition = ordered.length;
      Song? best;
      var bestScore = double.negativeInfinity;
      for (final candidate in remaining) {
        final musical = _pairScore(
          analyses[previous.id],
          analyses[candidate.id],
        );
        final preference = listeningSignals[candidate.id]?.preferenceScore ?? 0.0;
        final sameArtist = _sameMetadata(previous.artist, candidate.artist);
        final sameAlbum = _sameMetadata(previous.album, candidate.album);
        final diversity = (sameArtist ? -0.10 : 0.035) +
            (sameAlbum ? -0.035 : 0.015);
        final energyArc = _energyArcScore(
          analyses[candidate.id],
          position: nextPosition,
          total: input.length,
          minEnergy: minEnergy,
          maxEnergy: maxEnergy,
        );
        // Musical compatibility remains the main transition signal. The
        // lower-weight arc score shapes the full set: warm-up, rise, peak,
        // then a controlled landing. Missing energy is neutral, not penalized.
        final score = musical +
            diversity +
            preference +
            energyArc * 0.20 +
            rng.nextDouble() * 0.025;
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

  static double _energyArcScore(
    DjAnalysis? analysis, {
    required int position,
    required int total,
    required double? minEnergy,
    required double? maxEnergy,
  }) {
    if (analysis == null ||
        !analysis.hasUsableEnergy ||
        minEnergy == null ||
        maxEnergy == null) {
      return 0.5;
    }
    final range = maxEnergy - minEnergy;
    if (range < 0.08) return 0.5;

    final progress = total <= 1 ? 1.0 : position / (total - 1);
    final target = progress <= 0.72
        ? 0.15 + (progress / 0.72) * 0.73
        : 0.88 - ((progress - 0.72) / 0.28) * 0.32;
    final normalized = (analysis.energy! - minEnergy) / range;
    return (1.0 - (normalized - target).abs()).clamp(0.0, 1.0).toDouble();
  }

  static bool _matchesSong(Song song, DjAnalysis analysis) {
    final songDuration = song.duration.inMilliseconds;
    final analyzedDuration = analysis.durationMs;
    if (songDuration <= 0 || analyzedDuration == null || analyzedDuration <= 0) {
      return true;
    }
    return (songDuration - analyzedDuration).abs() <= 1500;
  }

  static double _trackConfidence(DjAnalysis a) {
    var availableWeight = 0.0;
    var confidence = 0.0;
    if (a.hasUsableBpm) {
      availableWeight += 0.55;
      confidence += 0.55 * a.bpmConfidence.clamp(0.0, 1.0).toDouble();
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
          .clamp(0.0, 1.0).toDouble();
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
      final energy = 1.0 - (a.energy! - b.energy!).abs().clamp(0.0, 1.0).toDouble();
      weighted += energy * 0.20;
      weight += 0.20;
    }

    return weight < 0.18 ? 0.5 : weighted / weight;
  }

  static double _tempoCompatibility(double a, double b) {
    final ratios = <double>[b / a, (b * 2) / a, b / (a * 2)];
    final difference = ratios
        .map((ratio) => (ratio - 1.0).abs())
        .reduce((left, right) => left < right ? left : right);
    return (1.0 - difference / 0.18).clamp(0.0, 1.0).toDouble();
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
    return (0.72 - circleDistance * 0.055).clamp(0.30, 0.72).toDouble();
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
