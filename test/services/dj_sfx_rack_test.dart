import 'dart:math' show Random;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/dj_engine/core/dj_policy.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/services/dj_sfx_rack.dart';
import 'package:resonate/services/playback_engine_session.dart';
import 'package:resonate/services/playback_backend.dart';

const safePool = <DjSfxPreset>{
  DjSfxPreset.tightGlue,
  DjSfxPreset.dryEcho,
  DjSfxPreset.echo,
  DjSfxPreset.filterOpen,
  DjSfxPreset.filterClose,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<DjSfxPreset> selectPreset(DjSfxRack rack, {required DjSfxPreset preferred, required DjAggressiveness aggressiveness}) async {
    await rack.engage(energyScore: 0.5, preset: preferred, aggressiveness: aggressiveness);
    final selected = rack.activePreset!;
    await rack.restore();
    return selected;
  }

  group('DJ one-shot sample gain', () {
    test('uses a conservative base gain and reduces it for higher energy', () {
      expect(djSfxOneShotVolumeForEnergy(0.2), 0.12);
      expect(djSfxOneShotVolumeForEnergy(0.7), 0.10);
      expect(djSfxOneShotVolumeForEnergy(0.9), 0.08);
    });

    test('normalizes out-of-range and non-finite energy scores', () {
      expect(djSfxOneShotVolumeForEnergy(double.nan), 0.12);
      expect(djSfxOneShotVolumeForEnergy(double.infinity), 0.12);
      expect(djSfxOneShotVolumeForEnergy(-1), 0.12);
      expect(djSfxOneShotVolumeForEnergy(2), 0.08);
    });
  });

  group('DjSfxRack Media3 deck overlays', () {
    test('routes transition EQ through both Media3 decks and clears on restore', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final session = _RecordingDeckOverlaySession();

      await rack.engage(
        energyScore: 0.5,
        preset: DjSfxPreset.filterOpen,
        playbackSession: session,
      );
      expect(session.setCalls.map((call) => call.deck), ['active', 'standby']);
      expect(session.setCalls.first.centersHz, hasLength(31));
      expect(
        session.setCalls.first.centersHz,
        orderedEquals(session.setCalls.first.centersHz.toList()..sort()),
      );

      await rack.tick(0.5);
      expect(session.setCalls.last.deck, 'standby');
      expect(session.setCalls.last.gainsDb.first, closeTo(0.0, 1e-9));
      expect(session.setCalls.last.gainsDb.last, closeTo(-3.0, 1e-9));

      await rack.restore();
      expect(session.clearCalls, ['active', 'standby']);
    });

    test('routes auxiliary samples and track automation through Media3 session capabilities', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final session = _RecordingDeckOverlaySession();
      final legacyOnlyPresets = <DjSfxPreset>[
        DjSfxPreset.airHorn,
        DjSfxPreset.gunshot,
        DjSfxPreset.vinylScratch,
        DjSfxPreset.rewind,
        DjSfxPreset.whoosh,
        DjSfxPreset.impact,
        DjSfxPreset.scratch,
        DjSfxPreset.stutter,
        DjSfxPreset.beatRepeat,
        DjSfxPreset.retrigger,
        DjSfxPreset.brake,
        DjSfxPreset.echo,
        DjSfxPreset.dryEcho,
        DjSfxPreset.repeat,
        DjSfxPreset.repeatRestart,
      ];

      for (final requested in legacyOnlyPresets) {
        session.setCalls.clear();
        session.clearCalls.clear();
        await rack.engage(
          energyScore: 0.5,
          preset: requested,
          playbackSession: session,
        );

        expect(
          rack.activePreset,
          requested,
          reason: '$requested should remain available through the Media3 session contract',
        );
        if (requested == DjSfxPreset.filterOpen || requested == DjSfxPreset.filterClose) {
          expect(session.setCalls.map((call) => call.deck), ['active', 'standby']);
        } else {
          expect(session.setCalls, isEmpty);
        }
        await rack.restore();
        if (requested == DjSfxPreset.filterOpen || requested == DjSfxPreset.filterClose) {
          expect(session.clearCalls, ['active', 'standby']);
        } else {
          expect(session.clearCalls, isEmpty);
        }
      }
    });

    test('cancels Media3 brake automation and restores the captured playback rate', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final session = _RecordingDeckOverlaySession();

      await rack.engage(
        energyScore: 0.8,
        preset: DjSfxPreset.brake,
        playbackSession: session,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await rack.restore();

      expect(session.speedCalls, isNotEmpty);
      expect(session.speedCalls.any((speed) => speed < 1.25), isTrue);
      expect(session.speedCalls.last, 1.25);
      expect(rack.engaged, isFalse);
    });

    test('routes Media3 scratch seeks through the canonical session', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final session = _RecordingDeckOverlaySession();

      await rack.engage(
        energyScore: 0.8,
        preset: DjSfxPreset.scratch,
        playbackSession: session,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await rack.restore();

      expect(session.seekCalls, isNotEmpty);
      expect(session.speedCalls.last, 1.25);
    });

    test('cancels Media3 scratch steps immediately and restores playback rate', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final session = _RecordingDeckOverlaySession();

      await rack.engage(
        energyScore: 0.8,
        preset: DjSfxPreset.scratch,
        playbackSession: session,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final seekCountAtCancellation = session.seekCalls.length;
      expect(seekCountAtCancellation, greaterThan(0));

      final cancellation = rack.cancelTrackAutomation();
      await cancellation;
      await Future<void>.delayed(const Duration(milliseconds: 260));

      expect(session.seekCalls, hasLength(seekCountAtCancellation));
      expect(session.speedCalls.last, 1.25);
      await rack.restore();
    });

    test('cancels every Media3 track-manipulation preset without stale commands', () async {
      const presets = <DjSfxPreset>[
        DjSfxPreset.brake,
        DjSfxPreset.vinylStop,
        DjSfxPreset.scratch,
        DjSfxPreset.stutter,
        DjSfxPreset.beatRepeat,
        DjSfxPreset.retrigger,
        DjSfxPreset.repeat,
        DjSfxPreset.repeatRestart,
      ];

      for (final preset in presets) {
        final rack = DjSfxRack(random: _SequenceRandom());
        final session = _RecordingDeckOverlaySession();
        await rack.engage(
          energyScore: 0.8,
          preset: preset,
          playbackSession: session,
        );
        await Future<void>.delayed(const Duration(milliseconds: 15));
        final seeksAtCancellation = session.seekCalls.length;
        final ratesAtCancellation = session.speedCalls.length;

        await rack.cancelTrackAutomation();
        final restoredRateCount = session.speedCalls.length;
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(session.seekCalls, hasLength(seeksAtCancellation), reason: '$preset issued a stale seek after cancellation');
        expect(session.speedCalls, hasLength(restoredRateCount), reason: '$preset issued a stale rate change after cancellation');
        expect(session.speedCalls.last, 1.25, reason: '$preset did not restore the captured playback rate');
        expect(restoredRateCount, greaterThanOrEqualTo(ratesAtCancellation));
        await rack.restore();
      }
    });

    test('retains the engaged Media3 session for tick and restore', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final session = _RecordingDeckOverlaySession();

      await rack.engage(
        energyScore: 0.5,
        preset: DjSfxPreset.filterClose,
        playbackSession: session,
      );
      final callsAfterEngage = session.setCalls.length;

      await rack.tick(0.4);
      expect(session.setCalls.length, callsAfterEngage + 2);
      expect(session.setCalls.last.deck, 'standby');

      await rack.restore();
      expect(session.clearCalls, ['active', 'standby']);
    });

    test('restores the previous session before engaging a replacement session', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final previous = _RecordingDeckOverlaySession();
      final replacement = _RecordingDeckOverlaySession();

      await rack.engage(
        energyScore: 0.5,
        preset: DjSfxPreset.filterOpen,
        playbackSession: previous,
      );
      await rack.engage(
        energyScore: 0.5,
        preset: DjSfxPreset.filterClose,
        playbackSession: replacement,
      );

      expect(previous.clearCalls, ['active', 'standby']);
      expect(replacement.setCalls.map((call) => call.deck), ['active', 'standby']);

      await rack.restore();
      expect(replacement.clearCalls, ['active', 'standby']);
    });

  });

  group('DjSfxRack usage fairness', () {
    test('rotates after two uses and exhausts the eligible pool fairly', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      final counts = <DjSfxPreset, int>{};
      for (var i = 0; i < 10; i++) {
        final selected = await selectPreset(rack, preferred: DjSfxPreset.tightGlue, aggressiveness: DjAggressiveness.safe);
        counts[selected] = (counts[selected] ?? 0) + 1;
        expect(counts[selected], lessThanOrEqualTo(2), reason: 'Effect $selected exceeded its two-use allowance at pick $i');
      }
      expect(counts.keys.toSet(), containsAll(safePool));
      expect(counts.values, everyElement(2));
      expect(await selectPreset(rack, preferred: DjSfxPreset.tightGlue, aggressiveness: DjAggressiveness.safe), DjSfxPreset.tightGlue);
    });

    test('safe aggressiveness never selects outside its eligible pool', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      for (var i = 0; i < 12; i++) {
        await rack.engage(energyScore: 0.5, transitionKind: DjTransitionKind.safeCrossfade, aggressiveness: DjAggressiveness.safe);
        expect(safePool, contains(rack.activePreset));
        await rack.restore();
      }
    });

    test('repeat and repeat-restart requests use non-seeking SFX instead', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      for (final requested in <DjSfxPreset>[
        DjSfxPreset.repeat,
        DjSfxPreset.repeatRestart,
      ]) {
        await rack.engage(
          energyScore: 0.5,
          preset: requested,
          aggressiveness: DjAggressiveness.balanced,
        );
        expect(
          rack.activePreset,
          isNot(anyOf(DjSfxPreset.repeat, DjSfxPreset.repeatRestart)),
          reason: '$requested must not seek/restart the outgoing track during a fade',
        );
        await rack.restore();
      }
    });

    test('phrase blends never choose repeat/restart SFX in musical mode', () async {
      final rack = DjSfxRack(random: _SequenceRandom());
      for (var i = 0; i < 20; i++) {
        await rack.engage(
          energyScore: 0.5,
          transitionKind: DjTransitionKind.phraseBlend,
          aggressiveness: DjAggressiveness.musical,
        );
        expect(
          rack.activePreset,
          isNot(anyOf(DjSfxPreset.repeat, DjSfxPreset.repeatRestart)),
          reason: 'phrase blend $i must use a non-seeking effect',
        );
        await rack.restore();
      }
    });
  });
}

