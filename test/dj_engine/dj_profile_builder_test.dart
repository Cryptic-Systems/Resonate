import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/analysis/dj_profile_builder.dart';
import 'package:resonate/models/dj_analysis.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';

void main() {
  const builder = DjProfileBuilder();

  test('keeps intro and outro hints as absolute track-relative positions', () {
    const analysis = DjAnalysis(
      songId: 'cue-track',
      durationMs: 180000,
      introHintMs: 12000,
      outroHintMs: 166000,
      energy: 0.7,
      loudness: 0.6,
    );

    final profile = builder.fromAnalysis(analysis);

    expect(profile.transitions.bestIntroMs, 12000);
    expect(profile.transitions.bestOutroMs, 166000);
    final outro = profile.sections.singleWhere(
      (section) => section.type == DjSectionType.outro,
    );
    expect(outro.startMs, 166000);
    expect(outro.endMs, 180000);
    expect(profile.energyCurve.any((point) => point.timeMs == 166000), isTrue);
    expect(profile.energyCurve.any((point) => point.timeMs == 14000), isFalse);
  });

  test('clamps malformed cue timestamps to known track bounds', () {
    const analysis = DjAnalysis(
      songId: 'bad-cues',
      durationMs: 180000,
      introHintMs: -500,
      outroHintMs: 220000,
      energy: 0.5,
    );

    final profile = builder.fromAnalysis(analysis);

    expect(profile.transitions.bestIntroMs, 0);
    expect(profile.transitions.bestOutroMs, 180000);
    final outro = profile.sections.singleWhere(
      (section) => section.type == DjSectionType.outro,
    );
    expect(outro.startMs, 180000);
    expect(outro.endMs, 180000);
  });
}
