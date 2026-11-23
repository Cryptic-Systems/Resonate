import 'dart:math' as math;

/// Maps platter rotation to a bounded seek preview. One complete revolution
/// represents eight seconds of track movement; this is deliberately a seek
/// gesture, not platter-speed control or scratch emulation.
class DjConsoleJogSeekPolicy {
  const DjConsoleJogSeekPolicy._();

  static const double millisecondsPerRevolution = 8000;

  static double normalizedAngleDelta(double radians) {
    if (!radians.isFinite) return 0;
    var value = radians;
    while (value > math.pi) {
      value -= math.pi * 2;
    }
    while (value < -math.pi) {
      value += math.pi * 2;
    }
    return value;
  }

  static Duration targetPosition({
    required Duration start,
    required double deltaRadians,
    required Duration duration,
  }) {
    final maximumMs = math.max(0, duration.inMilliseconds);
    final safeStartMs = start.inMilliseconds.clamp(0, maximumMs);
    if (!deltaRadians.isFinite) {
      return Duration(milliseconds: safeStartMs);
    }
    final deltaMs = (deltaRadians / (math.pi * 2) *
            millisecondsPerRevolution)
        .round();
    final targetMs = (safeStartMs + deltaMs).clamp(0, maximumMs);
    return Duration(milliseconds: targetMs);
  }
}
