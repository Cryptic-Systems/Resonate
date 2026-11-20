import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/playback_control_arbiter.dart';

void main() {
  group('PlaybackControlArbiter', () {
    test('grants one owner and rejects equal or lower priority contenders', () async {
      final events = <PlaybackControlDiagnostic>[];
      final arbiter = PlaybackControlArbiter(onDiagnostic: events.add);

      final dj = await arbiter.acquire(
        owner: 'dj_autopilot',
        priority: PlaybackControlPriority.automatic,
      );
      expect(dj, isNotNull);
      expect(dj!.isCurrent, isTrue);
      expect(dj.authorizeWrite('set_deck_eq'), isTrue);

      final crossfade = await arbiter.acquire(
        owner: 'crossfade',
        priority: PlaybackControlPriority.automatic,
      );
      final background = await arbiter.acquire(
        owner: 'spectrum_monitor',
        priority: PlaybackControlPriority.background,
      );

      expect(crossfade, isNull);
      expect(background, isNull);
      expect(arbiter.activeOwner, 'dj_autopilot');
      expect(
        events.where((e) => e.type == PlaybackControlDiagnosticType.conflict),
        hasLength(2),
      );
      expect(await dj.release(), isTrue);
      expect(arbiter.activeOwner, isNull);
    });

    test('higher priority preemption invalidates old token before cleanup', () async {
      final arbiter = PlaybackControlArbiter();
      var cleanupSawCurrentLease = true;
      PlaybackControlRevocation? observedRevocation;

      late PlaybackControlLease automaticLease;
      automaticLease = (await arbiter.acquire(
        owner: 'dj_autopilot',
        priority: PlaybackControlPriority.automatic,
        onRevoked: (revocation) {
          cleanupSawCurrentLease = automaticLease.isCurrent;
          observedRevocation = revocation;
        },
      ))!;
      expect(automaticLease.isCurrent, isTrue);

      final manual = await arbiter.acquire(
        owner: 'user_transport',
        priority: PlaybackControlPriority.userTransport,
      );

      expect(manual, isNotNull);
      expect(cleanupSawCurrentLease, isFalse);
      expect(automaticLease!.isCurrent, isFalse);
      expect(automaticLease.authorizeWrite('late_crossfade_gain'), isFalse);
      expect(manual!.isCurrent, isTrue);
      expect(observedRevocation?.reason,
          PlaybackControlRevocationReason.preempted);
      expect(observedRevocation?.preemptedByOwner, 'user_transport');
      expect(arbiter.activeOwner, 'user_transport');
    });

    test('new owner waits for revoked owner cleanup to finish', () async {
      final arbiter = PlaybackControlArbiter();
      final cleanupGate = Completer<void>();
      var cleanupFinished = false;

      final automatic = await arbiter.acquire(
        owner: 'crossfade',
        priority: PlaybackControlPriority.automatic,
        onRevoked: (_) async {
          await cleanupGate.future;
          cleanupFinished = true;
        },
      );
      final manualFuture = arbiter.acquire(
        owner: 'user_transport',
        priority: PlaybackControlPriority.userTransport,
      );

      await Future<void>.delayed(Duration.zero);
      expect(cleanupFinished, isFalse);
      expect(arbiter.activeOwner, isNull);
      expect(automatic!.isCurrent, isFalse);

      cleanupGate.complete();
      final manual = await manualFuture;

      expect(cleanupFinished, isTrue);
      expect(manual, isNotNull);
      expect(arbiter.activeOwner, 'user_transport');
    });

    test('same owner renews without changing generation or callback', () async {
      final events = <PlaybackControlDiagnostic>[];
      final arbiter = PlaybackControlArbiter(onDiagnostic: events.add);
      var revoked = 0;

      final first = await arbiter.acquire(
        owner: 'dsp_profile',
        priority: PlaybackControlPriority.interactive,
        onRevoked: (_) => revoked++,
      );
      final generation = first!.generation;
      final second = await arbiter.acquire(
        owner: 'dsp_profile',
        priority: PlaybackControlPriority.interactive,
        onRevoked: (_) => fail('renewal must not replace cleanup callback'),
      );

      expect(identical(first, second), isFalse);
      expect(second!.generation, generation);
      expect(first.isCurrent, isTrue);
      expect(second.isCurrent, isTrue);
      expect(await first.release(), isTrue);
      expect(first.isCurrent, isFalse);
      expect(second.isCurrent, isTrue);
      expect(revoked, 0,
          reason: 'One controller hold must not revoke another active hold.');
      expect(await second.renew(), isTrue);
      expect(
        events.where((e) => e.type == PlaybackControlDiagnosticType.renewed),
        hasLength(2),
      );

      await second.release();
      expect(revoked, 1);
    });

    test('stale lease cannot release or write through a newer owner', () async {
      final arbiter = PlaybackControlArbiter();
      final oldLease = await arbiter.acquire(
        owner: 'automatic_dj',
        priority: PlaybackControlPriority.automatic,
      );
      final newLease = await arbiter.acquire(
        owner: 'manual_transport',
        priority: PlaybackControlPriority.userTransport,
      );

      expect(oldLease!.isCurrent, isFalse);
      expect(oldLease.authorizeWrite('set_master_gain'), isFalse);
      expect(await oldLease.release(), isFalse);
      expect(newLease!.isCurrent, isTrue);
      expect(arbiter.activeOwner, 'manual_transport');
    });

    test('cleanup failure is diagnosed without granting stale authority', () async {
      final events = <PlaybackControlDiagnostic>[];
      final arbiter = PlaybackControlArbiter(onDiagnostic: events.add);
      await arbiter.acquire(
        owner: 'automatic_dj',
        priority: PlaybackControlPriority.automatic,
        onRevoked: (_) => throw StateError('restore failed'),
      );

      final manual = await arbiter.acquire(
        owner: 'user_transport',
        priority: PlaybackControlPriority.userTransport,
      );

      expect(manual, isNotNull);
      expect(manual!.isCurrent, isTrue);
      expect(
        events.where((e) => e.type == PlaybackControlDiagnosticType.cleanupFailed),
        hasLength(1),
      );
    });

    test('close revokes the owner and rejects all future acquisitions', () async {
      final events = <PlaybackControlDiagnostic>[];
      final arbiter = PlaybackControlArbiter(onDiagnostic: events.add);
      var cleanupCalls = 0;
      final lease = await arbiter.acquire(
        owner: 'dsp_profile',
        priority: PlaybackControlPriority.interactive,
        onRevoked: (_) => cleanupCalls++,
      );

      await arbiter.close();
      await arbiter.close();

      expect(arbiter.isClosed, isTrue);
      expect(arbiter.activeOwner, isNull);
      expect(lease!.isCurrent, isFalse);
      expect(await lease.authorizeWrite('set_eq'), isFalse);
      expect(
        await arbiter.acquire(
          owner: 'user_transport',
          priority: PlaybackControlPriority.userTransport,
        ),
        isNull,
      );
      expect(cleanupCalls, 1);
      expect(
        events.where((e) => e.type == PlaybackControlDiagnosticType.closed),
        hasLength(1),
      );
    });

    test('diagnostic sink failures cannot interrupt arbitration', () async {
      final arbiter = PlaybackControlArbiter(
        onDiagnostic: (_) => throw StateError('telemetry unavailable'),
      );
      final first = await arbiter.acquire(
        owner: 'automatic_dj',
        priority: PlaybackControlPriority.automatic,
      );
      final manual = await arbiter.acquire(
        owner: 'user_transport',
        priority: PlaybackControlPriority.userTransport,
      );

      expect(first!.isCurrent, isFalse);
      expect(manual!.isCurrent, isTrue);
    });
  });
}