class _SequenceRandom implements Random {
  int _next = 0;
  @override
  int nextInt(int max) => (_next++ % max);
  @override
  bool nextBool() => nextInt(2) == 0;
  @override
  double nextDouble() => nextInt(1000) / 1000;
}

class _DeckOverlayCall {
  _DeckOverlayCall(this.deck, this.centersHz, this.gainsDb);
  final String deck;
  final List<double> centersHz;
  final List<double> gainsDb;
}

class _RecordingDeckOverlaySession implements PlaybackEngineSession, PlaybackAuxiliaryEffectsBackend {
  final List<_DeckOverlayCall> setCalls = <_DeckOverlayCall>[];
  final List<String> clearCalls = <String>[];
  final List<Duration> seekCalls = <Duration>[];
  final List<double> speedCalls = <double>[];
  final List<String> auxiliaryCalls = <String>[];

  @override
  double playbackSpeed = 1.25;

  @override
  Duration position = const Duration(seconds: 20);

  @override
  Duration? duration = const Duration(minutes: 4);

  @override
  Future<void> seek(Duration value) async { seekCalls.add(value); }

  @override
  Future<void> setPlaybackSpeed(double value) async {
    playbackSpeed = value;
    speedCalls.add(value);
  }

  @override
  Future<void> playAuxiliarySound(Uri uri, {required double volume, Duration startPosition = Duration.zero, Duration? endPosition}) async {
    auxiliaryCalls.add('play:${uri.toString()}:${volume.toString()}');
  }

  @override
  Future<void> setAuxiliarySoundVolume(double volume) async { auxiliaryCalls.add('volume:${volume.toString()}'); }

  @override
  Future<void> stopAuxiliarySound() async { auxiliaryCalls.add('stop'); }

  @override
  Future<void> setDeckEqOverlay({
    required String deck,
    required List<double> centersHz,
    required List<double> gainsDb,
  }) async {
    setCalls.add(_DeckOverlayCall(
      deck,
      List<double>.from(centersHz),
      List<double>.from(gainsDb),
    ));
  }

  @override
  Future<void> clearDeckEqOverlay({required String deck}) async {
    clearCalls.add(deck);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
