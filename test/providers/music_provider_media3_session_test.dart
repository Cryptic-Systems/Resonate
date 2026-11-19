import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/playback/queue_store.dart';
import 'package:resonate/providers/music_provider.dart';
import 'package:resonate/providers/crossfade_provider.dart';
import 'package:resonate/providers/playback_features_provider.dart';
import 'package:resonate/services/audio_service_handler.dart';
import 'package:resonate/services/playback_backend.dart';
import 'package:resonate/services/playback_engine_session.dart';
import 'package:resonate/services/media3_provider_state_bridge.dart';

Song _song(String id) => Song(
      id: id,
      title: id,
      artist: 'Artist',
      album: 'Album',
      filePath: '/music/$id.mp3',
      duration: const Duration(minutes: 3),
      dateAdded: DateTime.utc(2026, 1, 1),
    );


Media3ProviderState _state({
  required Song song,
  required int queueIndex,
  bool playing = false,
  bool buffering = false,
  bool completed = false,
  bool playWhenReady = false,
  Duration position = Duration.zero,
  String activeDeckId = 'A',
  String crossfadeStatus = 'idle',
  String repeatMode = 'off',
}) => Media3ProviderState(
      currentSong: song,
      queueIndex: queueIndex,
      isPlaying: playing,
      position: position,
      bufferedPosition: position,
      isBuffering: buffering,
      isCompleted: completed,
      duration: song.duration,
      connected: true,
      isReady: true,
      playWhenReady: playWhenReady,
      mediaId: song.id,
      queueLength: queueIndex + 1,
      volume: 1.0,
      activeDeckId: activeDeckId,
      crossfadeStatus: crossfadeStatus,
      repeatMode: repeatMode,
      hasError: false,
      error: null,
    );

class _FakePlaybackSession implements PlaybackEngineSession {
  _FakePlaybackSession({bool synchronousStates = false})
      : states = StreamController<Media3ProviderState>.broadcast(
          sync: synchronousStates,
        );

  final StreamController<int?> audioSessions =
      StreamController<int?>.broadcast();
  final List<String> calls = <String>[];
  final StreamController<Media3ProviderState> states;
  List<Song> queue = <Song>[];
  int? loadedIndex;
  PlaybackQueueRepeatMode? repeatModeSet;
  bool? shuffleModeSet;
  double? volumeSet;
  bool? focusHandling;
  Completer<void>? focusEnableGate;
  Completer<void>? startGate;
  Map<String, double?>? gainFactors;
  Song? preloadedSong;
  int? preloadedIndex;
  Duration? preloadedStartPosition;
  Duration? crossfadeDuration;
  (double, double)? deckSpeeds;
  bool disposed = false;
  bool throwOnCrossfade = false;
  bool throwOnPreloadNext = false;
  bool throwOnDeckSpeedOnce = false;
  bool throwOnClearDeckEqOverlay = false;
  bool deferLoadQueueState = false;
  Completer<void>? cancelCrossfadeGate;
  Completer<void>? preloadNextGate;
  Song? currentSongValue;
  int? queueIndexValue;
  bool playingValue = false;
  bool readyValue = true;
  bool completedValue = false;
  String crossfadeStatusValue = 'idle';
  bool emitIncomingErrorOnCrossfade = false;
  String activeDeckIdValue = 'A';
  Duration positionValue = Duration.zero;
  Duration? durationValue;
  double playbackSpeedValue = 1.0;

  @override
  Stream<int?> get audioSessionIdStream => audioSessions.stream;
  @override
  Song? get currentSong => currentSongValue;
  @override
  int? get queueIndex => queueIndexValue;
  @override
  bool get isPlaying => playingValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get bufferedPosition => positionValue;
  @override
  Duration? get duration => durationValue;
  @override
  bool get isBuffering => false;
  @override
  String get crossfadeStatus => crossfadeStatusValue;
  @override
  bool get isCompleted => completedValue;
  @override
  bool get isReady => readyValue;
  @override
  bool get hasError => false;
  @override
  String? get error => null;
  @override
  double get volume => volumeSet ?? 1.0;
  @override
  double get playbackSpeed => playbackSpeedValue;
  @override
  PlaybackQueueRepeatMode get repeatMode => repeatModeSet ?? PlaybackQueueRepeatMode.off;
  @override
  bool get shuffleModeEnabled => shuffleModeSet ?? false;

  @override
  Stream<Media3ProviderState> get stateStream => states.stream;

  @override
  Future<void> start() async {
    calls.add('start');
    final gate = startGate;
    if (gate != null) {
      startGate = null;
      await gate.future;
    }
  }

  @override
  Future<void> setAudioFocusHandling(bool enabled) async {
    calls.add('focus:$enabled');
    if (enabled && focusEnableGate != null) {
      final gate = focusEnableGate!;
      focusEnableGate = null;
      await gate.future;
    }
    focusHandling = enabled;
  }

  @override
  Future<void> loadQueue(List<Song> songs, {int startIndex = 0}) async {
    queue = List<Song>.of(songs);
    loadedIndex = startIndex;
    if (!deferLoadQueueState) {
      currentSongValue = songs.isEmpty ? null : songs[startIndex];
      queueIndexValue = songs.isEmpty ? null : startIndex;
      durationValue = currentSongValue?.duration;
      positionValue = Duration.zero;
    }
    calls.add('loadQueue');
  }

