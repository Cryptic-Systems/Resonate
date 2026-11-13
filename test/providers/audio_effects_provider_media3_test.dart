import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonate/providers/audio_effects_provider.dart';
import 'package:resonate/services/playback_engine_session.dart';

class _FakePlaybackSession implements PlaybackEngineSession {
  final StreamController<int?> _audioSessionIds =
      StreamController<int?>.broadcast(sync: true);

  @override
  Stream<int?> get audioSessionIdStream => _audioSessionIds.stream;

  void emitSessionId(int? id) => _audioSessionIds.add(id);

  Future<void> close() => _audioSessionIds.close();

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

  test('Media3 active-session handoff detaches old and attaches new ID',
      () async {
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(
      sessionPlayers: const [],
      playbackSession: session,
    );
    // Let asynchronous preference restoration finish before asserting calls.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    calls.clear();

    session.emitSessionId(301);
    await settleProvider(provider);
    expect(
      calls.where((call) => call.method == 'attachToSession').map(
            (call) => (call.arguments as Map)['sessionId'],
          ),
      contains(301),
    );

    calls.clear();
    session.emitSessionId(302);
    await settleProvider(provider);

    final detachIndex = calls.indexWhere(
      (call) =>
          call.method == 'detachFromSession' &&
          (call.arguments as Map)['sessionId'] == 301,
    );
    final attachIndex = calls.indexWhere(
      (call) =>
          call.method == 'attachToSession' &&
          (call.arguments as Map)['sessionId'] == 302,
    );
    expect(detachIndex, isNonNegative);
    expect(attachIndex, greaterThan(detachIndex));

    calls.clear();
    session.emitSessionId(null);
    await settleProvider(provider);
    expect(
      calls.any(
        (call) =>
            call.method == 'detachFromSession' &&
            (call.arguments as Map)['sessionId'] == 302,
      ),
      isTrue,
    );

    provider.dispose();
    await session.close();
  });

  test('Media3 session exclusively owns effects when legacy players are supplied', () async {
    final legacyPlayer = AudioPlayer();
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(
      player: legacyPlayer,
      sessionPlayers: <AudioPlayer>[legacyPlayer],
      playbackSession: session,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    calls.clear();

    session.emitSessionId(601);
    await settleProvider(provider);

    expect(
      calls.where((call) => call.method == 'attachToSession').map(
            (call) => (call.arguments as Map)['sessionId'],
          ),
      [601],
      reason: 'the active Media3 session must be the only effects attachment target',
    );

    provider.dispose();
    await legacyPlayer.dispose();
    await session.close();
  });

  test('repeated Media3 session IDs do not cause redundant reattachment',
      () async {
    final session = _FakePlaybackSession();
    final provider = AudioEffectsProvider(
      sessionPlayers: const [],
      playbackSession: session,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    session.emitSessionId(411);
    await settleProvider(provider);
    calls.clear();

    session.emitSessionId(411);
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
      sessionPlayers: const [],
      playbackSession: session,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    provider.dispose();
    calls.clear();
    session.emitSessionId(512);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      calls.where((call) => call.method == 'attachToSession'),
      isEmpty,
    );
    await session.close();
  });
}
