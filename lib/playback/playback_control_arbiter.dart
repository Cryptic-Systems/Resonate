import 'dart:async';

/// Relative authority for controllers that can change live playback output.
///
/// A higher rank may revoke a lower-ranked lease. Equal-ranked controllers do
/// not silently replace one another; the current owner must release first.
enum PlaybackControlPriority {
  background(10),
  automatic(20),
  interactive(30),
  userTransport(100);

  const PlaybackControlPriority(this.rank);

  final int rank;
}

enum PlaybackControlRevocationReason {
  preempted,
  released,
  arbiterClosed,
}

enum PlaybackControlDiagnosticType {
  granted,
  renewed,
  released,
  revoked,
  conflict,
  writeAccepted,
  writeRejected,
  cleanupFailed,
  closed,
}

class PlaybackControlRevocation {
  const PlaybackControlRevocation({
    required this.reason,
    required this.generation,
    this.preemptedByOwner,
  });

  final PlaybackControlRevocationReason reason;
  final int generation;
  final String? preemptedByOwner;
}

class PlaybackControlDiagnostic {
  const PlaybackControlDiagnostic({
    required this.type,
    required this.generation,
    this.owner,
    this.priority,
    this.operation,
    this.otherOwner,
    this.reason,
  });

  final PlaybackControlDiagnosticType type;
  final int generation;
  final String? owner;
  final PlaybackControlPriority? priority;
  final String? operation;
  final String? otherOwner;
  final String? reason;
}

typedef PlaybackControlDiagnosticSink =
    void Function(PlaybackControlDiagnostic event);
typedef PlaybackControlRevocationHandler =
    FutureOr<void> Function(PlaybackControlRevocation revocation);

/// Process-local single-writer authority for live playback output controls.
///
/// Controllers may analyse, recommend, render UI, or prepare work without a
/// lease. They must hold the current lease and call [PlaybackControlLease
/// .authorizeWrite] immediately before dispatching any live-output mutation.
///
/// Revocation invalidates the token before awaiting owner cleanup. A new owner
/// is not granted until that cleanup callback settles. Since a MethodChannel or
/// native call already dispatched cannot be recalled, owners must re-check
/// [PlaybackControlLease.isCurrent] after every await and before each later
/// output write. Manual transport should acquire [PlaybackControlPriority
/// .userTransport] to preempt automatic controllers.
class PlaybackControlArbiter {
  PlaybackControlArbiter({PlaybackControlDiagnosticSink? onDiagnostic})
      : _onDiagnostic = onDiagnostic;

  final PlaybackControlDiagnosticSink? _onDiagnostic;

  PlaybackControlLease? _activeLease;
  int _activeLeaseReferences = 0;
  int _generation = 0;
  bool _closed = false;
  Future<void> _mutationTail = Future<void>.value();

  String? get activeOwner => _activeLease?.owner;
  PlaybackControlPriority? get activePriority => _activeLease?.priority;
  int get generation => _generation;
  bool get isClosed => _closed;

  /// Request exclusive authority. Higher priority preempts lower priority;
  /// equal/lower priority requests are denied to prevent controller flapping.
  ///
  /// Re-acquiring for the same owner and priority renews the existing token.
  /// The current owner must release before another equal-priority owner can
  /// acquire control.
  Future<PlaybackControlLease?> acquire({
    required String owner,
    required PlaybackControlPriority priority,
    PlaybackControlRevocationHandler? onRevoked,
  }) {
    final normalizedOwner = owner.trim();
    if (normalizedOwner.isEmpty) {
      throw ArgumentError.value(owner, 'owner', 'Must not be empty.');
    }

    return _serialize(() async {
      if (_closed) {
        _emit(PlaybackControlDiagnostic(
          type: PlaybackControlDiagnosticType.conflict,
          generation: _generation,
          owner: normalizedOwner,
          priority: priority,
          reason: 'arbiter_closed',
        ));
        return null;
      }

      final current = _activeLease;
      if (current != null && current.owner == normalizedOwner) {
        if (current.priority != priority) {
          _emit(PlaybackControlDiagnostic(
            type: PlaybackControlDiagnosticType.conflict,
            generation: _generation,
            owner: normalizedOwner,
            priority: priority,
            otherOwner: current.owner,
            reason: 'owner_priority_mismatch',
          ));
          return null;
        }
        _activeLeaseReferences++;
        final renewedLease = PlaybackControlLease._(
          arbiter: this,
          owner: current.owner,
          priority: current.priority,
          generation: current.generation,
          onRevoked: null,
        );
        _emit(PlaybackControlDiagnostic(
          type: PlaybackControlDiagnosticType.renewed,
          generation: current.generation,
          owner: current.owner,
          priority: current.priority,
        ));
        return renewedLease;
      }

      if (current != null && priority.rank <= current.priority.rank) {
        _emit(PlaybackControlDiagnostic(
          type: PlaybackControlDiagnosticType.conflict,
          generation: current.generation,
          owner: normalizedOwner,
          priority: priority,
          otherOwner: current.owner,
          reason: 'insufficient_priority',
        ));
        return null;
      }

      if (current != null) {
        await _revokeActive(
          current,
          reason: PlaybackControlRevocationReason.preempted,
          preemptedByOwner: normalizedOwner,
        );
      }

      if (_closed) return null;

      final lease = PlaybackControlLease._(
        arbiter: this,
        owner: normalizedOwner,
        priority: priority,
        generation: ++_generation,
        onRevoked: onRevoked,
      );
      _activeLease = lease;
      _activeLeaseReferences = 1;
      _emit(PlaybackControlDiagnostic(
        type: PlaybackControlDiagnosticType.granted,
        generation: lease.generation,
        owner: lease.owner,
        priority: lease.priority,
      ));
      return lease;
    });
  }