  @override
  Future<void> play() async { playingValue = true; completedValue = false; calls.add('play'); }
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeedValue = speed;
    calls.add('speed:$speed');
  }
  @override
  Future<void> pause() async { playingValue = false; calls.add('pause'); }
  @override
  Future<void> stop() async { playingValue = false; calls.add('stop'); }
  @override
  Future<void> seek(Duration position) async { positionValue = position; calls.add('seek:${position.inMilliseconds}'); }
  @override
  Future<void> next() async { if (queueIndexValue != null && queueIndexValue! < queue.length - 1) { queueIndexValue = queueIndexValue! + 1; currentSongValue = queue[queueIndexValue!]; } calls.add('next'); }
  @override
  Future<void> previous() async { if (queueIndexValue != null && queueIndexValue! > 0) { queueIndexValue = queueIndexValue! - 1; currentSongValue = queue[queueIndexValue!]; } calls.add('previous'); }
  @override
  Future<void> synchronizeQueue(List<Song> songs) async { queue = List<Song>.of(songs); calls.add('synchronizeQueue'); }

  @override
  Future<void> clearQueue() async {
    queue = <Song>[];
    loadedIndex = null;
    calls.add('clearQueue');
  }

  @override
  Future<void> setRepeatMode(PlaybackQueueRepeatMode mode) async {
    repeatModeSet = mode;
    calls.add('repeat:${mode.nativeValue}');
  }

  @override
  Future<void> setShuffleMode(bool enabled) async {
    shuffleModeSet = enabled;
    calls.add('shuffle:$enabled');
  }

  @override
  Future<void> setGainFactors({double? trackLevel, double? preamp, double? sleepFade, double? focusDuck}) async {
    gainFactors = <String, double?>{'trackLevel': trackLevel, 'preamp': preamp, 'sleepFade': sleepFade, 'focusDuck': focusDuck};
    calls.add('gainFactors');
  }

  @override
  Future<void> setVolume(double value) async {
    volumeSet = value;
    calls.add('volume:$value');
  }

  @override
  Future<void> setDeckPlaybackSpeeds({
    required double activeSpeed,
    required double standbySpeed,
  }) async {
    if (throwOnDeckSpeedOnce) {
      throwOnDeckSpeedOnce = false;
      // Simulate a native command that partially changes both deck rates
      // before reporting failure to Flutter.
      deckSpeeds = (1.04, 0.96);
      calls.add('deckSpeeds:partial_failure');
      throw StateError('simulated partial deck speed update');
    }
    deckSpeeds = (activeSpeed, standbySpeed);
    calls.add('deckSpeeds:${activeSpeed}:${standbySpeed}');
  }

  @override
  Future<void> preloadNext(
    Song song, {
    int? queueIndex,
    Duration startPosition = Duration.zero,
  }) async {
    calls.add('preloadNext:${song.id}:${queueIndex}:${startPosition.inMilliseconds}');
    if (throwOnPreloadNext) {
      throw StateError('simulated standby preload failure');
    }
    preloadedSong = song;
    preloadedIndex = queueIndex;
    preloadedStartPosition = startPosition;
    await preloadNextGate?.future;
  }

  @override
  Future<void> crossfade({required Duration duration}) async {
    if (emitIncomingErrorOnCrossfade) {
      crossfadeStatusValue = 'incoming_error';
      calls.add('crossfade:incoming_error');
      final current = currentSongValue;
      final index = queueIndexValue;
      if (current != null && index != null) {
        states.add(_state(
          song: current,
          queueIndex: index,
          playing: true,
          position: positionValue,
          playWhenReady: true,
          activeDeckId: activeDeckIdValue,
          crossfadeStatus: crossfadeStatusValue,
        ));
      }
      return;
    }
    if (throwOnCrossfade) {
      calls.add('crossfade:failed');
      throw StateError('simulated native crossfade failure');
    }
    crossfadeDuration = duration;
    calls.add('crossfade:${duration.inMilliseconds}');
    activeDeckIdValue = activeDeckIdValue == 'A' ? 'B' : 'A';
    final index = preloadedIndex;
    if (index != null && index >= 0 && index < queue.length) {
      currentSongValue = queue[index];
      queueIndexValue = index;
      positionValue = preloadedStartPosition ?? Duration.zero;
      playingValue = true;
      completedValue = false;
      durationValue = currentSongValue?.duration;
      states.add(_state(
        song: currentSongValue!,
        queueIndex: index,
        playing: true,
        position: positionValue,
        playWhenReady: true,
        activeDeckId: activeDeckIdValue,
      ));
    }
  }

  @override
  Future<void> setDeckEqOverlay({
    required String deck,
    required List<double> centersHz,
    required List<double> gainsDb,
  }) async {
    calls.add('setDeckEqOverlay:$deck');
  }

  @override
  Future<void> clearDeckEqOverlay({required String deck}) async {
    calls.add('clearDeckEqOverlay:$deck');
    if (throwOnClearDeckEqOverlay) {
      throw StateError('simulated standby overlay cleanup failure');
    }
  }

  @override
  Future<void> cancelCrossfade() async {
    calls.add('cancelCrossfade');
    await cancelCrossfadeGate?.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    calls.add('dispose');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('MusicProvider Media3 session preparation', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('applies cached volume normalization for the current Media3 track', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'normalization_enabled': true,
        'target_loudness': -14.0,
        'loudness_scan_v1_first': '1|-14.0|-10.0|-1.0|-6.0|1024|2026-11-17T00:00:00.000Z',
      });
      final session = _FakePlaybackSession();
      final music = MusicProvider(media3ProviderSession: session);
      await music.prepareMedia3ProviderSession();
      final features = PlaybackFeaturesProvider(music: music);
      await features.ready;
      final first = _song('first');
      await music.playSong(first, queue: <Song>[first]);
      expect(session.calls, contains('play'));
      for (var attempt = 0; attempt < 20; attempt++) {
        if ((session.gainFactors?['trackLevel'] ?? 1.0) < 0.9) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.gainFactors?['trackLevel'], closeTo(0.501187, 0.0001));
      features.dispose();
      music.dispose();
      await session.states.close();
      await session.audioSessions.close();
    });

    test('applies the selected track cached leveling trim before Media3 playback', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'audio_leveling_enabled_v1': true,
        'audio_leveling_target_rms_dbfs_v1': -18.0,
        'loudness_scan_v1_first': '1|-18.0|-12.0|-2.0|-6.0|1024|2026-11-17T00:00:00.000Z',
      });
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      await provider.prepareMedia3ProviderSession();
      final first = _song('first');

      await provider.playSong(first, queue: <Song>[first]);

      expect(session.calls, contains('play'));
      expect(session.gainFactors?['trackLevel'], closeTo(0.501187, 0.0001));
      expect(session.calls.indexOf('gainFactors'), lessThan(session.calls.indexOf('play')));
      provider.dispose();
      await session.states.close();
      await session.audioSessions.close();
    });

    test('restores saved speed and pitch before Media3 takes focus ownership', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'playback_speed': 1.35,
        'playback_pitch': 1.15,
      });
      final session = _PitchCapableFakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);

      await provider.prepareMedia3ProviderSession();

      expect(session.playbackSpeedValue, 1.35);
      expect(session.pitchValue, 1.15);
      final focusHandoff = session.calls.indexOf('focus:false');
      expect(session.calls.indexOf('speed:1.35'), lessThan(focusHandoff));
      expect(session.calls.indexOf('pitch:1.15'), lessThan(focusHandoff));
      expect(provider.debugLegacyEngineConstructed, isFalse);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('publishes active Media3 audio session without constructing legacy players', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final publishedIds = <int>[];
      provider.onAndroidSession = publishedIds.add;

      try {
        await provider.prepareMedia3ProviderSession();
        session.audioSessions.add(4321);
        await Future<void>.delayed(Duration.zero);

        expect(provider.activeAudioSessionId, 4321);
        expect(publishedIds, <int>[4321]);
        expect(provider.debugLegacyEngineConstructed, isFalse);
      } finally {
        provider.dispose();
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('saved audio-effect sync does not construct legacy engines for Media3', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);

      await provider.syncSavedAudioEffects();

      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'Media3 owns effect synchronization; the legacy controller must not create just_audio decks.');
      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('startup settings barrier holds feature activation until restoration completes', () async {
      final session = _PitchCapableFakePlaybackSession();
      final provider = MusicProvider(
        media3ProviderSession: session,
        deferMedia3UntilSettingsReady: true,
      );
      final settingsReady = Completer<void>();
      provider.setStartupSettingsReady(settingsReady.future);

      await provider.setPlaybackSpeedForFeatures(1.4);
      expect(provider.media3ProviderSessionActive, isFalse);

      settingsReady.complete();
      // Let the barrier's completion continuation publish readiness first.
      await Future<void>.delayed(Duration.zero);
      await provider.setPlaybackSpeedForFeatures(1.4);
      expect(provider.media3ProviderSessionActive, isTrue);
      expect(session.playbackSpeedValue, 1.4);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('playback feature changes activate and remain on injected Media3', () async {
      final session = _PitchCapableFakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);

      await provider.setPlaybackSpeedForFeatures(1.4);
      await provider.setPlaybackPitchForFeatures(1.1);
      await provider.setNormalizationForFeatures(
        targetGainMillibels: -350,
        enabled: true,
        trackLevel: 0.82,
      );

      expect(provider.media3ProviderSessionActive, isTrue);
      expect(session.playbackSpeedValue, 1.4);
      expect(session.pitchValue, 1.1);
      expect(session.gainFactors?['trackLevel'], 0.82);
      expect(session.calls, contains('speed:1.4'));
      expect(session.calls, contains('pitch:1.1'));
      expect(session.calls, contains('gainFactors'));
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'Feature changes must activate the injected session, not construct just_audio.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('system position publication reads the injected session before handoff', () async {
      final session = _FakePlaybackSession();
      session.positionValue = const Duration(seconds: 42);
      final handler = AudioServiceHandler();
      final provider = MusicProvider(
        audioHandler: handler,
        media3ProviderSession: session,
      );

      // pause publishes synchronously before its serialized command starts
      // Media3 preparation. The injected session is still the only valid
      // position source; a legacy EnginePair must not be constructed/read.
      final pause = provider.pause();
      expect(handler.playbackState.value.position,
          const Duration(seconds: 42));
      expect(provider.debugLegacyEngineConstructed, isFalse);

      await pause;
      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('requires an explicitly injected session', () async {
      final provider = MusicProvider();
      await expectLater(
        provider.prepareMedia3ProviderSession(),
        throwsStateError,
      );
      provider.dispose();
    });

    test('mirrors provider queue and settings before enabling the session handoff', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'Media3 startup must not construct the retired Flutter audio decks.');

      await provider.enqueueSongs(<Song>[_song('one'), _song('two')]);
      await provider.setRepeatMode(PlaybackRepeatMode.all);
      await provider.setShuffleEnabled(true);
      final expectedQueue = provider.queue.map((song) => song.id).toList();

      await provider.prepareMedia3ProviderSession();

      expect(provider.media3ProviderSessionPrepared, isTrue);
      expect(provider.media3ShadowState, isNull,
          reason: 'No Media3 snapshot has been published by the fake session.');
      // Queue mutation now activates the injected Media3 session before
      // explicit prepare; subsequent mode changes must be mirrored live.
      expect(session.calls, contains('loadQueue'));
      expect(session.calls, contains('repeat:all'));
      expect(session.calls, contains('shuffle:true'));
      expect(
        session.calls.indexOf('start'),
        lessThan(session.calls.indexOf('loadQueue')),
      );
      expect(
        session.calls.lastIndexOf('repeat:all'),
        greaterThan(session.calls.indexOf('loadQueue')),
      );
      expect(session.queue.map((song) => song.id).toList(), expectedQueue);
      expect(session.loadedIndex, provider.queueIndex);
      expect(session.repeatModeSet, PlaybackQueueRepeatMode.all);
      expect(session.shuffleModeSet, isTrue);
      expect(session.volumeSet, 1.0);
      expect(session.focusHandling, isTrue,
          reason: 'Media3 owns audio focus after the provider handoff is committed.');
      expect(provider.media3ProviderSessionActive, isTrue);
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'A successful Media3 handoff must not create a just_audio EnginePair.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(session.disposed, isTrue);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('rechecks communication mode after Media3 session activation before claiming focus', () async {
      var simulateCall = false;
      var communicationChecks = 0;
      const communicationChannel =
          MethodChannel('com.aetherion.resonate/media_store');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(communicationChannel, (call) async {
        if (!simulateCall) return false;
        communicationChecks++;
        // The first check allows recovery; the second simulates a call starting
        // while the asynchronous Media3 activation/focus path is in progress.
        return communicationChecks >= 2;
      });

      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('focus-race');

      try {
        expect(await provider.playSong(song, queue: <Song>[song]), isTrue);
        expect(provider.media3ProviderSessionActive, isTrue);

        simulateCall = true;
        communicationChecks = 0;
        session.calls.clear();
        await provider.ensureAudiblePlayback();

        expect(communicationChecks, 2);
        expect(session.calls, isNot(contains('focus:true')),
            reason: 'A newly active call must prevent Media3 from reclaiming focus.');
        expect(session.calls, isNot(contains('play')),
            reason: 'Audible recovery must not restart playback during a call.');
      } finally {
        provider.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(communicationChannel, null);
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('audible recovery relinquishes Media3 focus if communication starts during focus request', () async {
      var simulateCall = false;
      var communicationChecks = 0;
      const communicationChannel =
          MethodChannel('com.aetherion.resonate/media_store');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(communicationChannel, (call) async {
        if (!simulateCall) return false;
        communicationChecks++;
        return communicationChecks >= 3;
      });

      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('audible-focus-request-race');

      try {
        expect(await provider.playSong(song, queue: <Song>[song]), isTrue);
        simulateCall = true;
        communicationChecks = 0;
        session.calls.clear();
        final focusGate = Completer<void>();
        session.focusEnableGate = focusGate;

        final recovery = provider.ensureAudiblePlayback();
        for (var attempt = 0;
            attempt < 40 && !session.calls.contains('focus:true');
            attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(session.calls, contains('focus:true'));
        focusGate.complete();
        await recovery;

        expect(communicationChecks, 3);
        expect(session.calls, contains('focus:false'),
            reason: 'Media3 must relinquish focus when a call starts during the focus request.');
        expect(session.focusHandling, isFalse);
        expect(session.calls, isNot(contains('play')),
            reason: 'Audible recovery must not restart playback after focus is revoked.');
      } finally {
        provider.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(communicationChannel, null);
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('pause supersedes seek while Media3 activation is pending', () async {
      const communicationChannel =
          MethodChannel('com.aetherion.resonate/media_store');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(communicationChannel, (call) async => false);

      final session = _FakePlaybackSession();
      session.durationValue = const Duration(minutes: 3);
      final startGate = Completer<void>();
      session.startGate = startGate;
      final provider = MusicProvider(media3ProviderSession: session);

      try {
        final seek = provider.seek(const Duration(seconds: 5));
        for (var attempt = 0;
            attempt < 80 && !session.calls.contains('start');
            attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(session.calls, contains('start'),
            reason: 'The test must hold Media3 activation before it completes.');

        final pause = provider.pause();
        startGate.complete();
        await Future.wait(<Future<void>>[seek, pause]);

        expect(session.calls, isNot(contains('seek:5000')),
            reason: 'A superseded seek must not run after pause takes ownership.');
        expect(session.calls, contains('pause'));
        expect(provider.debugLegacyEngineConstructed, isFalse,
            reason: 'A stale Media3 seek must never fall through to just_audio.');
      } finally {
        provider.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(communicationChannel, null);
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('pause supersedes resume while Media3 activation is pending', () async {
      const communicationChannel =
          MethodChannel('com.aetherion.resonate/media_store');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(communicationChannel, (call) async => false);

      final session = _FakePlaybackSession();
      final startGate = Completer<void>();
      session.startGate = startGate;
      final provider = MusicProvider(media3ProviderSession: session);

      try {
        final preparing = provider.prepareMedia3ProviderSession();
        for (var attempt = 0;
            attempt < 80 && !session.calls.contains('start');
            attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(session.calls, contains('start'),
            reason: 'The test must hold Media3 activation before it completes.');

        final resume = provider.resumePlayback();
        final pause = provider.pause();
        startGate.complete();
        await Future.wait(<Future<void>>[preparing, resume, pause]);

        expect(session.calls, contains('pause'),
            reason: 'The later pause must be applied after activation completes.');
        expect(session.calls, isNot(contains('play')),
            reason: 'A superseded resume must not restart playback after pause.');
        expect(session.focusHandling, isFalse,
            reason: 'The completed pause must leave Media3 focus handling released.');
        expect(session.calls, contains('pause'));
        expect(session.focusHandling, isFalse);
        expect(provider.isPlaying, isFalse);
        expect(provider.debugLegacyEngineConstructed, isFalse,
            reason: 'A stale Media3 resume must never fall through to just_audio.');
      } finally {
        provider.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(communicationChannel, null);
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('resume relinquishes Media3 focus if communication starts during focus handoff', () async {
      var communicationChecks = 0;
      const communicationChannel =
          MethodChannel('com.aetherion.resonate/media_store');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(communicationChannel, (call) async {
        communicationChecks++;
        // Initial guard and post-activation guard pass; the call starts while
        // Media3 is enabling its focus handling.
        return communicationChecks >= 3;
      });

      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('resume-focus-race');

      try {
        expect(await provider.playSong(song, queue: <Song>[song]), isTrue);
        await provider.pause();
        session.calls.clear();
        communicationChecks = 0;

        await provider.resumePlayback();

        expect(communicationChecks, 3);
        expect(session.calls, contains('focus:true'));
        expect(session.calls, contains('focus:false'));
        expect(session.focusHandling, isFalse);
        expect(session.calls, isNot(contains('play')),
            reason: 'Resume must not start media playback after communication takes focus.');
        expect(provider.isPlaying, isFalse);
        expect(provider.debugLegacyEngineConstructed, isFalse);
      } finally {
        provider.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(communicationChannel, null);
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('clearing queue before explicit handoff activates and stops injected Media3', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);

      await provider.setQueue(<Song>[]);

      expect(provider.media3ProviderSessionActive, isTrue);
      expect(session.calls, contains('clearQueue'));
      expect(session.calls, contains('stop'));
      expect(provider.queue, isEmpty);
      expect(provider.debugLegacyEngineConstructed, isFalse);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('toggle before explicit handoff prepares and uses injected Media3 without creating legacy engines', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      expect(provider.debugLegacyEngineConstructed, isFalse);

      await provider.togglePlayPause();

      expect(provider.media3ProviderSessionActive, isTrue);
      expect(session.calls, contains('play'));
      expect(session.playingValue, isTrue);
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'An injected Media3 session must never fall through to lazy just_audio construction.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('queue edits, playback modes, navigation and seek stay on injected Media3', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('pre-handoff-first');
      final second = _song('pre-handoff-second');
      await provider.enqueueSongs(<Song>[first, second]);
      expect(provider.media3ProviderSessionActive, isTrue);
      expect(session.calls, contains('synchronizeQueue'));
      expect(provider.debugLegacyEngineConstructed, isFalse);

      await provider.setShuffleEnabled(true);
      expect(session.calls, contains('shuffle:true'));
      await provider.setRepeatMode(PlaybackRepeatMode.one);
      expect(session.calls, contains('repeat:one'));

      await provider.nextSong();
      expect(provider.media3ProviderSessionActive, isTrue);
      expect(session.calls, contains('next'));
      expect(provider.currentSong?.id, second.id);

      await provider.previousSong();
      expect(session.calls, contains('previous'));
      expect(provider.currentSong?.id, first.id);

      await provider.seek(const Duration(seconds: 25));
      expect(session.calls, contains('seek:25000'));
      expect(session.positionValue, const Duration(seconds: 25));
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'Navigation and seeking must not construct the legacy just_audio EnginePair.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('external MediaSession repeat changes reconcile into provider state', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('external-repeat');
      await provider.enqueueSongs(<Song>[song]);
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(song, queue: <Song>[song]), isTrue);
      expect(provider.repeatMode, PlaybackRepeatMode.off);

      // Simulates a repeat-mode update originating from Android's notification,
      // a headset transport control or Android Auto rather than Flutter UI.
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        repeatMode: 'one',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(provider.repeatMode, PlaybackRepeatMode.one);

      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        repeatMode: 'all',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(provider.repeatMode, PlaybackRepeatMode.all);
      provider.dispose();
      await session.states.close();
      await session.audioSessions.close();
    });

    test('planned queue order overrides Shuffle temporarily without changing its saved preference', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      await provider.setShuffleEnabled(true);
      final first = _song('planned-first');
      final second = _song('planned-second');
      final third = _song('planned-third');
      final fourth = _song('planned-fourth');
      final fifth = _song('planned-fifth');

      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
        preserveQueueOrder: true,
      ), isTrue);
      expect(provider.queue.map((song) => song.id).toList(),
          [first.id, second.id, third.id]);
      expect(provider.queueOrderLocked, isTrue);
      expect(provider.shuffleEnabled, isFalse);
      expect(session.shuffleModeSet, isFalse);

      expect(await provider.enqueueSongs(
        <Song>[fourth, fifth],
        preserveOrder: true,
      ), isTrue);
      expect(provider.queue.map((song) => song.id).toList(),
          [first.id, second.id, third.id, fourth.id, fifth.id]);
      expect(session.shuffleModeSet, isFalse);

      // Selecting another item in the same planned queue must not unlock it.
      expect(await provider.playSong(
        second,
        queue: provider.queue,
        startIndex: 1,
      ), isTrue);
      expect(provider.queue.map((song) => song.id).toList(),
          [first.id, second.id, third.id, fourth.id, fifth.id]);
      expect(provider.queueOrderLocked, isTrue);
      expect(session.shuffleModeSet, isFalse);

      // A direct user Shuffle toggle overrides the temporary lock.
      await provider.setShuffleEnabled(true);
      expect(provider.queueOrderLocked, isFalse);
      expect(provider.shuffleEnabled, isTrue);
      expect(session.shuffleModeSet, isTrue);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('clearing upcoming queue awaits persistence and synchronizes Media3', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('clear-upcoming-current');
      final second = _song('clear-upcoming-next');
      final third = _song('clear-upcoming-later');

      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);
      session.calls.clear();

      await provider.clearUpcomingQueue();

      expect(session.queue.map((song) => song.id).toList(), [first.id]);
      expect(session.calls, contains('synchronizeQueue'));
      expect(provider.currentSong?.id, first.id);
      expect(provider.queueIndex, 0);
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'Clearing upcoming items must remain on the injected Media3 session.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('removing the prepared incoming track invalidates a blocked Media3 preload', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('queue-edit-outgoing');
      final second = _song('queue-edit-prepared-incoming');
      final third = _song('queue-edit-new-incoming');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.any((call) =>
                  call.startsWith('preloadNext:queue-edit-prepared-incoming:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        session.calls.any((call) =>
            call.startsWith('preloadNext:queue-edit-prepared-incoming:')),
        isTrue,
        reason: 'The first upcoming track should be prepared before the edit.',
      );

      expect(await provider.removeFromQueue(1), isTrue);
      expect(provider.upcomingQueue.map((song) => song.id).toList(),
          <String>[third.id]);
      expect(session.calls, contains('cancelCrossfade'));
      expect(session.calls, contains('clearDeckEqOverlay:standby'));

      session.preloadNextGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.calls.where((call) => call.startsWith('crossfade:')),
          isEmpty,
          reason: 'A stale preload must never commit after its target is removed.');
      expect(provider.currentSong?.id, first.id);
      expect(provider.queueIndex, 0);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('appending behind the prepared target preserves the Media3 preload', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('queue-append-outgoing');
      final second = _song('queue-append-prepared-target');
      final third = _song('queue-append-existing-tail');
      final fourth = _song('queue-append-new-tail');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.any((call) =>
                  call.startsWith('preloadNext:queue-append-prepared-target:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        session.calls.any((call) =>
            call.startsWith('preloadNext:queue-append-prepared-target:')),
        isTrue,
      );

      session.calls.clear();
      expect(await provider.enqueueSongs(<Song>[fourth]), isTrue);
      expect(provider.upcomingQueue.map((song) => song.id).toList(),
          <String>[second.id, third.id, fourth.id]);
      expect(session.calls, contains('synchronizeQueue'));
      expect(
        session.calls,
        isNot(contains('cancelCrossfade')),
        reason: 'Appending after the prepared successor must not retire its standby deck.',
      );

      session.preloadNextGate!.complete();
      for (var attempt = 0;
          attempt < 100 && session.calls.where((call) => call.startsWith('deckSpeeds:')).isEmpty;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.preloadedSong?.id, second.id);
      expect(session.preloadedIndex, 1);
      expect(session.calls, isNot(contains('cancelCrossfade')));
      expect(provider.currentSong?.id, first.id);
      expect(provider.queueIndex, 0);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('rapid Next then Previous preempts a prepared Media3 DJ handoff', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('rapid-transport-outgoing');
      final second = _song('rapid-transport-prepared');
      final third = _song('rapid-transport-tail');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.any((call) =>
                  call.startsWith('preloadNext:rapid-transport-prepared:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        session.calls.any((call) =>
            call.startsWith('preloadNext:rapid-transport-prepared:')),
        isTrue,
      );

      // Exercise two opposing transport commands while the incoming decoder
      // is still blocked. The second command must own the final queue position.
      await provider.nextSong();
      await provider.previousSong();
      expect(provider.currentSong?.id, first.id);
      expect(provider.queueIndex, 0);
      expect(session.calls, contains('cancelCrossfade'));

      session.preloadNextGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        session.calls.where((call) => call.startsWith('crossfade:')),
        isEmpty,
        reason: 'The pre-transport standby plan must not commit after Next/Previous.',
      );
      expect(provider.currentSong?.id, first.id);
      expect(provider.queueIndex, 0);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('restores the provider resume position into the new Media3 session before handoff', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      // Set the restored provider position before the first queue mutation:
      // queue synchronization activates the injected session immediately.
      provider.currentPosition = const Duration(seconds: 42);
      await provider.enqueueSongs(<Song>[_song('resume'), _song('next')]);

      await provider.prepareMedia3ProviderSession();

      expect(session.calls, contains('seek:42000'));
      expect(session.positionValue, const Duration(seconds: 42));
      expect(
        session.calls.indexOf('loadQueue'),
        lessThan(session.calls.indexOf('seek:42000')),
      );
      expect(
        session.calls.indexOf('seek:42000'),
        lessThan(session.calls.indexOf('focus:true')),
      );

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('persists live Media3 position so force-stop recovery has a durable checkpoint', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('media3-resume-checkpoint');
      await provider.enqueueSongs(<Song>[song]);
      await provider.prepareMedia3ProviderSession();

      session.positionValue = const Duration(seconds: 42);
      session.playingValue = true;
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 42),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('playback_resume_position_ms'), 42000);
      expect(prefs.getString('playback_resume_song_id'), song.id);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('persists the queue index when Media3 promotes the next deck', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('queue-first');
      final second = _song('queue-second');
      await provider.enqueueSongs(<Song>[first, second]);
      await provider.prepareMedia3ProviderSession();

      session.currentSongValue = second;
      session.queueIndexValue = 1;
      session.positionValue = const Duration(seconds: 18);
      session.playingValue = true;
      session.states.add(_state(
        song: second,
        queueIndex: 1,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 18),
        activeDeckId: 'B',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(QueueStore.savedQueueIndexKey), 1);
      expect(prefs.getString('playback_resume_song_id'), second.id);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('reports native Engine A/B promotion and recovers DJ state on Media3 only', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('deck-identity');
      await provider.enqueueSongs(<Song>[song]);
      await provider.prepareMedia3ProviderSession();

      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 12),
        activeDeckId: 'B',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.activeEngineLabel, 'B');
      expect(provider.isEngineA, isFalse);

      session.playingValue = true;
      provider.configureDjMode(beatAlignActive: true, tempoMatchActive: true, sfxActive: true);
      provider.configureDjMode(beatAlignActive: false, tempoMatchActive: false, sfxActive: false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(session.calls, contains('deckSpeeds:1.0:1.0'));
      expect(session.calls, contains('gainFactors'));
      expect(session.gainFactors?['focusDuck'], 1.0,
          reason: 'DJ recovery must not leave a focus duck applied without focus loss');
      expect(session.focusHandling, isTrue,
          reason: 'DJ toggle must not transfer audio-focus ownership');
      expect(session.playingValue, isTrue,
          reason: 'DJ toggle must not pause canonical Media3 playback');
      expect(session.calls, isNot(contains('pause')));
      expect(session.calls, isNot(contains('stop')));

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('routes play, pause, seek, next, previous and stop through the handed-off session', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      await provider.prepareMedia3ProviderSession();

      expect(await provider.playSong(
        _song('one'),
        queue: <Song>[_song('one'), _song('two')],
        startIndex: 0,
      ), isTrue);
      expect(session.calls, contains('play'));
      expect(provider.media3ProviderSessionActive, isTrue);

      await provider.pause();
      expect(session.calls, contains('pause'));
      await provider.seek(const Duration(seconds: 25));
      expect(session.positionValue, const Duration(seconds: 25));
      await provider.nextSong();
      expect(session.calls, contains('next'));
      expect(provider.currentSong?.id, 'two');
      await provider.previousSong();
      expect(session.calls, contains('previous'));
      expect(provider.currentSong?.id, 'one');
      await provider.stop();
      expect(session.calls, contains('stop'));

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('explicit queue selection cancels native crossfade before loading the selected track', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('queue-select-first');
      final second = _song('queue-select-second');
      final third = _song('queue-select-third');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);

      // Ignore cancellation performed by the initial Play Song command.
      session.calls.clear();
      expect(await provider.playQueueIndex(2), isTrue);

      final cancelIndex = session.calls.indexOf('cancelCrossfade');
      final overlayClearIndex = session.calls.indexOf('clearDeckEqOverlay:standby');
      final loadIndex = session.calls.lastIndexOf('loadQueue');
      expect(cancelIndex, greaterThanOrEqualTo(0),
          reason: 'Queue selection must invalidate a prepared native standby deck.');
      expect(overlayClearIndex, greaterThan(cancelIndex),
          reason: 'Transport cancellation must clear temporary standby bass ducking.');
      expect(loadIndex, greaterThan(overlayClearIndex),
          reason: 'The requested queue occurrence must load after transition cleanup.');
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(session.currentSong?.id, third.id);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('external MediaSession transport keeps track, queue and controls synchronized', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('external-transport-first');
      final second = _song('external-transport-second');
      final third = _song('external-transport-third');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);

      // Resolve the initial optimistic selection first. Real Media3 publishes
      // the selected item after loadQueue; without this acknowledgement the
      // provider correctly treats the next different item as a delayed
      // outgoing snapshot while the initial selection is still pending.
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.currentSong?.id, first.id);
      expect(provider.queueIndex, 0);

      // Android notification, headset and Auto commands bypass Flutter
      // transport methods. Their canonical Media3 observations must still
      // update the provider's selected occurrence and transport controls.
      session.currentSongValue = second;
      session.queueIndexValue = 1;
      session.positionValue = const Duration(seconds: 11);
      session.playingValue = true;
      session.states.add(_state(
        song: second,
        queueIndex: 1,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 11),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);
      expect(provider.currentPosition, const Duration(seconds: 11));
      expect(provider.isPlaying, isTrue);

      session.currentSongValue = third;
      session.queueIndexValue = 2;
      session.positionValue = const Duration(seconds: 3);
      session.playingValue = true;
      session.states.add(_state(
        song: third,
        queueIndex: 2,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 3),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(provider.currentPosition, const Duration(seconds: 3));
      expect(provider.isPlaying, isTrue);

      // A native pause/resume affects the session-level control even when
      // the queue occurrence itself does not change.
      session.playingValue = false;
      session.states.add(_state(
        song: third,
        queueIndex: 2,
        playing: false,
        playWhenReady: false,
        position: const Duration(seconds: 4),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.isPlaying, isFalse);
      expect(provider.currentSong?.id, third.id);

      session.playingValue = true;
      session.states.add(_state(
        song: third,
        queueIndex: 2,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 5),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.isPlaying, isTrue);
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('fresh library selection is not reverted by a delayed native timeline snapshot', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('stale-ui-first');
      final second = _song('stale-ui-second');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second],
        startIndex: 0,
      ), isTrue);

      // Simulate Media3 accepting loadQueue while its readable timeline still
      // points at the outgoing item for a short interval.
      session.deferLoadQueueState = true;
      expect(await provider.playSong(
        second,
        queue: <Song>[first, second],
        startIndex: 1,
      ), isTrue);
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);
      expect(provider.currentPosition, Duration.zero);

      // A delayed callback for the outgoing track must not overwrite the
      // committed library selection while Media3 is publishing its timeline.
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 37),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);
      expect(provider.currentPosition, Duration.zero);

      // A pause edge from the still-visible outgoing timeline is global to the
      // MediaSession. It must update the Play/Pause control even while the
      // selected track identity remains fenced against that stale timeline.
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: false,
        playWhenReady: false,
        position: const Duration(seconds: 38),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(provider.isPlaying, isFalse);
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);
      expect(provider.currentPosition, Duration.zero);

      // Once the native timeline catches up, normal observation remains the
      // source of truth and must preserve the selected item.
      session.deferLoadQueueState = false;
      session.currentSongValue = second;
      session.queueIndexValue = 1;
      session.durationValue = second.duration;
      session.states.add(_state(
        song: second,
        queueIndex: 1,
        playing: true,
        playWhenReady: true,
        position: Duration.zero,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('preserves the selected occurrence when a queue contains duplicate song IDs', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final firstOccurrence = _song('duplicate-id');
      final secondOccurrence = Song(
        id: 'duplicate-id',
        title: 'Remastered',
        artist: 'Artist',
        album: 'Album',
        filePath: '/music/duplicate-id-remastered.mp3',
        duration: const Duration(minutes: 3),
        dateAdded: DateTime.utc(2026, 1, 1),
      );
      await provider.prepareMedia3ProviderSession();

      expect(await provider.playSong(
        secondOccurrence,
        queue: <Song>[firstOccurrence, secondOccurrence],
        startIndex: 1,
      ), isTrue);

      expect(session.loadedIndex, 1);
      expect(provider.queueIndex, 1);
      expect(provider.currentSong?.filePath,
          '/music/duplicate-id-remastered.mp3');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('uses canonical Media3 state for recovery without overriding an external pause', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('one');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(song, queue: <Song>[song]), isTrue);

      final playCallsBeforeRecovery =
          session.calls.where((call) => call == 'play').length;
      session.playingValue = false;
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        position: const Duration(seconds: 42),
        playWhenReady: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(provider.currentPosition, const Duration(seconds: 42));
      expect(
        session.calls.where((call) => call == 'play').length,
        greaterThan(playCallsBeforeRecovery),
        reason: 'A stopped deck with native playWhenReady intent is recoverable.',
      );
      expect(session.playingValue, isTrue);
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'The Media3 watchdog must not construct legacy just_audio decks.');

      final playCallsAfterRecovery =
          session.calls.where((call) => call == 'play').length;
      session.playingValue = false;
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        position: const Duration(seconds: 42),
        playWhenReady: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        session.calls.where((call) => call == 'play').length,
        playCallsAfterRecovery,
        reason: 'A native pause must not be undone by the recovery watchdog.',
      );

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('advances completion through the canonical Media3 session', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('only-track');
      await provider.prepareMedia3ProviderSession();
      await provider.setRepeatMode(PlaybackRepeatMode.off);
      expect(await provider.playSong(song, queue: <Song>[song]), isTrue);

      session.playingValue = false;
      session.completedValue = true;
      session.positionValue = song.duration;
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        completed: true,
        position: song.duration,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(session.calls, contains('stop'));
      expect(provider.isPlaying, isFalse);
      expect(provider.media3ProviderSessionActive, isTrue);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('restores persisted crossfade and arms Media3 without a UI toggle', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'crossfade_enabled': true,
        'crossfade_duration': 500.0,
        'crossfade_fade_type': 'ease_in_out',
      });
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('restored-fade-out');
      final second = _song('restored-fade-in');

      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      session.positionValue = const Duration(milliseconds: 177600);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.preloadedSong, isNull,
          reason: 'Crossfade preferences have not been hydrated yet.');

      final crossfade = CrossfadeProvider(music: provider);
      try {
        await crossfade.ready;
        expect(crossfade.isEnabled, isTrue);
        expect(crossfade.duration, 500.0);
        expect(provider.crossfadeEnabled, isTrue);
        expect(provider.crossfadeDurationMs, 500);
        expect(provider.crossfadeFadeType, 'ease_in_out');

        for (var attempt = 0;
            attempt < 40 && session.preloadedSong == null;
            attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(session.preloadedSong?.id, second.id,
            reason: 'Restored settings must immediately arm the current track preload.');

        session.positionValue = const Duration(milliseconds: 178000);
        session.states.add(_state(
          song: first,
          queueIndex: 0,
          playing: true,
          playWhenReady: true,
          position: session.positionValue,
        ));
        for (var attempt = 0;
            attempt < 60 && session.crossfadeDuration == null;
            attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(session.crossfadeDuration, const Duration(milliseconds: 500));
        expect(provider.currentSong?.id, second.id);
      } finally {
        crossfade.dispose();
        provider.dispose();
        await Future<void>.delayed(Duration.zero);
        await session.audioSessions.close();
        await session.states.close();
      }
    });

    test('defers crossfade without replacing the active queue while standby preload is slow', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('slow-preload-out');
      final second = _song('slow-preload-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 && !session.calls.any((call) => call.startsWith('preloadNext:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.calls.any((call) => call.startsWith('preloadNext:')), isTrue);

      // Reach the normal trigger window while the native standby preparation
      // is still deliberately blocked. The outgoing queue must remain intact.
      session.positionValue = const Duration(milliseconds: 178000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 2200));

      expect(session.calls.where((call) => call == 'loadQueue').length, 1,
          reason: 'A slow standby preload must not trigger a hard queue replacement.');
      expect(session.calls.where((call) => call == 'play').length, 1,
          reason: 'The active deck must not be restarted while preload is pending.');
      expect(session.calls.where((call) => call.startsWith('crossfade:')), isEmpty);

      session.preloadNextGate!.complete();
      for (var attempt = 0;
          attempt < 100 && !session.calls.any((call) => call.startsWith('deckSpeeds:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 && session.currentSongValue?.id != second.id;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.currentSongValue?.id, second.id,
          reason: 'Once standby preparation completes, the safe crossfade should resume normally.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('partial DJ preload speed failure independently restores both deck rates', () async {
      final session = _FakePlaybackSession()..throwOnDeckSpeedOnce = true;
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('partial-speed-preload-out');
      final second = _song('partial-speed-preload-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.contains('deckSpeeds:1.0:1.0');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(session.calls, contains('deckSpeeds:partial_failure'));
      expect(session.calls, contains('clearDeckEqOverlay:standby'));
      expect(session.calls, contains('deckSpeeds:1.0:1.0'),
          reason: 'A partially applied tempo match must be reset after preload failure.');
      expect(session.deckSpeeds, (1.0, 1.0));
      expect(provider.currentSong?.id, first.id);
      expect(session.calls.where((call) => call.startsWith('crossfade:')), isEmpty);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('late standby completion defers to the native queue instead of reloading playback', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('late-preload-out');
      final second = _song('late-preload-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 && !session.calls.any((call) => call.startsWith('preloadNext:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.calls.any((call) => call.startsWith('preloadNext:')), isTrue);

      // Trigger the transition with two seconds remaining. The decoder finishes
      // just before the two-second wait expires, leaving too little room for a
      // validated fade. That must not take the hard queue-reload fallback.
      session.positionValue = const Duration(milliseconds: 178000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      session.positionValue = const Duration(milliseconds: 179000);
      session.preloadNextGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(session.calls.where((call) => call == 'loadQueue').length, 1,
          reason: 'A late standby deck must not reload the active queue.');
      expect(session.calls.where((call) => call == 'play').length, 1,
          reason: 'Natural queue completion must retain ownership of playback.');
      expect(session.calls.where((call) => call.startsWith('crossfade:')), isEmpty);
      expect(session.calls, contains('cancelCrossfade'));
      expect(session.calls, contains('deckSpeeds:1.0:1.0'));
      expect(provider.currentSong?.id, first.id);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('manual transport invalidates a blocked preload without poisoning the next preload', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('cancel-preload-out');
      final second = _song('cancel-preload-in');
      final third = _song('cancel-preload-next');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.any((call) => call.startsWith('preloadNext:cancel-preload-in:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        session.calls.any((call) => call.startsWith('preloadNext:cancel-preload-in:')),
        isTrue,
      );

      // A new explicit selection owns transport while the old standby load is
      // still blocked. Its late completion must not keep the preload lock set.
      expect(await provider.playSong(second, queue: <Song>[second, third]), isTrue);
      final cancelCountAfterSelection =
          session.calls.where((call) => call == 'cancelCrossfade').length;
      session.preloadNextGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        session.calls.where((call) => call == 'cancelCrossfade').length,
        cancelCountAfterSelection,
        reason: 'A stale preload continuation must not cancel a newer standby operation.',
      );

      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: second,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.any((call) => call.startsWith('preloadNext:cancel-preload-next:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        session.calls.any((call) => call.startsWith('preloadNext:cancel-preload-next:')),
        isTrue,
        reason: 'A stale preload completion must not leave the next queue occurrence permanently un-preloadable.',
      );

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('manual pause still resets DJ deck speeds when standby EQ cleanup fails', () async {
      final session = _FakePlaybackSession()
        ..throwOnClearDeckEqOverlay = true
        ..deckSpeeds = (1.04, 0.96);
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('pause-cleanup-out');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first]), isTrue);
      session.calls.clear();

      await provider.pause();
      for (var attempt = 0;
          attempt < 100 && !session.calls.contains('deckSpeeds:1.0:1.0');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(session.calls, contains('cancelCrossfade'));
      expect(session.calls, contains('clearDeckEqOverlay:standby'));
      expect(
        session.calls,
        contains('deckSpeeds:1.0:1.0'),
        reason: 'EQ cleanup failure must not strand tempo-matched rates after manual pause.',
      );
      expect(session.deckSpeeds, (1.0, 1.0));

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('failed standby preload preserves the active queue for gapless completion', () async {
      final session = _FakePlaybackSession()..throwOnPreloadNext = true;
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('preload-failure-out');
      final second = _song('preload-failure-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      // Trigger the lead-in preload window, then wait for its failure to settle.
      session.positionValue = const Duration(milliseconds: 170000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 && !session.calls.any((call) => call.startsWith('preloadNext:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.calls.any((call) => call.startsWith('preloadNext:')), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Enter the normal fade trigger window after standby decoding has failed.
      session.positionValue = const Duration(milliseconds: 178000);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(session.calls.where((call) => call == 'loadQueue').length, 1,
          reason: 'A failed standby decode must not replace the playing queue.');
      expect(session.calls.where((call) => call == 'play').length, 1,
          reason: 'A failed standby decode must not restart playback.');
      expect(session.calls, contains('cancelCrossfade'));
      expect(session.calls, contains('deckSpeeds:1.0:1.0'));
      expect(session.currentSongValue?.id, first.id);
      expect(session.playingValue, isTrue);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('fails over immediately when the native standby deck reports an error', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'crossfade_enabled': true,
        'crossfade_duration': 500.0,
      });
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('standby-error-out');
      final second = _song('standby-error-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      // Hydrate the persisted opt-in through the same provider lifecycle used
      // by the app; SharedPreferences alone does not enable crossfade in
      // MusicProvider.
      final crossfade = CrossfadeProvider(music: provider);
      await crossfade.ready;
      expect(provider.crossfadeEnabled, isTrue);
      // Preload belongs to the lead-in window, not the fade-arm window.
      // At 2.4s remaining the ordinary 500ms crossfade is already too late
      // to request a fresh preload, so first place playback 10s from the end.
      session.positionValue = const Duration(milliseconds: 170000);
      expect(provider.canCrossfadeNext, isTrue);
      expect(session.isPlaying, isTrue);
      provider.onCrossfadeSettingsRestored();
      for (var attempt = 0;
          attempt < 100 && session.preloadedSong?.id != second.id;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.preloadedSong?.id, second.id,
          reason: 'The selected standby occurrence must be prepared in the preload lead-in window.');

      // Now enter the native fade trigger window and report the simulated
      // standby decode error from the crossfade command itself.
      session.positionValue = const Duration(milliseconds: 178000);
      session.emitIncomingErrorOnCrossfade = true;
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 && !session.calls.contains('crossfade:incoming_error');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.calls, contains('crossfade:incoming_error'));
      for (var attempt = 0;
          attempt < 100 && session.loadedIndex != 1;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.loadedIndex, 1,
          reason: 'A failed standby deck must fall back to the selected queue item without waiting for the transition timeout.');
      expect(session.calls, contains('play'));
      crossfade.dispose();
      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('does not consult retired just_audio duration when Media3 duration is unavailable', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('duration-unavailable-out');
      final second = _song('duration-unavailable-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      session.durationValue = null;
      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(session.preloadedSong, isNull);
      expect(session.crossfadeDuration, isNull);
      expect(provider.debugLegacyEngineConstructed, isFalse,
          reason: 'Media3 duration unavailability must not fall back to a retired legacy player.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('runs automatic crossfade and DJ deck commands through the Media3 session', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('fade-out');
      final second = _song('fade-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second],
      ), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(session.preloadedSong?.id, 'fade-in');
      expect(session.preloadedIndex, 1);
      expect(session.crossfadeDuration, isNotNull);
      expect(session.calls, contains('crossfade:500'));
      expect(session.calls, contains('deckSpeeds:1.0:1.0'));
      expect(provider.currentSong?.id, 'fade-in');
      expect(provider.media3ProviderSessionActive, isTrue);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('incoming deck error recovers the selected track on the active Media3 deck', () async {
      final session = _FakePlaybackSession()
        ..emitIncomingErrorOnCrossfade = true;
      final provider = MusicProvider(media3ProviderSession: session);
      final outgoing = _song('incoming-error-outgoing');
      final incoming = _song('incoming-error-incoming');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        outgoing,
        queue: <Song>[outgoing, incoming],
      ), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: outgoing,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));

      for (var attempt = 0;
          attempt < 120 &&
              !session.calls.skip(1).contains('loadQueue');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(session.calls, contains('crossfade:incoming_error'));
      expect(session.calls, contains('cancelCrossfade'));
      expect(session.calls, contains('clearDeckEqOverlay:standby'));
      expect(session.calls, contains('deckSpeeds:1.0:1.0'));
      expect(
        session.calls.where((call) => call == 'loadQueue').length,
        greaterThanOrEqualTo(2),
        reason: 'An incoming-deck failure must recover through the canonical Media3 queue.',
      );
      expect(
        session.calls.where((call) => call == 'play').length,
        greaterThanOrEqualTo(2),
        reason: 'The same-session fallback must resume the selected incoming occurrence.',
      );
      expect(provider.currentSong?.id, incoming.id);
      expect(provider.queueIndex, 1);
      expect(provider.media3ProviderSessionActive, isTrue);
      expect(provider.debugLegacyEngineConstructed, isFalse);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('library selection after crossfade promotion resists delayed outgoing state', () async {
      final session = _FakePlaybackSession();
      final audioHandler = AudioServiceHandler();
      final provider = MusicProvider(
        audioHandler: audioHandler,
        media3ProviderSession: session,
      );
      final first = _song('promotion-outgoing');
      final second = _song('promotion-promoted');
      final third = _song('promotion-library-selection');
      final queue = <Song>[first, second, third];
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: queue), isTrue);

      // Confirm the initial native selection before exercising a real
      // crossfade promotion from deck A to deck B.
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await provider.setCrossfadeDuration(500);
      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(session.activeDeckIdValue, 'B');
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);
      expect(provider.isPlaying, isTrue);

      // Immediately selecting a library track after promotion must win over
      // delayed snapshots still describing the promoted/outgoing timeline.
      session.deferLoadQueueState = true;
      expect(await provider.playSong(
        third,
        queue: queue,
        startIndex: 2,
      ), isTrue);
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(provider.currentPosition, Duration.zero);

      session.states.add(_state(
        song: second,
        queueIndex: 1,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 24),
        activeDeckId: 'B',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(provider.currentPosition, Duration.zero);
      expect(provider.isPlaying, isTrue);

      // The session-level pause edge must still update immediately while the
      // stale timeline is fenced from changing the selected library track.
      session.states.add(_state(
        song: second,
        queueIndex: 1,
        playing: false,
        playWhenReady: false,
        position: const Duration(seconds: 25),
        activeDeckId: 'B',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(provider.isPlaying, isFalse);
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(provider.currentPosition, Duration.zero);
      expect(audioHandler.playbackState.value.playing, isFalse);
      expect(
        audioHandler.playbackState.value.controls
            .map((control) => control.action),
        contains(MediaControl.play.action),
        reason: 'A stale outgoing timeline must not leave system transport on Pause.',
      );

      // The opposite transport edge must also publish without waiting for the
      // selected timeline to catch up.
      session.states.add(_state(
        song: second,
        queueIndex: 1,
        playing: true,
        playWhenReady: true,
        position: const Duration(seconds: 26),
        activeDeckId: 'B',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(provider.isPlaying, isTrue);
      expect(provider.currentSong?.id, third.id);
      expect(provider.currentPosition, Duration.zero);
      expect(audioHandler.playbackState.value.playing, isTrue);
      expect(
        audioHandler.playbackState.value.controls
            .map((control) => control.action),
        contains(MediaControl.pause.action),
        reason: 'A stale outgoing timeline must not leave system transport on Play.',
      );

      // Once the selected item is published by Media3, its own state becomes
      // canonical again, including position and resumed transport state.
      session.deferLoadQueueState = false;
      session.currentSongValue = third;
      session.queueIndexValue = 2;
      session.durationValue = third.duration;
      session.positionValue = const Duration(seconds: 2);
      session.states.add(_state(
        song: third,
        queueIndex: 2,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(provider.currentPosition, const Duration(seconds: 2));
      expect(provider.isPlaying, isTrue);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('overlay cleanup failure does not skip DJ deck speed reset', () async {
      final session = _FakePlaybackSession()
        ..throwOnCrossfade = true
        ..throwOnClearDeckEqOverlay = true;
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('cleanup-failure-out');
      final second = _song('cleanup-failure-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 100 && !session.calls.contains('crossfade:failed');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.calls, contains('crossfade:failed'));
      for (var attempt = 0;
          attempt < 100 && !session.calls.contains('deckSpeeds:1.0:1.0');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(session.calls, contains('clearDeckEqOverlay:standby'));
      expect(
        session.calls,
        contains('deckSpeeds:1.0:1.0'),
        reason: 'A failed overlay clear must not strand a tempo-matched deck rate.',
      );
      expect(session.calls, contains('loadQueue'),
          reason: 'The selected queue fallback remains available after cleanup attempts.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('pause during crossfade fallback cannot be followed by a stale play', () async {
      final session = _FakePlaybackSession()
        ..throwOnCrossfade = true;
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('pause-fade-out');
      final second = _song('pause-fade-in');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(first, queue: <Song>[first, second]), isTrue);
      await provider.setCrossfadeDuration(500);
      // Ignore the expected cancel issued by the initial play command; only
      // hold the cleanup belonging to the deliberately failed crossfade.
      session.cancelCrossfadeGate = Completer<void>();

      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));

      for (var attempt = 0;
          attempt < 60 && !session.calls.contains('crossfade:failed');
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.calls, contains('crossfade:failed'));
      expect(session.calls, contains('cancelCrossfade'));

      final playCallsBeforePause =
          session.calls.where((call) => call == 'play').length;
      final pause = provider.pause();
      session.cancelCrossfadeGate!.complete();
      await pause;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(session.playingValue, isFalse);
      expect(
        session.calls.where((call) => call == 'play').length,
        playCallsBeforePause,
        reason: 'A failed crossfade fallback must not restart after Pause.',
      );

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('Pause after crossfade wins over a late Media3 completion callback', () async {
      final session = _FakePlaybackSession(synchronousStates: true);
      final provider = MusicProvider(media3ProviderSession: session);
      final first = _song('late-completion-outgoing');
      final second = _song('late-completion-incoming');
      final third = _song('late-completion-next');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(
        first,
        queue: <Song>[first, second, third],
      ), isTrue);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: first,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      for (var attempt = 0;
          attempt < 80 && provider.currentSong?.id != second.id;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.currentSong?.id, second.id);
      expect(session.calls, contains('crossfade:500'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final playCallsBeforeCompletion =
          session.calls.where((call) => call == 'play').length;
      session.playingValue = false;
      session.completedValue = true;
      session.positionValue = second.duration;
      session.states.add(_state(
        song: second,
        queueIndex: 1,
        completed: true,
        position: second.duration,
      ));
      // The synchronous fake stream starts the handler inline. Its first
      // diagnostic await yields, allowing Pause to supersede that completion.
      await provider.pause();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(session.playingValue, isFalse);
      expect(provider.currentSong?.id, second.id);
      expect(provider.queueIndex, 1);
      expect(
        session.calls.where((call) => call == 'play').length,
        playCallsBeforeCompletion,
        reason: 'A completion callback from the crossfaded track must not restart or advance after Pause.',
      );
      expect(
        session.calls.where((call) => call.startsWith('loadQueue')).length,
        1,
        reason: 'Late completion must not load the next queue item after Pause.',
      );

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('repeat-one hands off through the Media3 standby deck and returns to repeat-one', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('repeat-one-deck');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(song, queue: <Song>[song]), isTrue);
      await provider.setRepeatMode(PlaybackRepeatMode.one);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(seconds: 178);
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
        activeDeckId: 'A',
        repeatMode: 'one',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 240));

      expect(session.preloadedSong?.id, song.id);
      expect(session.preloadedIndex, 0);
      expect(session.preloadedStartPosition, Duration.zero);
      expect(session.calls, contains('repeat:off'));
      expect(session.crossfadeDuration, const Duration(milliseconds: 1600));
      expect(session.calls, contains('repeat:one'));
      expect(session.repeatModeSet, PlaybackQueueRepeatMode.one);
      expect(provider.activeEngineLabel, 'B');
      expect(provider.currentSong?.id, song.id);
      expect(provider.queueIndex, 0);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('turning Repeat One off invalidates a blocked same-track DJ preload', () async {
      final session = _FakePlaybackSession()
        ..preloadNextGate = Completer<void>();
      final provider = MusicProvider(media3ProviderSession: session);
      final song = _song('repeat-one-cancel-preload');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(song, queue: <Song>[song]), isTrue);
      await provider.setRepeatMode(PlaybackRepeatMode.one);
      await provider.setCrossfadeDuration(500);

      session.positionValue = const Duration(milliseconds: 178000);
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
        activeDeckId: 'A',
        repeatMode: 'one',
      ));
      for (var attempt = 0;
          attempt < 100 &&
              !session.calls.any((call) =>
                  call.startsWith('preloadNext:repeat-one-cancel-preload:'));
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        session.calls.any((call) =>
            call.startsWith('preloadNext:repeat-one-cancel-preload:')),
        isTrue,
        reason: 'Repeat One should prepare the same-track standby deck before the loop.',
      );

      await provider.setRepeatMode(PlaybackRepeatMode.off);
      expect(provider.repeatMode, PlaybackRepeatMode.off);
      expect(session.repeatModeSet, PlaybackQueueRepeatMode.off);
      expect(session.calls, contains('cancelCrossfade'));

      session.preloadNextGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        session.calls.where((call) => call.startsWith('crossfade:')),
        isEmpty,
        reason: 'A stale Repeat One preload must not start after Repeat Off.',
      );
      expect(session.repeatModeSet, PlaybackQueueRepeatMode.off);
      expect(provider.currentSong?.id, song.id);
      expect(provider.queueIndex, 0);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('clears an empty shadow queue and forwards Media3 audio-session IDs', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      final received = <int>[];
      provider.onAndroidSession = received.add;

      await provider.prepareMedia3ProviderSession();
      expect(session.calls, contains('clearQueue'));
      expect(session.calls.indexOf('focus:false'),
          lessThan(session.calls.indexOf('clearQueue')));

      session.audioSessions.add(73);
      await Future<void>.delayed(Duration.zero);
      expect(received, [73]);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
    });

    test('publishes canonical Media3 position to the system media notification', () async {
      final handler = AudioServiceHandler();
      final session = _FakePlaybackSession();
      final provider = MusicProvider(
        audioHandler: handler,
        media3ProviderSession: session,
      );
      final song = _song('notification-track');
      await provider.prepareMedia3ProviderSession();
      expect(await provider.playSong(song, queue: <Song>[song]), isTrue);

      // The legacy compatibility players are idle after handoff. The system
      // media state must nevertheless follow the progressing Media3 session,
      // including its actual playback rate.
      session.playbackSpeedValue = 1.5;
      session.positionValue = const Duration(seconds: 42);
      session.states.add(_state(
        song: song,
        queueIndex: 0,
        playing: true,
        playWhenReady: true,
        position: session.positionValue,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(handler.playbackState.value.updatePosition,
          const Duration(seconds: 42));
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.speed, 1.5,
          reason: 'Media notification must report the active Media3 playback speed.');

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await session.states.close();
    });

    test('does not mark the session prepared when startup fails', () async {
      final session = _FakePlaybackSession();
      final provider = MusicProvider(media3ProviderSession: session);
      // A failed focus-ownership handoff must leave the preparation flag false.
      // The fake throws before any queue or settings mirroring can begin.
      session.calls.clear();
      final failing = _FailingStartSession();
      final failingProvider = MusicProvider(media3ProviderSession: failing);

      await expectLater(
        failingProvider.prepareMedia3ProviderSession(),
        throwsStateError,
      );
      expect(failingProvider.media3ProviderSessionPrepared, isFalse);
      expect(failing.calls, ['start']);

      // Production playback must fail closed rather than lazily constructing
      // EnginePair/just_audio after Media3 startup has failed.
      final failedSong = _song('media3-startup-failure');
      expect(
        await failingProvider.playSong(
          failedSong,
          queue: <Song>[failedSong],
        ),
        isFalse,
      );
      expect(failingProvider.debugLegacyEngineConstructed, isFalse);

      provider.dispose();
      failingProvider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await failing.audioSessions.close();
    });

    test('approved Media3 DJ transition lookup consumes the exact adjacent pair once', () {
      final provider = MusicProvider();
      const candidate = DjTransitionCandidate(
        kind: DjTransitionKind.phraseBlend,
        outgoingStartMs: 160000,
        incomingStartMs: 12000,
        durationMs: 6000,
        score: 0.9,
        confidence: 0.9,
      );
      const plan = DjExecutionPlan(
        candidate: candidate,
        fallback: true,
        reason: 'insufficient_analysis_confidence',
      );

      provider.setApprovedDjTransitions({
        'outgoing-track\u0000incoming-track': plan,
      });

      expect(
        provider.takeApprovedDjTransition('outgoing-track', 'incoming-track'),
        same(plan),
      );
      expect(
        provider.takeApprovedDjTransition('outgoing-track', 'incoming-track'),
        isNull,
        reason: 'an approved plan is a one-shot handoff token',
      );
      provider.dispose();
    });
  });
}

class _PitchCapableFakePlaybackSession extends _FakePlaybackSession
    implements PlaybackPitchSession {
  double? pitchValue;

  @override
  Future<void> setPlaybackPitch(double pitch) async {
    pitchValue = pitch;
    calls.add('pitch:$pitch');
  }
}

class _FailingStartSession extends _FakePlaybackSession {
  @override
  Future<void> start() async {
    calls.add('start');
    throw StateError('simulated Media3 startup failure');
  }
}
