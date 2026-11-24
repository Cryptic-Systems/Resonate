import 'dart:async';

import '../models/song.dart';
import 'media3_playback_runtime.dart';
import 'playback_snapshot.dart';

/// Projects the serialized Media3 runtime into the small state surface that
/// MusicProvider and its UI consumers need.
///
/// This is intentionally a state-only bridge: it never creates a player, issues
/// commands, or optimistically changes playback state. MusicProvider consumes
/// this projection as canonical state after its session handoff.
class Media3ProviderStateBridge {
  Media3ProviderStateBridge(this._runtime);

  final Media3PlaybackRuntime _runtime;
  final StreamController<Media3ProviderState> _states =
      StreamController<Media3ProviderState>.broadcast();

  StreamSubscription<Media3RuntimeState>? _subscription;
  Media3ProviderState _current = const Media3ProviderState.empty();
  bool _started = false;
  bool _disposed = false;

  Stream<Media3ProviderState> get states => _states.stream;
  Media3ProviderState get current => _current;

  /// Subscribes before publishing the runtime's current value, avoiding a gap
  /// where a state update could be lost during provider attachment.
  Future<void> start() async {
    if (_disposed) throw StateError('Media3ProviderStateBridge is disposed.');
    if (_started) return;
    _started = true;
    _subscription = _runtime.states.listen(_accept);
    _accept(_runtime.current);
  }

  void _accept(Media3RuntimeState state) {
    if (_disposed) return;
    final snapshot = state.snapshot;
    _current = Media3ProviderState(
      currentSong: state.currentSong,
      queueIndex: state.currentQueueIndex,
      isPlaying: state.isPlaying,
      position: state.position,
      bufferedPosition: snapshot?.bufferedPosition ?? Duration.zero,
      isBuffering: snapshot?.isBuffering ?? false,
      isCompleted: snapshot?.isCompleted ?? false,
      duration: state.duration,
      connected: state.connected,
      isReady: snapshot?.isReady ?? false,
      playWhenReady: snapshot?.playWhenReady ?? false,
      mediaId: snapshot?.mediaId,
      queueLength: snapshot?.queueLength ?? 0,
      volume: snapshot?.volume ?? 1.0,
      audioSessionId: snapshot?.audioSessionId,
      standbyAudioSessionId: snapshot?.standbyAudioSessionId,
      activeDeckId: snapshot?.activeDeckId ?? 'A',
      crossfadeStatus: snapshot?.crossfadeStatus ?? 'idle',
      crossfadeProgress: snapshot?.crossfadeProgress ?? 0.0,
      activeDeckVolume: snapshot?.activeDeckVolume ?? 1.0,
      standbyDeckVolume: snapshot?.standbyDeckVolume ?? 0.0,
      activeDeckSpeed: snapshot?.activeDeckSpeed,
      activeDeckPitch: snapshot?.activeDeckPitch,
      standbyDeckSpeed: snapshot?.standbyDeckSpeed,
      standbyDeckPitch: snapshot?.standbyDeckPitch,
      incomingMediaId: snapshot?.incomingMediaId,
      incomingReady: snapshot?.incomingReady ?? false,
      incomingPosition: snapshot?.incomingPosition ?? Duration.zero,
      djDualDeckMode: snapshot?.djDualDeckMode ?? false,
      djCrossfaderPosition: snapshot?.djCrossfaderPosition ?? 0.5,
      deckA: snapshot?.deckA,
      deckB: snapshot?.deckB,
      audioUnderrunCountA: snapshot?.audioUnderrunCountA ?? 0,
      audioUnderrunCountB: snapshot?.audioUnderrunCountB ?? 0,
      lastUnderrunDeck: snapshot?.lastUnderrunDeck,
      lastUnderrunBufferSizeFrames: snapshot?.lastUnderrunBufferSizeFrames ?? 0,
      lastUnderrunBufferSizeMs: snapshot?.lastUnderrunBufferSizeMs ?? 0,
      lastUnderrunElapsedSinceFeedMs: snapshot?.lastUnderrunElapsedSinceFeedMs ?? 0,
      lastUnderrunElapsedRealtimeMs: snapshot?.lastUnderrunElapsedRealtimeMs ?? 0,
      repeatMode: snapshot?.repeatMode ?? 'off',
      shuffleModeEnabled: snapshot?.shuffleModeEnabled ?? false,
      hasError: state.hasError,
      error: state.error,
    );
    // The empty runtime state is useful as the initial value but should not
    // masquerade as a native update to consumers until a snapshot exists.
    if (snapshot != null && !_states.isClosed) _states.add(_current);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    await _states.close();
  }
}

