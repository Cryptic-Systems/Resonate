import 'dart:math' as math;

/// Maps platter rotation to bounded seek previews and native scratch anchors.
/// Seek previews retain their millisecond UI contract; scratch anchors preserve
/// microsecond precision so frequent control updates do not quantize the audio cursor.
class DjConsoleJogSeekPolicy {
  const DjConsoleJogSeekPolicy._();

  static const double millisecondsPerRevolution = 8000;

  /// Maps the accumulated platter rotation to a track-time anchor without
  /// millisecond quantization. One revolution represents 1.8 seconds at
  /// 33⅓ RPM, matching the native scratch velocity mapping.
  static Duration scratchAnchorPosition({
    required Duration start,
    required double accumulatedRadians,
    required Duration duration,
  }) {
    final maximumUs = math.max(0, duration.inMicroseconds).toInt();
    final safeStartUs = start.inMicroseconds.clamp(0, maximumUs).toInt();
    if (!accumulatedRadians.isFinite) {
      return Duration(microseconds: safeStartUs);
    }
    const microsecondsPerRevolution = 1800000.0;
    final deltaUs =
        (accumulatedRadians / (math.pi * 2) * microsecondsPerRevolution)
            .round();
    final targetUs = (safeStartUs + deltaUs).clamp(0, maximumUs).toInt();
    return Duration(microseconds: targetUs);
  }

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
    final maximumMs = math.max(0, duration.inMilliseconds).toInt();
    final safeStartMs = start.inMilliseconds.clamp(0, maximumMs).toInt();
    if (!deltaRadians.isFinite) {
      return Duration(milliseconds: safeStartMs);
    }
    final deltaMs = (deltaRadians / (math.pi * 2) *
            millisecondsPerRevolution)
        .round();
    final targetMs = (safeStartMs + deltaMs).clamp(0, maximumMs).toInt();
    return Duration(milliseconds: targetMs);
  }
}
