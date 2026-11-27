import 'dart:async';

import 'package:flutter/foundation.dart';

/// Product workspace whose presentation and workspace-specific observers are active.
enum ResonateWorkspace { player, dj }

/// A long-lived service that needs to suspend/resume workspace-specific work.
abstract interface class WorkspaceLifecycleParticipant {
  FutureOr<void> onWorkspaceChanged(ResonateWorkspace workspace);
}

/// Serializes workspace transitions and gives app-level services one lifecycle
/// contract. Shared playback, DSP, audio focus and library analysis are not
/// participants unless they explicitly opt in.
class WorkspaceLifecycleCoordinator extends ChangeNotifier {
  ResonateWorkspace _active = ResonateWorkspace.player;
  Future<void> _transitionTail = Future<void>.value();
  final Set<WorkspaceLifecycleParticipant> _participants = {};
  bool _disposed = false;

  ResonateWorkspace get activeWorkspace => _active;
  bool get isPlayerActive => _active == ResonateWorkspace.player;
  bool get isDjActive => _active == ResonateWorkspace.dj;

  /// Registration is serialized with transitions. A participant registered
  /// during a switch receives the destination state after that switch settles.
  void register(WorkspaceLifecycleParticipant participant) {
    if (_disposed || !_participants.add(participant)) return;
    final operation = _transitionTail.then((_) async {
      if (_disposed || !_participants.contains(participant)) return;
      await participant.onWorkspaceChanged(_active);
    });
    _transitionTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        // A participant that cannot synchronize to the current workspace must
        // not remain registered and receive later transitions from an
        // unknown starting state. It can explicitly register again after its
        // own initialization/recovery has completed.
        _participants.remove(participant);
        debugPrint('Workspace participant initialization failed; unregistered: $error');
      },
    );
  }

  void unregister(WorkspaceLifecycleParticipant participant) {
    _participants.remove(participant);
  }

  Future<void> activate(ResonateWorkspace workspace) {
    final operation = _transitionTail.then((_) async {
      if (_disposed) return;
      if (_active == workspace) return;
      final participants = _participants.toList(growable: false);
      final previous = _active;
      final changed = <WorkspaceLifecycleParticipant>[];
      try {
        for (final participant in participants) {
          if (!_participants.contains(participant)) continue;
          changed.add(participant);
          await participant.onWorkspaceChanged(workspace);
        }
        if (_disposed) {
          // dispose() may run while an asynchronous participant is applying
          // the destination. Restore every participant already touched before
          // allowing the queued transition to settle.
          for (final participant in changed.reversed) {
            try {
              await participant.onWorkspaceChanged(previous);
            } catch (rollbackError) {
              debugPrint('Disposed workspace transition rollback failed: $rollbackError');
            }
          }
          return;
        }
        _active = workspace;
        notifyListeners();
      } catch (_) {
        // Roll back only participants that accepted the destination. Continue
        // best-effort so one failing participant cannot strand the others.
        for (final participant in changed.reversed) {
          if (!_participants.contains(participant)) continue;
          try {
            await participant.onWorkspaceChanged(previous);
          } catch (rollbackError) {
            debugPrint('Workspace participant rollback failed: $rollbackError');
          }
        }
        rethrow;
      }
    });
    _transitionTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    _participants.clear();
    super.dispose();
  }
}
