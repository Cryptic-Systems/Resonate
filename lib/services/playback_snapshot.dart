/// Engine-neutral playback state consumed by Resonate's provider and UI.
///
/// This deliberately avoids Media3/ExoPlayer types so a backend can be swapped
/// without making MusicProvider depend on a particular native engine.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.connected,
    required this.isPlaying,
    required this.isReady,
    required this.playWhenReady,
    required this.position,
    this.bufferedPosition = Duration.zero,
    this.isBuffering = false,
    this.isCompleted = false,
    required this.duration,
    required this.mediaId,
    required this.title,
    required this.artist,
    required this.album,
    required this.currentQueueIndex,
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

  final bool connected;
  final bool isPlaying;
  final bool isReady;
  final bool playWhenReady;
  final Duration position;
  final Duration bufferedPosition;
  final bool isBuffering;
  final bool isCompleted;
  final Duration? duration;
  final String? mediaId;
  final String? title;
  final String? artist;
  final String? album;
  final int currentQueueIndex;
  final int queueLength;
  /// Active native audio session, when the backend exposes one.
  final int? audioSessionId;
  /// Prepared standby deck's Android audio session, when allocated.
  final int? standbyAudioSessionId;
  /// Physical A/B deck currently promoted as the canonical playback deck.
  final String activeDeckId;
  final String crossfadeStatus;
  final double crossfadeProgress;
  final double activeDeckVolume;
  final double standbyDeckVolume;
  /// Native per-deck speed/pitch; null means unavailable.
  final double? activeDeckSpeed;
  final double? activeDeckPitch;
  final double? standbyDeckSpeed;
  final double? standbyDeckPitch;
  /// Incoming standby identity and readiness, independent of physical A/B role.
  final String? incomingMediaId;
  final bool incomingReady;
  final Duration incomingPosition;
  /// Cumulative native underruns attributed to physical A/B output decks.
  final int audioUnderrunCountA;
  final int audioUnderrunCountB;
  final String? lastUnderrunDeck;
  final int lastUnderrunBufferSizeFrames;
  final int lastUnderrunBufferSizeMs;
  final int lastUnderrunElapsedSinceFeedMs;
  final int lastUnderrunElapsedRealtimeMs;
  final double volume;
  /// Current queue repeat policy: `off`, `one`, or `all`.
  final String repeatMode;
  final bool shuffleModeEnabled;
  final bool hasError;
  final String? error;
}
