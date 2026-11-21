import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/models/dj_analysis.dart';
import 'package:resonate/services/dj_bpm_estimator.dart';
import 'package:resonate/services/dj_transition_planner.dart';

void main() {
  DjAnalysis analysis(String id, double bpm, double confidence) => DjAnalysis(
        songId: id,
        bpm: bpm,
        bpmConfidence: confidence,
        bpmSource: 'pcm_native',
      );

  test('accepts a close, confident match but caps stretch at six percent', () {
    final plan = computeSafeTempoStretch(
      bpmA: 128,
      bpmB: 122,
      confidenceA: 0.95,
      confidenceB: 0.92,
      maxStretchPercent: 22,
    );

    expect(plan, isNotNull);
    expect(plan!.speedOutgoing, 1.0);
    expect(plan.speedIncoming, inInclusiveRange(0.94, 1.06));
  });

  test('rejects low-confidence BPM even when the numbers are close', () {
    expect(
      computeSafeTempoStretch(
        bpmA: 128,
        bpmB: 126,
        confidenceA: 0.95,
        confidenceB: 0.55,
        maxStretchPercent: 6,
      ),
      isNull,
    );
  });

  test('rejects a tempo gap beyond six percent instead of stretching across it', () {
    expect(
      computeSafeTempoStretch(
        bpmA: 128,
        bpmB: 114,
        confidenceA: 0.95,
        confidenceB: 0.95,
        maxStretchPercent: 22,
      ),
      isNull,
    );
  });

  test('recognizes a confident half-time BPM interpretation without pitch shifting', () {
    final plan = computeSafeTempoStretch(
      bpmA: 128,
      bpmB: 64,
      confidenceA: 0.95,
      confidenceB: 0.95,
      maxStretchPercent: 22,
    );

    expect(plan, isNotNull);
    expect(plan!.speedIncoming, 1.0);
  });

  test('legacy planner never creates a stretch from weak BPM evidence', () {
    final plan = planDjTransition(
      analysisA: analysis('a', 128, 0.95),
      analysisB: analysis('b', 126, 0.50),
      tempoMatchActive: true,
      beatAlignActive: false,
      maxStretchPercent: 22,
    );

    expect(plan.stretch, isNull);
    expect(plan.strategy, 'safe_fallback');
  });

  test('legacy planner enforces the same six-percent ceiling', () {
    final plan = planDjTransition(
      analysisA: analysis('a', 128, 0.95),
      analysisB: analysis('b', 122, 0.95),
      tempoMatchActive: true,
      beatAlignActive: false,
      maxStretchPercent: 22,
    );

    expect(plan.stretch, isNotNull);
    expect(plan.stretch!.speedIncoming, inInclusiveRange(0.94, 1.06));
  });
}
