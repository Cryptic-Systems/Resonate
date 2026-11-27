import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/screens/dj_console_overlay_policy.dart';

void main() {
  group('DjConsoleOverlayPolicy', () {
    const beats = <int>[
      0, 500, 1000, 1500, 2000, 2500, 3000, 3500,
      4000, 4500, 5000, 5500, 6000, 6500, 7000, 7500,
      8000, 8500, 9000, 9500, 10000, 10500, 11000, 11500,
      12000, 12500, 13000, 13500, 14000, 14500, 15000, 15500,
    ];

    test('hides beat grid when tempo confidence is below threshold', () {
      const grid = DjBeatGrid(
        bpm: 120,
        confidence: 0.64,
        beatMs: beats,
        barConfidence: 0.9,
        phraseConfidence: 0.9,
      );

      expect(DjConsoleOverlayPolicy.beatTicks(grid), isEmpty);
      expect(DjConsoleOverlayPolicy.barTicks(grid), isEmpty);
      expect(DjConsoleOverlayPolicy.phraseTicks(grid), isEmpty);
    });

    test('shows measured beat ticks only after confidence and coverage gates', () {
      const lowCoverage = DjBeatGrid(
        bpm: 120,
        confidence: 0.9,
        beatMs: <int>[0, 500, 1000, 1500, 2000, 2500, 3000],
      );
      const trusted = DjBeatGrid(
        bpm: 120,
        confidence: 0.9,
        beatMs: beats,
      );

      expect(DjConsoleOverlayPolicy.beatTicks(lowCoverage), isEmpty);
      expect(DjConsoleOverlayPolicy.beatTicks(trusted), beats);
    });

    test('bar and phrase overlays require their own confidence evidence', () {
      const grid = DjBeatGrid(
        bpm: 120,
        confidence: 0.9,
        beatMs: beats,
        barConfidence: 0.68,
        phraseConfidence: 0.71,
      );

      expect(DjConsoleOverlayPolicy.barTicks(grid), <int>[0, 2000, 4000, 6000, 8000, 10000, 12000, 14000]);
      expect(DjConsoleOverlayPolicy.phraseTicks(grid), isEmpty);

      const phraseTrusted = DjBeatGrid(
        bpm: 120,
        confidence: 0.9,
        beatMs: beats,
        barConfidence: 0.8,
        phraseConfidence: 0.72,
      );
      expect(DjConsoleOverlayPolicy.phraseTicks(phraseTrusted), <int>[0, 8000]);
    });

    test('exposes only a nearby upcoming beat from a trusted grid', () {
      const trusted = DjBeatGrid(
        bpm: 120,
        confidence: 0.9,
        beatMs: beats,
      );
      const uncertain = DjBeatGrid(
        bpm: 120,
        confidence: 0.64,
        beatMs: beats,
      );

      expect(DjConsoleOverlayPolicy.nextBeatInMs(trusted, 1250), 250);
      expect(DjConsoleOverlayPolicy.nextBeatInMs(trusted, 1500), 0);
      expect(DjConsoleOverlayPolicy.nextBeatInMs(trusted, 0), 0);
      expect(DjConsoleOverlayPolicy.nextBeatInMs(trusted, 10000), 0);
      expect(DjConsoleOverlayPolicy.nextBeatInMs(uncertain, 1250), isNull);
      expect(DjConsoleOverlayPolicy.nextBeatInMs(trusted, -1), isNull);
    });

    test('returns only a confidence-qualified section containing playhead', () {
      const sections = <DjSection>[
        DjSection(type: DjSectionType.intro, startMs: 0, endMs: 8000, confidence: 0.8),
        DjSection(type: DjSectionType.drop, startMs: 8000, endMs: 12000, confidence: 0.69),
      ];

      expect(
        DjConsoleOverlayPolicy.trustedSectionAt(sections, 4000)?.type,
        DjSectionType.intro,
      );
      expect(DjConsoleOverlayPolicy.trustedSectionAt(sections, 9000), isNull);
      expect(DjConsoleOverlayPolicy.trustedSectionAt(sections, 12000), isNull);
    });

    test('filters unknown, low-confidence and invalid sections', () {
      const sections = <DjSection>[
        DjSection(type: DjSectionType.intro, startMs: 0, endMs: 8000, confidence: 0.8),
        DjSection(type: DjSectionType.drop, startMs: 8000, endMs: 12000, confidence: 0.69),
        DjSection(type: DjSectionType.unknown, startMs: 12000, endMs: 16000, confidence: 0.9),
        DjSection(type: DjSectionType.verse, startMs: 16000, endMs: 15000, confidence: 0.9),
      ];

      expect(
        DjConsoleOverlayPolicy.trustedSections(sections).map((s) => s.type),
        <DjSectionType>[DjSectionType.intro],
      );
    });
  });
}
