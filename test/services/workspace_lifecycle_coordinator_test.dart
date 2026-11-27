import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/services/workspace_lifecycle_coordinator.dart';

class _Participant implements WorkspaceLifecycleParticipant {
  final List<ResonateWorkspace> transitions = [];
  bool failOnDj = false;
  Completer<void>? djGate;

  @override
  Future<void> onWorkspaceChanged(ResonateWorkspace workspace) async {
    transitions.add(workspace);
    if (workspace == ResonateWorkspace.dj && djGate != null) {
      await djGate!.future;
    }
    if (failOnDj && workspace == ResonateWorkspace.dj) {
      throw StateError('synthetic lifecycle failure');
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

  test('participant registered during a transition receives the settled destination', () async {
    final coordinator = WorkspaceLifecycleCoordinator();
    final blocker = _Participant()..djGate = Completer<void>();
    coordinator.register(blocker);
    await coordinator.activate(ResonateWorkspace.player);

    final switching = coordinator.activate(ResonateWorkspace.dj);
    await Future<void>.delayed(Duration.zero);
    final lateParticipant = _Participant();
    coordinator.register(lateParticipant);

    blocker.djGate!.complete();
    await switching;
    await coordinator.activate(ResonateWorkspace.dj);

    expect(lateParticipant.transitions, [ResonateWorkspace.dj]);
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
}
