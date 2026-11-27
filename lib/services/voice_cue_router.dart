import 'dart:collection';

/// The experience that originated a voice event. Automatic DJ mixing still
/// belongs to the Player; manual deck/Console actions belong to DJ Workspace.
enum VoiceCueOrigin { playerAuto, djManual, sharedSystem }

/// Routing permission assigned to an individual voice asset in the manifest.
enum VoiceCueRoute {
  playerAuto,
  djManual,
  bothContextual,
  sharedSystem,
  conditional,
}

enum VoiceCueBlockReason {
  voiceFeedbackDisabled,
  wrongWorkspace,
  unconfirmedEvent,
  expired,
  invalidRequest,
  duplicateEvent,
}

class VoiceCueRequest {
  const VoiceCueRequest({
    required this.cueId,
    required this.route,
    required this.origin,
    required this.eventId,
    required this.semanticGroup,
    required this.voiceFeedbackEnabled,
    required this.confirmed,
    required this.expiresAt,
    this.allowedOrigins,
  });

  /// Stable manifest ID. Never use a source filename as the runtime lookup key.
  final String cueId;
  final VoiceCueRoute route;
  final VoiceCueOrigin origin;
  final String eventId;
  final String semanticGroup;
  final bool voiceFeedbackEnabled;
  final bool confirmed;
  final DateTime expiresAt;
  final List<VoiceCueOrigin>? allowedOrigins;
}

class VoiceCueDecision {
  const VoiceCueDecision.allowed()
      : allowed = true,
        reason = null;

  const VoiceCueDecision.blocked(this.reason) : allowed = false;

  final bool allowed;
  final VoiceCueBlockReason? reason;
}

/// Deterministic eligibility and duplicate suppression. The caller supplies time
/// so expiry behavior is testable and never depends on background timers.
class VoiceCueRouter {
  VoiceCueRouter({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const int _maxRememberedEvents = 512;
  final DateTime Function() _clock;
  final LinkedHashMap<String, DateTime> _spokenEventGroups =
      LinkedHashMap<String, DateTime>();

  VoiceCueDecision evaluate(VoiceCueRequest request) {
    _pruneExpiredEvents();

    if (!request.voiceFeedbackEnabled) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.voiceFeedbackDisabled,
      );
    }
    if (!request.confirmed) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.unconfirmedEvent,
      );
    }
    if (!_clock().isBefore(request.expiresAt)) {
      return const VoiceCueDecision.blocked(VoiceCueBlockReason.expired);
    }
    if (request.cueId.trim().isEmpty ||
        request.eventId.trim().isEmpty ||
        request.semanticGroup.trim().isEmpty ||
        (request.route == VoiceCueRoute.conditional &&
            request.allowedOrigins != null &&
            request.allowedOrigins!.isEmpty)) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.invalidRequest,
      );
    }
    if (!_routeAllows(request.route, request.origin, request.allowedOrigins)) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.wrongWorkspace,
      );
    }

    final dedupeKey = _dedupeKey(request.eventId, request.semanticGroup);
    if (_spokenEventGroups.containsKey(dedupeKey)) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.duplicateEvent,
      );
    }

    // Reserve before playback. Release only if playback never starts.
    _spokenEventGroups[dedupeKey] = request.expiresAt;
    while (_spokenEventGroups.length > _maxRememberedEvents) {
      _spokenEventGroups.remove(_spokenEventGroups.keys.first);
    }
    return const VoiceCueDecision.allowed();
  }

  bool release({
    required String eventId,
    required String semanticGroup,
  }) {
    if (eventId.trim().isEmpty || semanticGroup.trim().isEmpty) return false;
    return _spokenEventGroups.remove(_dedupeKey(eventId, semanticGroup)) != null;
  }

  // Length-prefixing avoids collisions even if either caller-supplied value
  // contains the separator characters used by ordinary concatenation.
  String _dedupeKey(String eventId, String semanticGroup) =>
      '${eventId.length}:$eventId${semanticGroup.length}:$semanticGroup';

  bool _routeAllows(
    VoiceCueRoute route,
    VoiceCueOrigin origin,
    List<VoiceCueOrigin>? allowedOrigins,
  ) {
    switch (route) {
      case VoiceCueRoute.playerAuto:
        return origin == VoiceCueOrigin.playerAuto;
      case VoiceCueRoute.djManual:
        return origin == VoiceCueOrigin.djManual;
      case VoiceCueRoute.bothContextual:
        return origin != VoiceCueOrigin.sharedSystem;
      case VoiceCueRoute.conditional:
        return allowedOrigins?.contains(origin) ??
            origin != VoiceCueOrigin.sharedSystem;
      case VoiceCueRoute.sharedSystem:
        return origin == VoiceCueOrigin.sharedSystem;
    }
  }

  void _pruneExpiredEvents() {
    final now = _clock();
    _spokenEventGroups.removeWhere((_, expiresAt) => !now.isBefore(expiresAt));
  }

  void resetSession() => _spokenEventGroups.clear();
}
