import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/screens/dj_console_tempo_policy.dart';

void main() {
  group('DjConsoleTempoPolicy', () {
    test('updates only the selected physical deck and preserves the other', () {
      final activeA = DjConsoleTempoPolicy.commandForPhysicalDeck(
        physicalDeckId: 'A',
        activeDeckId: 'A',
        activeSpeed: 1.02,
        activePitch: 1.0,
        standbySpeed: 0.98,
        standbyPitch: 1.0,
        percent: 4,
        keyLockEnabled: true,
      )!;
      expect(activeA.activeSpeed, closeTo(1.04, 0.000001));
      expect(activeA.activePitch, 1.0);
      expect(activeA.standbySpeed, 0.98);
      expect(activeA.standbyPitch, 1.0);

      // After promotion B is on air. Editing physical A must now target
      // logical standby while preserving the newly active B parameters.
      final standbyA = DjConsoleTempoPolicy.commandForPhysicalDeck(
        physicalDeckId: 'A',
        activeDeckId: 'B',
        activeSpeed: 0.98,
        activePitch: 1.0,
        standbySpeed: 1.02,
        standbyPitch: 1.0,
        percent: -2,
        keyLockEnabled: false,
      )!;
      expect(standbyA.activeSpeed, 0.98);
      expect(standbyA.activePitch, 1.0);
      expect(standbyA.standbySpeed, closeTo(0.98, 0.000001));
      expect(standbyA.standbyPitch, closeTo(0.98, 0.000001));
    });

    test('rejects incomplete native deck readback for tempo writes', () {
      expect(
        DjConsoleTempoPolicy.commandForPhysicalDeck(
          physicalDeckId: 'A',
          activeDeckId: 'A',
          activeSpeed: double.nan,
          activePitch: 1,
          standbySpeed: 1,
          standbyPitch: 1,
          percent: 2,
          keyLockEnabled: true,
        ),
        isNull,
      );
      expect(
        DjConsoleTempoPolicy.commandForPhysicalDeck(
          physicalDeckId: 'A',
          activeDeckId: null,
          activeSpeed: 1,
          activePitch: 1,
          standbySpeed: 1,
          standbyPitch: 1,
          percent: 2,
          keyLockEnabled: true,
        ),
        isNull,
      );
    });

    test('maps physical decks through native role promotion', () {
      expect(DjConsoleTempoPolicy.roleForPhysicalDeck(physicalDeckId: 'A', activeDeckId: 'A'), DjConsoleTempoDeckRole.active);
      expect(DjConsoleTempoPolicy.roleForPhysicalDeck(physicalDeckId: 'B', activeDeckId: 'A'), DjConsoleTempoDeckRole.standby);
      expect(DjConsoleTempoPolicy.roleForPhysicalDeck(physicalDeckId: 'A', activeDeckId: 'B'), DjConsoleTempoDeckRole.standby);
      expect(DjConsoleTempoPolicy.roleForPhysicalDeck(physicalDeckId: 'B', activeDeckId: 'B'), DjConsoleTempoDeckRole.active);
      expect(DjConsoleTempoPolicy.roleForPhysicalDeck(physicalDeckId: 'A', activeDeckId: null), DjConsoleTempoDeckRole.unavailable);
    });

    test('maps the fader percentage to playback speed', () {
      final slower = DjConsoleTempoPolicy.parametersFor(percent: -6, keyLockEnabled: true);
      final faster = DjConsoleTempoPolicy.parametersFor(percent: 6, keyLockEnabled: true);
      expect(slower?.speed, closeTo(0.94, 0.000001));
      expect(faster?.speed, closeTo(1.06, 0.000001));
    });

    test('key lock keeps pitch at unity while tempo changes', () {
      final parameters = DjConsoleTempoPolicy.parametersFor(percent: 4.5, keyLockEnabled: true);
      expect(parameters?.speed, closeTo(1.045, 0.000001));
      expect(parameters?.pitch, 1.0);
    });

    test('disabling key lock links pitch to playback speed', () {
      final parameters = DjConsoleTempoPolicy.parametersFor(percent: -3, keyLockEnabled: false);
      expect(parameters?.speed, closeTo(0.97, 0.000001));
      expect(parameters?.pitch, closeTo(0.97, 0.000001));
    });

    test('rejects non-finite and out-of-range fader positions', () {
      expect(DjConsoleTempoPolicy.parametersFor(percent: double.nan, keyLockEnabled: true), isNull);
      expect(DjConsoleTempoPolicy.parametersFor(percent: 6.01, keyLockEnabled: true), isNull);
      expect(DjConsoleTempoPolicy.parametersFor(percent: -6.01, keyLockEnabled: false), isNull);
    });

    test('calculates effective BPM only for valid source tempo and fader', () {
      expect(DjConsoleTempoPolicy.effectiveBpm(sourceBpm: 120, percent: 5), closeTo(126, 0.000001));
      expect(DjConsoleTempoPolicy.effectiveBpm(sourceBpm: 0, percent: 5), isNull);
      expect(DjConsoleTempoPolicy.effectiveBpm(sourceBpm: 120, percent: 7), isNull);
    });
  });
}
