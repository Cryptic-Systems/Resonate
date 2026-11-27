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
    this.allowedOrigins,
  });

  /// Stable manifest ID. Never use a source filename as the runtime lookup key.
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

  /// Optional explicit origin allow-list for conditional cues (e.g. mode
  /// announcements valid after a shared setting change as well as Player).
  /// Other route types keep their fixed origin rules.
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

/// Small, deterministic eligibility and duplicate-suppression layer for voice
/// feedback. Caller supplies time, so expiry behavior is straightforward to
/// test and does not depend on timers or a background service.
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

    // This is a reservation. If playback never starts (for example, the music
    // state changed or the audio focus request was denied), the caller must
    // release it. Once speech starts, keep it to suppress duplicate variants.
    _spokenEventGroups[dedupeKey] = request.expiresAt;
    while (_spokenEventGroups.length > _maxRememberedEvents) {
      _spokenEventGroups.remove(_spokenEventGroups.keys.first);
    }
    return const VoiceCueDecision.allowed();
  }

  /// Releases a reservation when the cue was accepted but did not start.
  ///
  /// Do not call after audible playback begins; keeping the reservation then
  /// prevents duplicate phrases for the same semantic event.
  bool release({
    required String eventId,
    required String semanticGroup,
  }) {
    if (eventId.trim().isEmpty || semanticGroup.trim().isEmpty) return false;
    return _spokenEventGroups.remove(_dedupeKey(eventId, semanticGroup)) != null;
  }

  String _dedupeKey(String eventId, String semanticGroup) =>
      '${eventId}::${semanticGroup}';

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

  /// Clears dedupe state at the start of a new app/session lifecycle.
  void resetSession() => _spokenEventGroups.clear();
}