  /// Closes the arbiter and revokes its current owner after invalidating it.
  /// Future acquisitions are denied. Safe to call more than once.
  Future<void> close() => _serialize(() async {
        if (_closed) return;
        _closed = true;
        final current = _activeLease;
        if (current != null) {
          await _revokeActive(
            current,
            reason: PlaybackControlRevocationReason.arbiterClosed,
          );
        }
        _generation++;
        _emit(PlaybackControlDiagnostic(
          type: PlaybackControlDiagnosticType.closed,
          generation: _generation,
        ));
      });

  bool _owns(PlaybackControlLease lease) {
    final active = _activeLease;
    return !_closed &&
        !lease._released &&
        active != null &&
        lease.generation == _generation &&
        lease.generation == active.generation &&
        lease.owner == active.owner &&
        lease.priority == active.priority;
  }

  bool _authorizeWrite(PlaybackControlLease lease, String operation) {
    final allowed = _owns(lease);
    _emit(PlaybackControlDiagnostic(
      type: allowed
          ? PlaybackControlDiagnosticType.writeAccepted
          : PlaybackControlDiagnosticType.writeRejected,
      generation: lease.generation,
      owner: lease.owner,
      priority: lease.priority,
      operation: operation,
      reason: allowed ? null : 'lease_not_current',
    ));
    return allowed;
  }

  Future<bool> _renew(PlaybackControlLease lease) => _serialize(() async {
        if (!_owns(lease)) {
          _emit(PlaybackControlDiagnostic(
            type: PlaybackControlDiagnosticType.conflict,
            generation: lease.generation,
            owner: lease.owner,
            priority: lease.priority,
            reason: 'stale_renewal',
          ));
          return false;
        }
        _emit(PlaybackControlDiagnostic(
          type: PlaybackControlDiagnosticType.renewed,
          generation: lease.generation,
          owner: lease.owner,
          priority: lease.priority,
        ));
        return true;
      });

  Future<bool> _release(PlaybackControlLease lease) => _serialize(() async {
        if (!_owns(lease)) {
          lease._markReleased();
          _emit(PlaybackControlDiagnostic(
            type: PlaybackControlDiagnosticType.conflict,
            generation: lease.generation,
            owner: lease.owner,
            priority: lease.priority,
            reason: 'stale_release',
          ));
          return false;
        }
        lease._markReleased();
        if (_activeLeaseReferences > 0) _activeLeaseReferences--;
        _emit(PlaybackControlDiagnostic(
          type: PlaybackControlDiagnosticType.released,
          generation: lease.generation,
          owner: lease.owner,
          priority: lease.priority,
          reason: _activeLeaseReferences > 0 ? 'shared_hold_released' : 'final_hold_released',
        ));
        if (_activeLeaseReferences > 0) return true;
        final active = _activeLease!;
        await _revokeActive(
          active,
          reason: PlaybackControlRevocationReason.released,
        );
        return true;
      });

  Future<void> _revokeActive(
    PlaybackControlLease lease, {
    required PlaybackControlRevocationReason reason,
    String? preemptedByOwner,
  }) async {
    if (!identical(_activeLease, lease)) return;

    // Invalidate first. Cleanup code can never authorize another live write.
    _activeLease = null;
    _activeLeaseReferences = 0;
    lease._markReleased();
    final revokedGeneration = lease.generation;
    _generation++;
    _emit(PlaybackControlDiagnostic(
      type: PlaybackControlDiagnosticType.revoked,
      generation: revokedGeneration,
      owner: lease.owner,
      priority: lease.priority,
      otherOwner: preemptedByOwner,
      reason: reason.name,
    ));

    try {
      await lease._notifyRevoked(PlaybackControlRevocation(
        reason: reason,
        generation: revokedGeneration,
        preemptedByOwner: preemptedByOwner,
      ));
    } catch (error) {
      _emit(PlaybackControlDiagnostic(
        type: PlaybackControlDiagnosticType.cleanupFailed,
        generation: revokedGeneration,
        owner: lease.owner,
        priority: lease.priority,
        otherOwner: preemptedByOwner,
        reason: error.toString(),
      ));
    }
  }

  void _emit(PlaybackControlDiagnostic event) {
    try {
      _onDiagnostic?.call(event);
    } catch (_) {
      // Diagnostics must never interfere with playback ownership.
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}

/// Revocable capability to mutate live playback output.
///
/// The generation is immutable. Once revoked, this lease can never become
/// current again; a later acquisition always receives a new generation.
class PlaybackControlLease {
  PlaybackControlLease._({
    required PlaybackControlArbiter arbiter,
    required this.owner,
    required this.priority,
    required this.generation,
    required PlaybackControlRevocationHandler? onRevoked,
  })  : _arbiter = arbiter,
        _onRevoked = onRevoked;

  final PlaybackControlArbiter _arbiter;
  final PlaybackControlRevocationHandler? _onRevoked;

  final String owner;
  final PlaybackControlPriority priority;
  final int generation;
  bool _released = false;

  bool get isCurrent => _arbiter._owns(this);

  void _markReleased() {
    _released = true;
  }

  /// Authorize one immediate live-output write. Call again after every await.
  bool authorizeWrite(String operation) {
    final name = operation.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(operation, 'operation', 'Must not be empty.');
    }
    return _arbiter._authorizeWrite(this, name);
  }

  /// Explicitly renews the current lease without changing its generation.
  Future<bool> renew() => _arbiter._renew(this);

  /// Releases this lease. Stale leases cannot release a newer owner's lease.
  Future<bool> release() => _arbiter._release(this);

  Future<void> _notifyRevoked(PlaybackControlRevocation revocation) async {
    await _onRevoked?.call(revocation);
  }
}
