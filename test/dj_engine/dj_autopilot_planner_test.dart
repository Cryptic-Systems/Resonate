import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/dj_engine/core/dj_policy.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/dj_engine/intelligence/dj_autopilot_planner.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  DjTrackProfile track(String id, {bool outgoing = false}) => DjTrackProfile(
    songId: id, durationMs: 240000,
    beatGrid: const DjBeatGrid(
      bpm: 128, confidence: 0.95, firstBeatMs: 0,
      beatMs: [0, 469, 938, 1406, 1875, 2344, 2813, 3281]),
    sections: [DjSection(
      type: outgoing ? DjSectionType.outro : DjSectionType.intro,
      startMs: outgoing ? 220000 : 0,
      endMs: outgoing ? 240000 : 20000,
      confidence: 0.9, energy: 0.65)],
    energyCurve: [DjEnergyPoint(timeMs: outgoing ? 220000 : 0, value: 0.65)],
    analysisConfidence: 0.95,
  );

  test('honours a safe user-preferred strategy when policy accepts it', () async {
    final selected = await DjAutopilotPlanner().choose(
      outgoing: track('a', outgoing: true), incoming: track('b'),
      outgoingPositionMs: 210000, preferredDurationMs: 6500, maxDurationMs: 6500,
      policy: DjPolicy.balanced, preferredKind: DjTransitionKind.safeCrossfade);
    expect(selected.kind, DjTransitionKind.safeCrossfade);
    expect(selected.outgoingStartMs, greaterThanOrEqualTo(210000));
  });

  test('uses autonomous ranking when the preferred strategy is unavailable', () async {
    final selected = await DjAutopilotPlanner().choose(
      outgoing: track('a', outgoing: true), incoming: track('b'),
      outgoingPositionMs: 210000, preferredDurationMs: 6500, maxDurationMs: 6500,
      policy: DjPolicy.balanced, preferredKind: DjTransitionKind.breakdownDrop);
    expect(selected.kind, isNot(DjTransitionKind.breakdownDrop));
  });
}
