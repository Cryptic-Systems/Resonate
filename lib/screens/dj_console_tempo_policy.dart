/// Conservative manual tempo-fader policy for the DJ Console.
///
/// Native Media3 accepts a wider 0.5–2.0 factor for compatibility, but the
/// initial Console fader is intentionally limited to ±6%.
class DjConsoleTempoParameters {
  const DjConsoleTempoParameters({
    required this.percent,
    required this.speed,
    required this.pitch,
  });

  final double percent;
  final double speed;
  final double pitch;
}

enum DjConsoleTempoDeckRole { active, standby, unavailable }

abstract final class DjConsoleTempoPolicy {
  /// Resolve physical A/B identity against the latest native promotion state.
  /// Unknown IDs stay unavailable; callers must not infer a role.
  static DjConsoleTempoDeckRole roleForPhysicalDeck({
    required String physicalDeckId,
    required String? activeDeckId,
  }) {
    if ((physicalDeckId != 'A' && physicalDeckId != 'B') ||
        (activeDeckId != 'A' && activeDeckId != 'B')) {
      return DjConsoleTempoDeckRole.unavailable;
    }
    return physicalDeckId == activeDeckId
        ? DjConsoleTempoDeckRole.active
        : DjConsoleTempoDeckRole.standby;
  }

  static const double minPercent = -6.0;
  static const double maxPercent = 6.0;

  /// Rejects out-of-policy commands rather than silently clamping them.
  static DjConsoleTempoParameters? parametersFor({
    required double percent,
    required bool keyLockEnabled,
  }) {
    if (!percent.isFinite || percent < minPercent || percent > maxPercent) {
      return null;
    }
    final speed = 1.0 + percent / 100.0;
    return DjConsoleTempoParameters(
      percent: percent,
      speed: speed,
      pitch: keyLockEnabled ? 1.0 : speed,
    );
  }

  static double? effectiveBpm({
    required double sourceBpm,
    required double percent,
  }) {
    if (!sourceBpm.isFinite || sourceBpm <= 0) return null;
    final parameters = parametersFor(
      percent: percent,
      keyLockEnabled: true,
    );
    if (parameters == null) return null;
    return sourceBpm * parameters.speed;
  }
}
