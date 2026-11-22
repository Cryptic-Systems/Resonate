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

  static List<int> beatTicks(DjBeatGrid grid) {
    if (!grid.usable ||
        grid.confidence < beatConfidenceThreshold ||
        grid.beatMs.length < 8) {
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
