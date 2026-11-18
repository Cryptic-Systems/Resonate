import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/services/dj_transition_preset_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('persists directed pair cues and preferred strategy', () async {
    const preset = DjTransitionPreset(
      outgoingSongId: 'track-a', incomingSongId: 'track-b',
      outgoingCueMs: 188000, incomingCueMs: 12000, durationMs: 7200,
      preferredKind: DjTransitionKind.phraseBlend,
    );
    await DjTransitionPresetStore.save(preset);
    final loaded = await DjTransitionPresetStore.get('track-a', 'track-b');
    expect(loaded?.outgoingCueMs, 215000);
    expect(loaded?.incomingCueMs, 12000);
    expect(loaded?.durationMs, 7200);
    expect(loaded?.preferredKind, DjTransitionKind.phraseBlend);
    expect(await DjTransitionPresetStore.get('track-b', 'track-a'), isNull);
  });

  test('pair overlays preserve the source track profiles', () {
    const a = DjTrackProfile(songId: 'a', durationMs: 240000,
      transitions: DjTransitionMarkers(bestOutroMs: 210000));
    const b = DjTrackProfile(songId: 'b', durationMs: 220000,
      transitions: DjTransitionMarkers(bestIntroMs: 5000));
    const preset = DjTransitionPreset(
      outgoingSongId: 'a', incomingSongId: 'b',
      outgoingCueMs: 188000, incomingCueMs: 12000, durationMs: 7200);
    final out = preset.applyOutgoing(a);
    final incoming = preset.applyIncoming(b);
    expect(out.transitions.bestOutroMs, 188000);
    expect(out.transitions.safeMixOuts.single.timeMs, 188000);
    expect(incoming.transitions.bestIntroMs, 12000);
    expect(incoming.transitions.safeMixIns.single.timeMs, 12000);
    expect(a.transitions.bestOutroMs, 210000);
    expect(b.transitions.bestIntroMs, 5000);
  });

  test('rejects stale cues and cues that leave too little playable audio', () {
    const preset = DjTransitionPreset(
      outgoingSongId: 'a', incomingSongId: 'b',
      outgoingCueMs: 90000, incomingCueMs: 10000, durationMs: 6000);
    expect(preset.isUsableFor(outgoingPositionMs: 90001), isFalse);
    expect(preset.isUsableFor(outgoingPositionMs: 0, outgoingDurationMs: 91000), isFalse);
    expect(preset.isUsableFor(outgoingPositionMs: 0, incomingDurationMs: 11000), isFalse);
    expect(preset.isUsableFor(outgoingPositionMs: 0,
      outgoingDurationMs: 180000, incomingDurationMs: 180000), isTrue);
  });

  test('deleting one pair does not remove another pair', () async {
    await DjTransitionPresetStore.save(const DjTransitionPreset(
      outgoingSongId: 'a', incomingSongId: 'b',
      outgoingCueMs: 100000, incomingCueMs: 5000, durationMs: 6000));
    await DjTransitionPresetStore.save(const DjTransitionPreset(
      outgoingSongId: 'b', incomingSongId: 'c',
      outgoingCueMs: 110000, incomingCueMs: 8000, durationMs: 7000));
    await DjTransitionPresetStore.delete('a', 'b');
    expect(await DjTransitionPresetStore.get('a', 'b'), isNull);
    expect(await DjTransitionPresetStore.get('b', 'c'), isNotNull);
  });
}

  test('persists and validates an explicit repeat-one self preset', () async {
    const preset = DjTransitionPreset(
      outgoingSongId: 'repeat-track', incomingSongId: 'repeat-track',
      outgoingCueMs: 215000, incomingCueMs: 6000, durationMs: 7200,
      preferredKind: DjTransitionKind.phraseBlend,
    );
    await DjTransitionPresetStore.save(preset);
    final loaded = await DjTransitionPresetStore.get('repeat-track', 'repeat-track');
    expect(loaded?.outgoingSongId, 'repeat-track');
    expect(loaded?.incomingSongId, 'repeat-track');
    expect(loaded?.outgoingCueMs, 188000);
    expect(loaded?.incomingCueMs, 6000);
    expect(loaded?.preferredKind, DjTransitionKind.phraseBlend);
    expect(loaded?.isUsableFor(
      outgoingPositionMs: 200000,
      outgoingDurationMs: 240000,
      incomingDurationMs: 240000,
    ), isTrue);
    expect(loaded?.isUsableFor(
      outgoingPositionMs: 215001,
      outgoingDurationMs: 240000,
      incomingDurationMs: 240000,
    ), isFalse);
    expect(await DjTransitionPresetStore.get('repeat-track', 'other-track'), isNull);
  });
