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
    this.activeDeckId = 'A',
    this.crossfadeStatus = 'idle',
    this.crossfadeProgress = 0.0,
    this.activeDeckVolume = 1.0,
    this.standbyDeckVolume = 0.0,
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
  /// Physical A/B deck currently promoted as the canonical playback deck.
  final String activeDeckId;
  final String crossfadeStatus;
  final double crossfadeProgress;
  final double activeDeckVolume;
  final double standbyDeckVolume;
  final double volume;
  /// Current queue repeat policy: `off`, `one`, or `all`.
  final String repeatMode;
  final bool shuffleModeEnabled;
  final bool hasError;
  final String? error;
}
