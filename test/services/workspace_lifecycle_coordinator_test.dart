import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/services/workspace_lifecycle_coordinator.dart';

class _Participant implements WorkspaceLifecycleParticipant {
  final List<ResonateWorkspace> transitions = [];
  bool failOnDj = false;
  bool failOnPlayer = false;

  @override
  Future<void> onWorkspaceChanged(ResonateWorkspace workspace) async {
    transitions.add(workspace);
    if ((failOnDj && workspace == ResonateWorkspace.dj) ||
        (failOnPlayer && workspace == ResonateWorkspace.player)) {
      throw StateError('synthetic lifecycle failure');
    }
  }
}

 
class _BlockingParticipant implements WorkspaceLifecycleParticipant {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  final List<ResonateWorkspace> transitions = [];

  @override
  Future<void> onWorkspaceChanged(ResonateWorkspace workspace) async {
    transitions.add(workspace);
    if (workspace == ResonateWorkspace.dj) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
  }
}

class _FailOnceParticipant implements WorkspaceLifecycleParticipant {
  bool failNextDj = true;
  final List<ResonateWorkspace> transitions = [];

  @override
  Future<void> onWorkspaceChanged(ResonateWorkspace workspace) async {
    transitions.add(workspace);
    if (workspace == ResonateWorkspace.dj && failNextDj) {
      failNextDj = false;
      throw StateError('one-time lifecycle failure');
    }
  }
}

void main() {
  test('switches workspace and notifies registered participants', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant();
    coordinator.register(participant);

    await coordinator.activate(ResonateWorkspace.dj);

    expect(coordinator.activeWorkspace, ResonateWorkspace.dj);
    expect(participant.transitions, [
      ResonateWorkspace.player,
      ResonateWorkspace.dj,
    ]);
  });

  test('repeated activation of the current workspace is idempotent', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant();
    coordinator.register(participant);

    await coordinator.activate(ResonateWorkspace.player);
    await coordinator.activate(ResonateWorkspace.player);

    expect(participant.transitions, [ResonateWorkspace.player]);
  });

  test('serializes rapid transitions and leaves the final destination active',
      () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant();
    coordinator.register(participant);

    final toDj = coordinator.activate(ResonateWorkspace.dj);
    final toPlayer = coordinator.activate(ResonateWorkspace.player);
    await Future.wait([toDj, toPlayer]);

    expect(coordinator.activeWorkspace, ResonateWorkspace.player);
    expect(participant.transitions.last, ResonateWorkspace.player);
  });

  test('restores prior participant state when a transition fails', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant()..failOnDj = true;
    coordinator.register(participant);

    await expectLater(
      coordinator.activate(ResonateWorkspace.dj),
      throwsStateError,
    );

    expect(coordinator.activeWorkspace, ResonateWorkspace.player);
    expect(participant.transitions.last, ResonateWorkspace.player);
  });

  test('late participant receives the current settled workspace', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    await coordinator.activate(ResonateWorkspace.dj);
    final participant = _Participant();
    coordinator.register(participant);

    // This same-destination activation waits behind the queued registration.
    await coordinator.activate(ResonateWorkspace.dj);

    expect(participant.transitions, [ResonateWorkspace.dj]);
  });

  test('participant failure after partial application is rolled back', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant()..failOnDj = true;
    coordinator.register(participant);

    await expectLater(
      coordinator.activate(ResonateWorkspace.dj),
      throwsStateError,
    );

    expect(participant.transitions.last, ResonateWorkspace.player);
    expect(coordinator.activeWorkspace, ResonateWorkspace.player);
  });

  test('unregistered participants receive no later transitions', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant();
    coordinator.register(participant);
    coordinator.unregister(participant);

    await coordinator.activate(ResonateWorkspace.dj);

    expect(participant.transitions, isEmpty);
  });

  test('dispose during an in-flight transition rolls participants back', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _BlockingParticipant();
    coordinator.register(participant);
    await coordinator.activate(ResonateWorkspace.player);

    final transition = coordinator.activate(ResonateWorkspace.dj);
    await participant.entered.future;
    coordinator.dispose();
    participant.release.complete();
    await transition;

    expect(coordinator.activeWorkspace, ResonateWorkspace.player);
    expect(participant.transitions, [
      ResonateWorkspace.player,
      ResonateWorkspace.dj,
      ResonateWorkspace.player,
    ]);
  });

  test('transition queue recovers after a participant failure', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _FailOnceParticipant();
    coordinator.register(participant);
    await coordinator.activate(ResonateWorkspace.player);

    await expectLater(
      coordinator.activate(ResonateWorkspace.dj),
      throwsStateError,
    );
    await coordinator.activate(ResonateWorkspace.dj);

    expect(coordinator.activeWorkspace, ResonateWorkspace.dj);
    expect(participant.transitions, [
      ResonateWorkspace.player,
      ResonateWorkspace.dj,
      ResonateWorkspace.player,
      ResonateWorkspace.dj,
    ]);
  });

  test('participant that fails initial synchronization is unregistered', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final participant = _Participant()..failOnPlayer = true;

    // Registration initialization is serialized before this activation.
    coordinator.register(participant);
    await coordinator.activate(ResonateWorkspace.player);
    await coordinator.activate(ResonateWorkspace.dj);
    await coordinator.activate(ResonateWorkspace.player);

    expect(participant.transitions, [ResonateWorkspace.player]);
    expect(coordinator.activeWorkspace, ResonateWorkspace.player);
  });
}
