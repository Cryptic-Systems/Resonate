import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/playback/playback_control_arbiter.dart';
import 'package:resonate/services/audio_effects_bridge.dart';
import 'package:resonate/services/audio_output_route.dart';
import 'package:resonate/services/equalizer_dvc_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.aetherion.resonate/audio_effects');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, dynamic>{'active': true};
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('route safety override waits for transition cleanup before DSP writes',
      () async {
    final arbiter = PlaybackControlArbiter();
    final cleanupGate = Completer<void>();
    var cleanupStarted = false;
    await arbiter.acquire(
      owner: 'dj_transition',
      priority: PlaybackControlPriority.automatic,
      onRevoked: (_) async {
        cleanupStarted = true;
        await cleanupGate.future;
      },
    );

    final update = syncSpeakerPolicy(
      needsSpeakerProtection: true,
      virtualBassAmount: 0.6,
      route: AudioOutputRoute.builtInSpeaker,
      arbiter: arbiter,
    );
    for (var attempt = 0; attempt < 100 && !cleanupStarted; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    expect(cleanupStarted, isTrue);
    expect(arbiter.activeOwner, isNull);
    expect(calls, isEmpty);

    cleanupGate.complete();
    await update;

    expect(
      calls.map((call) => call.method),
      containsAll(['setLiveDspSpeakerMode', 'setLiveDspVirtualBass']),
    );
    expect(arbiter.activeOwner, isNull);
    await arbiter.close();
  });

  test('background DSP synchronization does not preempt a DJ transition',
      () async {
    final arbiter = PlaybackControlArbiter();
    final transition = await arbiter.acquire(
      owner: 'dj_transition',
      priority: PlaybackControlPriority.automatic,
    );

    await syncStudioBandsToNativeEq(
      centersHz: const [60, 250, 1000, 4000, 12000],
      gainsDb: const [0, 0, 0, 0, 0],
      enabled: true,
      arbiter: arbiter,
      priority: PlaybackControlPriority.background,
    );

    expect(calls, isEmpty);
    expect(arbiter.activeOwner, 'dj_transition');
    expect(transition!.isCurrent, isTrue);

    await transition.release();
    await arbiter.close();
  });
}
