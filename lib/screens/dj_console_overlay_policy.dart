import '../dj_engine/core/dj_types.dart';

/// Conservative presentation policy for measured DJ Console overlays.
///
/// This policy never creates timing data. It only exposes timestamps already
/// present in a track profile when the corresponding confidence is sufficient.
class DjConsoleOverlayPolicy {
  const DjConsoleOverlayPolicy._();

  static const double beatConfidenceThreshold = 0.65;
  static const double barConfidenceThreshold = 0.68;
  static const double phraseConfidenceThreshold = 0.72;
  static const double sectionConfidenceThreshold = 0.70;

  static bool hasTrustedTempo(DjBeatGrid grid) =>
      grid.usable &&
      grid.confidence >= beatConfidenceThreshold &&
      grid.beatMs.length >= 8;

  static int? nextBeatInMs(DjBeatGrid grid, int positionMs) {
    if (!hasTrustedTempo(grid) || positionMs < 0) return null;
    for (final beat in grid.beatMs) {
      if (beat >= positionMs) {
        final delta = beat - positionMs;
        return delta <= 2000 ? delta : null;
      }
    }
    return null;
  }

  static DjSection? trustedSectionAt(
    List<DjSection> sections,
    int positionMs,
  ) {
    if (positionMs < 0) return null;
    for (final section in trustedSections(sections)) {
      if (positionMs >= section.startMs && positionMs < section.endMs) {
        return section;
      }
    }
    return null;
  }

  static List<int> beatTicks(DjBeatGrid grid) {
    if (!hasTrustedTempo(grid)) {
      return const [];
    }
    return grid.beatMs;
  }

  static List<int> barTicks(DjBeatGrid grid) {
    if (grid.barConfidence < barConfidenceThreshold ||
        grid.beatsPerBar <= 0) {
      return const [];
    }
    final beats = beatTicks(grid);
    if (beats.isEmpty) return const [];
    return <int>[
      for (var i = 0; i < beats.length; i += grid.beatsPerBar) beats[i],
    ];
  }

  static List<int> phraseTicks(DjBeatGrid grid) {
    if (grid.phraseConfidence < phraseConfidenceThreshold ||
        grid.beatsPerPhrase <= 0) {
      return const [];
    }
    final beats = beatTicks(grid);
    if (beats.length < grid.beatsPerPhrase) return const [];
    return <int>[
      for (var i = 0; i < beats.length; i += grid.beatsPerPhrase)
        beats[i],
    ];
  }

  static List<DjSection> trustedSections(List<DjSection> sections) {
    return sections
        .where((section) =>
            section.type != DjSectionType.unknown &&
            section.confidence >= sectionConfidenceThreshold &&
            section.startMs >= 0 &&
            section.endMs > section.startMs)
        .toList(growable: false);
  }
}
