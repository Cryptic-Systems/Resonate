import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/playback/queue_store.dart';
import 'package:resonate/providers/music_provider.dart';
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
  Map<String, double?>? gainFactors;
  Song? preloadedSong;
  int? preloadedIndex;
  Duration? preloadedStartPosition;
  Duration? crossfadeDuration;
  (double, double)? deckSpeeds;
  bool disposed = false;
  bool throwOnCrossfade = false;
  Completer<void>? cancelCrossfadeGate;
  Song? currentSongValue;
  int? queueIndexValue;
  bool playingValue = false;
  bool readyValue = true;
  bool completedValue = false;
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
    currentSongValue = songs.isEmpty ? null : songs[startIndex];
    queueIndexValue = songs.isEmpty ? null : startIndex;
    durationValue = currentSongValue?.duration;
    positionValue = Duration.zero;
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
    deckSpeeds = (activeSpeed, standbySpeed);
    calls.add('deckSpeeds:${activeSpeed}:${standbySpeed}');
  }

  @override
  Future<void> preloadNext(
    Song song, {
    int? queueIndex,
    Duration startPosition = Duration.zero,
  }) async {
    preloadedSong = song;
    preloadedIndex = queueIndex;
    preloadedStartPosition = startPosition;
    calls.add('preloadNext:${song.id}:${queueIndex}:${startPosition.inMilliseconds}');
  }

  @override
  Future<void> crossfade({required Duration duration}) async {
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
      final loadIndex = session.calls.lastIndexOf('loadQueue');
      expect(cancelIndex, greaterThanOrEqualTo(0),
          reason: 'Queue selection must invalidate a prepared native standby deck.');
      expect(loadIndex, greaterThan(cancelIndex),
          reason: 'The requested queue occurrence must load after cancellation.');
      expect(provider.currentSong?.id, third.id);
      expect(provider.queueIndex, 2);
      expect(session.currentSong?.id, third.id);

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
  });
}

class _FailingStartSession extends _FakePlaybackSession {
  @override
  Future<void> start() async {
    calls.add('start');
    throw StateError('simulated Media3 startup failure');
  }
}
