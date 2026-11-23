import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/screens/dj_console_jog_seek_policy.dart';

void main() {
  group('DjConsoleJogSeekPolicy', () {
    test('one full revolution advances eight seconds', () {
      final result = DjConsoleJogSeekPolicy.targetPosition(
        start: const Duration(seconds: 20),
        deltaRadians: math.pi * 2,
        duration: const Duration(minutes: 3),
      );
      expect(result, const Duration(seconds: 28));
    });

    test('reverse rotation moves backward', () {
      final result = DjConsoleJogSeekPolicy.targetPosition(
        start: const Duration(seconds: 20),
        deltaRadians: -math.pi,
        duration: const Duration(minutes: 3),
      );
      expect(result, const Duration(seconds: 16));
    });

    test('seek preview clamps at track boundaries', () {
      expect(
        DjConsoleJogSeekPolicy.targetPosition(
          start: const Duration(seconds: 2),
          deltaRadians: -math.pi * 2,
          duration: const Duration(minutes: 1),
        ),
        Duration.zero,
      );
      expect(
        DjConsoleJogSeekPolicy.targetPosition(
          start: const Duration(seconds: 58),
          deltaRadians: math.pi * 2,
          duration: const Duration(minutes: 1),
        ),
        const Duration(minutes: 1),
      );
    });

    test('normalizes angle wrap across the -pi/pi boundary', () {
      expect(
        DjConsoleJogSeekPolicy.normalizedAngleDelta(-math.pi * 1.9),
        closeTo(math.pi * 0.1, 0.000001),
      );
    });

    test('non-finite input cannot produce an invalid target', () {
      expect(
        DjConsoleJogSeekPolicy.targetPosition(
          start: const Duration(seconds: 12),
          deltaRadians: double.nan,
          duration: const Duration(minutes: 1),
        ),
        const Duration(seconds: 12),
      );
    });
  });
}
