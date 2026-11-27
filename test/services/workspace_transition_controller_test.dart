import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/services/workspace_lifecycle_coordinator.dart';
import 'package:resonate/services/workspace_transition_controller.dart';

void main() {
  group('WorkspaceTransitionController', () {
    test('keeps the barrier active until the destination reports ready',
        () async {
      final controller = WorkspaceTransitionController();
      var handoffCompleted = false;

      final transition = controller.transitionTo(
        ResonateWorkspace.player,
        performHandoff: () async {
          handoffCompleted = true;
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(handoffCompleted, isTrue);
      expect(controller.isTransitioning, isTrue);
      expect(controller.destination, ResonateWorkspace.player);

      controller.markReady(ResonateWorkspace.dj);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isTransitioning, isTrue);

      controller.markReady(ResonateWorkspace.player);
      await transition;

      expect(controller.isTransitioning, isFalse);
      expect(controller.destination, isNull);
      controller.dispose();
    });

    test('serializes rapid workspace handoff requests', () async {
      final controller = WorkspaceTransitionController();
      final firstReady = Completer<void>();
      final events = <String>[];

      final first = controller.transitionTo(
        ResonateWorkspace.player,
        performHandoff: () async {
          events.add('player-start');
          await firstReady.future;
          events.add('player-handoff');
        },
      );
      final second = controller.transitionTo(
        ResonateWorkspace.dj,
        performHandoff: () async {
          events.add('dj-start');
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(events, ['player-start']);
      firstReady.complete();
      controller.markReady(ResonateWorkspace.player);
      await first;

      await Future<void>.delayed(Duration.zero);
      expect(events, ['player-start', 'player-handoff', 'dj-start']);
      controller.markReady(ResonateWorkspace.dj);
      await second;

      expect(controller.isTransitioning, isFalse);
      controller.dispose();
    });

    test('clears the barrier when handoff preparation fails', () async {
      final controller = WorkspaceTransitionController();

      await expectLater(
        controller.transitionTo(
          ResonateWorkspace.player,
          performHandoff: () async {
            throw StateError('synthetic handoff failure');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(controller.isTransitioning, isFalse);
      expect(controller.destination, isNull);
      controller.dispose();
    });
  });
}