/// Immutable provider-facing state; playback truth always comes from Media3.
class Media3ProviderState {
  const Media3ProviderState({
    required this.currentSong,
    required this.queueIndex,
    required this.isPlaying,
    required this.position,
    this.bufferedPosition = Duration.zero,
    this.isBuffering = false,
    this.isCompleted = false,
    required this.duration,
    required this.connected,
    required this.isReady,
    required this.playWhenReady,
    required this.mediaId,
    required this.queueLength,
    required this.volume,
    this.audioSessionId,
    this.standbyAudioSessionId,
    this.activeDeckId = 'A',
    this.crossfadeStatus = 'idle',
    this.crossfadeProgress = 0.0,
    this.activeDeckVolume = 1.0,
    this.standbyDeckVolume = 0.0,
    this.activeDeckSpeed,
    this.activeDeckPitch,
    this.standbyDeckSpeed,
    this.standbyDeckPitch,
    this.incomingMediaId,
    this.incomingReady = false,
    this.incomingPosition = Duration.zero,
    this.djDualDeckMode = false,
    this.djCrossfaderPosition = 0.5,
    this.deckA,
    this.deckB,
    this.audioUnderrunCountA = 0,
    this.audioUnderrunCountB = 0,
    this.lastUnderrunDeck,
    this.lastUnderrunBufferSizeFrames = 0,
    this.lastUnderrunBufferSizeMs = 0,
    this.lastUnderrunElapsedSinceFeedMs = 0,
    this.lastUnderrunElapsedRealtimeMs = 0,
    this.repeatMode = 'off',
    this.shuffleModeEnabled = false,
    required this.hasError,
    required this.error,
  });

  const Media3ProviderState.empty()
      : currentSong = null,
        queueIndex = null,
        isPlaying = false,
        position = Duration.zero,
        bufferedPosition = Duration.zero,
        isBuffering = false,
        isCompleted = false,
        duration = null,
        connected = false,
        isReady = false,
        playWhenReady = false,
        mediaId = null,
        queueLength = 0,
        volume = 1.0,
        audioSessionId = null,
        standbyAudioSessionId = null,
        activeDeckId = 'A',
        crossfadeStatus = 'idle',
        crossfadeProgress = 0.0,
        activeDeckVolume = 1.0,
        standbyDeckVolume = 0.0,
        activeDeckSpeed = null,
        activeDeckPitch = null,
        standbyDeckSpeed = null,
        standbyDeckPitch = null,
        incomingMediaId = null,
        incomingReady = false,
        incomingPosition = Duration.zero,
        djDualDeckMode = false,
        djCrossfaderPosition = 0.5,
        deckA = null,
        deckB = null,
        audioUnderrunCountA = 0,
        audioUnderrunCountB = 0,
        lastUnderrunDeck = null,
        lastUnderrunBufferSizeFrames = 0,
        lastUnderrunBufferSizeMs = 0,
        lastUnderrunElapsedSinceFeedMs = 0,
        lastUnderrunElapsedRealtimeMs = 0,
        repeatMode = 'off',
        shuffleModeEnabled = false,
        hasError = false,
        error = null;

  final Song? currentSong;
  final int? queueIndex;
  final bool isPlaying;
  final Duration position;
  final Duration bufferedPosition;
  final bool isBuffering;
  final bool isCompleted;
  final Duration? duration;
  final bool connected;
  final bool isReady;
  final bool playWhenReady;
  final String? mediaId;
  final int queueLength;
  final double volume;

  /// Android session owned by the active Media3 deck. It can change at a
  /// crossfade handoff, so consumers must follow state updates rather than
  /// cache the first non-null value indefinitely.
  final int? audioSessionId;
  /// Prepared standby deck's Android audio session, when allocated.
  final int? standbyAudioSessionId;

  /// Physical Media3 deck currently owning canonical playback.
  final String activeDeckId;
  final String crossfadeStatus;
  final double crossfadeProgress;
  final double activeDeckVolume;
  final double standbyDeckVolume;
  /// Native Media3 parameters; null means not reported by the service.
  final double? activeDeckSpeed;
  final double? activeDeckPitch;
  final double? standbyDeckSpeed;
  final double? standbyDeckPitch;
  final String? incomingMediaId;
  final bool incomingReady;
  final Duration incomingPosition;
  final bool djDualDeckMode;
  final double djCrossfaderPosition;
  final PlaybackDeckSnapshot? deckA;
  final PlaybackDeckSnapshot? deckB;
  final int audioUnderrunCountA;
  final int audioUnderrunCountB;
  final String? lastUnderrunDeck;
  final int lastUnderrunBufferSizeFrames;
  final int lastUnderrunBufferSizeMs;
  final int lastUnderrunElapsedSinceFeedMs;
  final int lastUnderrunElapsedRealtimeMs;

  final String repeatMode;
  final bool shuffleModeEnabled;
  final bool hasError;
  final String? error;
}