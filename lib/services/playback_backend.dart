import '../models/song.dart';
import 'playback_snapshot.dart';

/// The transport/state contract a playback engine must provide to Resonate.
///
/// This contract is engine-neutral. DSP, audio-session routing, leveling,
/// focus ducking, and crossfade must be integrated into the chosen backend's
/// runtime before MusicProvider switches production playback authority.
abstract interface class PlaybackBackend {
  Stream<PlaybackSnapshot> get states;

  Future<void> loadQueue(List<Song> songs, {int startIndex = 0});
  Future<void> clearQueue();
  Future<PlaybackSnapshot> currentState();

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setVolume(double value);
  Future<void> setGainFactors({
    double? trackLevel,
    double? preamp,
    double? sleepFade,
    double? focusDuck,
  });
  Future<void> setRepeatMode(PlaybackQueueRepeatMode mode);
  Future<void> setShuffleMode(bool enabled);
}

/// Optional capability for explicit ownership of Android audio-focus requests.
/// Disabling requests is safe only after another playback owner has taken over.
abstract interface class PlaybackAudioFocusBackend {
  Future<void> setAudioFocusHandling(bool enabled);
}

/// Optional playback-rate capability. Backends without native speed support
/// remain valid, but the provider-facing session must report it as unsupported.
abstract interface class PlaybackSpeedBackend {
  Future<void> setPlaybackSpeed(double speed);
}

/// Optional capability for DJ transitions that require independent rates on
/// the outgoing and prepared incoming Media3 decks.
abstract interface class PlaybackDeckSpeedBackend {
  Future<void> setDeckPlaybackSpeeds({
    required double activeSpeed,
    required double standbySpeed,
  });
}

/// Optional capability for DJ transition filters that target one deck only.
abstract interface class PlaybackDeckEqOverlayBackend {
  Future<void> setDeckEqOverlay({
    required String deck,
    required List<double> centersHz,
    required List<double> gainsDb,
  });
  Future<void> clearDeckEqOverlay({required String deck});
}

/// Optional capability for short auxiliary effects owned by the playback backend.
/// Auxiliary audio is mixed by the Media3 service and never replaces the
/// canonical queue item or creates a second MediaSession/transport authority.
abstract interface class PlaybackAuxiliaryEffectsBackend {
  Future<void> playAuxiliarySound(
    Uri uri, {
    required double volume,
    Duration startPosition = Duration.zero,
    Duration? endPosition,
  });
  Future<void> setAuxiliarySoundVolume(double volume);
  Future<void> stopAuxiliarySound();
}

/// Optional capability for reconciling queue edits without resetting the active player.
/// Backends that do not implement this retain their existing full-load fallback.
abstract interface class PlaybackPlaylistSyncBackend {
  Future<void> synchronizeQueue(List<Song> songs);
}

/// Optional crossfade capability for engines that own two synchronized decks.
/// A backend without this capability must not emulate a crossfade by starting a
/// second independent playback authority.
abstract interface class PlaybackCrossfadeBackend {
  Future<void> preloadNext(
    Song song, {
    List<Song>? queue,
    int? startIndex,
    Duration startPosition = Duration.zero,
  });
  Future<void> crossfade({required Duration duration});
  Future<void> cancelCrossfade();
}

/// Repeat behavior shared by backend implementations.
enum PlaybackQueueRepeatMode {
  off('off'),
  one('one'),
  all('all');

  const PlaybackQueueRepeatMode(this.nativeValue);

  final String nativeValue;
}
