import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonate/providers/audio_effects_provider.dart';
import 'package:resonate/services/playback_engine_session.dart';
import 'package:resonate/services/media3_provider_state_bridge.dart';

class _FakePlaybackSession implements PlaybackEngineSession {
  final StreamController<int?> _audioSessionIds =
      StreamController<int?>.broadcast(sync: true);
  final StreamController<Media3ProviderState> _states =
      StreamController<Media3ProviderState>.broadcast(sync: true);

  @override
  Stream<int?> get audioSessionIdStream => _audioSessionIds.stream;
  @override
  Stream<Media3ProviderState> get stateStream => _states.stream;

  void emitState(int? active, [int? standby]) {
    _states.add(Media3ProviderState(
      currentSong: null,
      queueIndex: null,
      isPlaying: false,
      position: Duration.zero,
      duration: null,
      connected: true,
      isReady: false,
      playWhenReady: false,
      mediaId: null,
      queueLength: 0,
      volume: 1.0,
      audioSessionId: active,
      standbyAudioSessionId: standby,
      hasError: false,
      error: null,
    ));
  }

  Future<void> close() async {
    await _audioSessionIds.close();
    await _states.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const effectsChannel =
      MethodChannel('com.aetherion.resonate/audio_effects');
  final calls = <MethodCall>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(effectsChannel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(effectsChannel, null);
  });

  Future<void> settleProvider(AudioEffectsProvider provider) async {
    // Let the stream callback's queued native work settle without issuing a
    // second settings mutation (which would itself trigger another attach).
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('Media3 effects stay attached to both decks through promotion',
      () async {
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(
      playbackSession: session,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    calls.clear();

    session.emitState(301);
    await settleProvider(provider);
    expect(
      calls.where((call) => call.method == 'attachToSession').map(
            (call) => (call.arguments as Map)['sessionId'],
          ),
      contains(301),
    );

    calls.clear();
    session.emitState(301, 302);
    await settleProvider(provider);
    expect(
      calls.where((call) => call.method == 'attachToSession').map(
            (call) => (call.arguments as Map)['sessionId'],
          ),
      contains(302),
    );
    expect(
      calls.where((call) => call.method == 'detachFromSession'),
      isEmpty,
      reason: 'the outgoing deck remains a live session during the overlap',
    );

    calls.clear();
    session.emitState(302, 301);
    await settleProvider(provider);
    expect(calls, isEmpty,
        reason: 'promotion must not detach or redundantly reattach either deck');

    calls.clear();
    session.emitState(302);
    await settleProvider(provider);
    expect(
      calls.any((call) =>
          call.method == 'detachFromSession' &&
          (call.arguments as Map)['sessionId'] == 301),
      isTrue,
    );

    calls.clear();
    session.emitState(null);
    await settleProvider(provider);
    expect(
      calls.any((call) =>
          call.method == 'detachFromSession' &&
          (call.arguments as Map)['sessionId'] == 302),
      isTrue,
    );

    provider.dispose();
    await session.close();
  });

  test('Media3 session owns effects without constructing legacy players', () async {
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(playbackSession: session);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    calls.clear();

    session.emitState(601, 602);
    await settleProvider(provider);

    expect(
      calls.where((call) => call.method == 'attachToSession').map(
            (call) => (call.arguments as Map)['sessionId'],
          ),
      containsAll([601, 602]),
      reason: 'Media3 must own effects on both physical decks, not legacy players',
    );

    provider.dispose();
    await session.close();
  });

  test('repeated Media3 session IDs do not cause redundant reattachment',
      () async {
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(
      playbackSession: session,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    session.emitState(411);
    await settleProvider(provider);
    calls.clear();

    session.emitState(411);
    await settleProvider(provider);

    expect(
      calls.where((call) => call.method == 'attachToSession'),
      isEmpty,
    );

    provider.dispose();
    await session.close();
  });

  test('disposing provider cancels Media3 session observation', () async {
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(
      playbackSession: session,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    provider.dispose();
    calls.clear();
    session.emitState(512);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      calls.where((call) => call.method == 'attachToSession'),
      isEmpty,
    );
    await session.close();
  });
}
