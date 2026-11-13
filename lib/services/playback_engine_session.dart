import '../models/song.dart';
import 'playback_backend.dart';
import 'playback_observation_source.dart';
import 'media3_provider_state_bridge.dart';

/// A provider-facing playback session.
///
/// Observations and commands belong to the same session so the provider cannot
/// read state from Media3 while sending transport commands to just_audio (or
/// vice versa). Production selection requires parity for the responsibilities
/// routed through this contract; remaining feature-specific cutover gates are
/// tracked separately in the Media3 execution plan.
abstract interface class PlaybackEngineSession
    implements PlaybackObservationSource {
  /// Immutable, reconciled snapshots from the same backend that receives this
  /// session's commands. Consumers must not combine this with another player.
  Stream<Media3ProviderState> get stateStream;
  Future<void> start();
  List<Song> get queue;

  /// Synchronous snapshot of the same engine that receives transport commands.
  /// These values are reconciled from backend state; they are never optimistic.
  Song? get currentSong;
  int? get queueIndex;
  bool get isPlaying;
  Duration get position;
  Duration get bufferedPosition;
  Duration? get duration;
  bool get isBuffering;
  bool get isCompleted;
  bool get isReady;
  bool get hasError;
  String? get error;
  double get volume;
  double get playbackSpeed;
  PlaybackQueueRepeatMode get repeatMode;
  bool get shuffleModeEnabled;

  /// Emits the active native audio session, including changes at deck handoff.
  /// A null value means the backend has no active session to attach DSP to.
  Stream<int?> get audioSessionIdStream;

  Future<void> loadQueue(List<Song> songs, {int startIndex = 0});
  Future<void> synchronizeQueue(List<Song> songs);
  Future<void> clearQueue();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setPlaybackSpeed(double speed);
  Future<void> setDeckPlaybackSpeeds({
    required double activeSpeed,
    required double standbySpeed,
  });
  Future<void> setDeckEqOverlay({
    required String deck,
    required List<double> centersHz,
    required List<double> gainsDb,
  });
  Future<void> clearDeckEqOverlay({required String deck});
  Future<void> setVolume(double value);

  /// Enables or disables focus requests from this session's active Media3 deck.
  /// Disable only after another playback owner has explicitly taken over focus.
  Future<void> setAudioFocusHandling(bool enabled);
  Future<void> setGainFactors({
    double? trackLevel,
    double? preamp,
    double? sleepFade,
    double? focusDuck,
  });
  Future<void> setRepeatMode(PlaybackQueueRepeatMode mode);
  Future<void> setShuffleMode(bool enabled);

  Future<void> preloadNext(
    Song song, {
    int? queueIndex,
    Duration startPosition = Duration.zero,
  });
  Future<void> crossfade({required Duration duration});
  Future<void> cancelCrossfade();

  Future<void> dispose();
}
