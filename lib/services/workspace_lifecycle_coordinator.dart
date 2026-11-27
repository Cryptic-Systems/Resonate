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

  ResonateWorkspace get activeWorkspace => _active;
  bool get isPlayerActive => _active == ResonateWorkspace.player;
  bool get isDjActive => _active == ResonateWorkspace.dj;

  void register(WorkspaceLifecycleParticipant participant) {
    _participants.add(participant);
    unawaited(Future<void>.sync(() => participant.onWorkspaceChanged(_active))
        .catchError((Object error) {
      debugPrint('Workspace participant initialization failed: $error');
    }));
  }

  void unregister(WorkspaceLifecycleParticipant participant) {
    _participants.remove(participant);
  }

  Future<void> activate(ResonateWorkspace workspace) {
    final transition = _transitionTail.then((_) async {
      if (_active == workspace) {
        // Reconcile late-registered participants without restarting services.
        for (final participant in _participants.toList(growable: false)) {
          await participant.onWorkspaceChanged(workspace);
        }
        return;
      }
      final participants = _participants.toList(growable: false);
      // Suspend/activate is represented as one idempotent destination update.
      // If a participant fails, keep the previous workspace authoritative and
      // restore participants to it before surfacing the failure.
      try {
        for (final participant in participants) {
          await participant.onWorkspaceChanged(workspace);
        }
        _active = workspace;
        notifyListeners();
      } catch (_) {
        for (final participant in participants) {
          try {
            await participant.onWorkspaceChanged(_active);
          } catch (_) {}
        }
        rethrow;
      }
    });
    _transitionTail = transition.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return transition;
  }
}
