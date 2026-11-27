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
  duplicateEvent,
}

/// A request to speak a cue. This policy deliberately does not own an audio
/// player: it decides whether the event is eligible before a playback layer
/// resolves the stable cue ID to an asset.
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
  });

  final String cueId;
  final VoiceCueRoute route;
  final VoiceCueOrigin origin;

  /// Stable ID for the event that caused the cue (transition, queue update,
  /// deck action, etc.). Multiple phrase variants share this ID.
  final String eventId;

  /// Mutually exclusive phrase family, e.g. transition_praise or acknowledgement.
  final String semanticGroup;
  final bool voiceFeedbackEnabled;
  final bool confirmed;
  final DateTime expiresAt;
}

class VoiceCueDecision {
  const VoiceCueDecision.allowed()
      : allowed = true,
        reason = null;

  const VoiceCueDecision.blocked(this.reason) : allowed = false;

  final bool allowed;
  final VoiceCueBlockReason? reason;
}

/// Small, deterministic eligibility and duplicate-suppression layer for voice
/// feedback. Caller supplies time, so expiry behavior is straightforward to
/// test and does not depend on timers or a background service.
class VoiceCueRouter {
  VoiceCueRouter({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  static const int _maxRememberedEvents = 512;\n  final LinkedHashMap<String, DateTime> _spokenEventGroups =\n      LinkedHashMap<String, DateTime>();

  VoiceCueDecision evaluate(VoiceCueRequest request) {
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

    if (!_routeAllows(request.route, request.origin)) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.wrongWorkspace,
      );
    }

    final dedupeKey = '${request.eventId}::${request.semanticGroup}';
    if (_spokenEventGroups.contains(dedupeKey)) {
      return const VoiceCueDecision.blocked(
        VoiceCueBlockReason.duplicateEvent,
      );
    }

    _spokenEventGroups.add(dedupeKey);
    return const VoiceCueDecision.allowed();
  }

  bool _routeAllows(VoiceCueRoute route, VoiceCueOrigin origin) {
    switch (route) {
      case VoiceCueRoute.playerAuto:
        return origin == VoiceCueOrigin.playerAuto;
      case VoiceCueRoute.djManual:
        return origin == VoiceCueOrigin.djManual;
      case VoiceCueRoute.bothContextual:
      case VoiceCueRoute.conditional:
        return origin != VoiceCueOrigin.sharedSystem;
      case VoiceCueRoute.sharedSystem:
        return origin == VoiceCueOrigin.sharedSystem;
    }
  }

  /// Clears dedupe state at the start of a new app/session lifecycle.
  void resetSession() => _spokenEventGroups.clear();
}
