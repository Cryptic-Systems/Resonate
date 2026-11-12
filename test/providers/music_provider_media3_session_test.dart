import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/providers/music_provider.dart';
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

class _FakePlaybackSession implements PlaybackEngineSession {
  final StreamController<int?> audioSessions =
      StreamController<int?>.broadcast();
  final List<String> calls = <String>[];
  final StreamController<Media3ProviderState> states =
      StreamController<Media3ProviderState>.broadcast();
  List<Song> queue = <Song>[];
  int? loadedIndex;
  PlaybackQueueRepeatMode? repeatModeSet;
  bool? shuffleModeSet;
  double? volumeSet;
  bool? focusHandling;
  bool disposed = false;

  @override
  Stream<int?> get audioSessionIdStream => audioSessions.stream;

  @override
  Stream<Media3ProviderState> get stateStream => states.stream;

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> setAudioFocusHandling(bool enabled) async {
    focusHandling = enabled;
    calls.add('focus:$enabled');
  }

  @override
  Future<void> loadQueue(List<Song> songs, {int startIndex = 0}) async {
    queue = List<Song>.of(songs);
    loadedIndex = startIndex;
    calls.add('loadQueue');
  }

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
  Future<void> setVolume(double value) async {
    volumeSet = value;
    calls.add('volume:$value');
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

      await provider.enqueueSongs(<Song>[_song('one'), _song('two')]);
      await provider.setRepeatMode(PlaybackRepeatMode.all);
      await provider.setShuffleEnabled(true);
      final expectedQueue = provider.queue.map((song) => song.id).toList();

      await provider.prepareMedia3ProviderSession();

      expect(provider.media3ProviderSessionPrepared, isTrue);
      expect(provider.media3ShadowState, isNull,
          reason: 'No Media3 snapshot has been published by the fake session.');
      expect(session.calls, [
        'start',
        'focus:false',
        'loadQueue',
        'repeat:all',
        'shuffle:true',
        'volume:1.0',
        'focus:true',
      ]);
      expect(session.queue.map((song) => song.id).toList(), expectedQueue);
      expect(session.loadedIndex, provider.queueIndex);
      expect(session.repeatModeSet, PlaybackQueueRepeatMode.all);
      expect(session.shuffleModeSet, isTrue);
      expect(session.volumeSet, 1.0);
      expect(session.focusHandling, isTrue,
          reason: 'Media3 owns audio focus after the provider handoff is committed.');
      expect(provider.media3ProviderSessionActive, isTrue);

      provider.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(session.disposed, isTrue);
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

      provider.dispose();
      failingProvider.dispose();
      await Future<void>.delayed(Duration.zero);
      await session.audioSessions.close();
      await failing.audioSessions.close();
    });
  });
}

class _FailingStartSession extends _FakePlaybackSession {
  @override
  Future<void> start() async {
    calls.add('start');
    throw StateError('simulated Media3 startup failure');
  }
}
