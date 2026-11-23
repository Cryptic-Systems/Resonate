import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/screens/dj_console_tempo_policy.dart';

void main() {
  group('DjConsoleTempoPolicy', () {
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
