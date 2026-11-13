import 'dart:async';

import 'package:flutter/services.dart';

import '../models/song.dart';

/// Immutable playback snapshot published by the native Media3 session.
class Media3PlaybackState {
  const Media3PlaybackState({
    required this.connected,
    required this.isPlaying,
    required this.playbackState,
    this.isBuffering = false,
    this.isCompleted = false,
    required this.playWhenReady,
    required this.position,
    this.bufferedPosition = Duration.zero,
    required this.duration,
    required this.mediaId,
    required this.title,
    required this.artist,
    required this.album,
    required this.currentMediaItemIndex,
    required this.mediaItemCount,
    required this.volume,
    this.audioSessionId,
    this.repeatMode = 'off',
    this.shuffleModeEnabled = false,
    required this.hasError,
    required this.error,
  });

  final bool connected;
  final bool isPlaying;
  final int playbackState;
  final bool isBuffering;
  final bool isCompleted;
  final bool playWhenReady;
  final Duration position;
  final Duration bufferedPosition;
  final Duration? duration;
  final String? mediaId;
  final String? title;
  final String? artist;
  final String? album;
  final int currentMediaItemIndex;
  final int mediaItemCount;
  final double volume;
  /// Active ExoPlayer audio session; can change when the crossfade decks swap.
  final int? audioSessionId;
  final String repeatMode;
  final bool shuffleModeEnabled;
  final bool hasError;
  final String? error;

  factory Media3PlaybackState.fromMap(Map<Object?, Object?> map) {
    int integerValue(Object? value, [int fallback = 0]) =>
        value is num && value.isFinite ? value.toInt() : fallback;
    double doubleValue(Object? value, [double fallback = 1.0]) =>
        value is num && value.isFinite ? value.toDouble() : fallback;
    bool boolValue(Object? value) => value == true;
    String? stringValue(Object? value) => value is String ? value : null;

    final rawDuration = map['durationMs'];
    return Media3PlaybackState(
      connected: boolValue(map['connected']),
      isPlaying: boolValue(map['isPlaying']),
      playbackState: integerValue(map['playbackState']),
      isBuffering: boolValue(map['isBuffering']),
      isCompleted: boolValue(map['isCompleted']),
      playWhenReady: boolValue(map['playWhenReady']),
      position: Duration(
        milliseconds: integerValue(map['positionMs']).clamp(0, 0x7fffffff).toInt(),
      ),
      bufferedPosition: Duration(
        milliseconds: integerValue(map['bufferedPositionMs'])
            .clamp(0, 0x7fffffff)
            .toInt(),
      ),
      duration: rawDuration is num &&
              rawDuration.isFinite &&
              rawDuration >= 0
          ? Duration(milliseconds: rawDuration.toInt().clamp(0, 0x7fffffff).toInt())
          : null,
      mediaId: stringValue(map['mediaId']),
      title: stringValue(map['title']),
      artist: stringValue(map['artist']),
      album: stringValue(map['album']),
      currentMediaItemIndex: integerValue(map['currentMediaItemIndex'], -1),
      mediaItemCount: integerValue(map['mediaItemCount']),
      volume: doubleValue(map['volume']).clamp(0.0, 1.0).toDouble(),
      audioSessionId: integerValue(map['audioSessionId'], 0) > 0
          ? integerValue(map['audioSessionId'])
          : null,
      repeatMode: const {'off', 'one', 'all'}.contains(map['repeatMode'])
          ? map['repeatMode'] as String
          : 'off',
      shuffleModeEnabled: boolValue(map['shuffleModeEnabled']),
      hasError: boolValue(map['hasError']),
      error: stringValue(map['error']),
    );
  }
}

/// Typed command/state boundary for native Media3 playback.
class Media3PlaybackClient {
  Media3PlaybackClient({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel = methodChannel ??
            const MethodChannel('com.aetherion.resonate/media3'),
        _eventChannel = eventChannel ??
            const EventChannel('com.aetherion.resonate/media3_events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Stream<Media3PlaybackState> get states => _eventChannel
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => Media3PlaybackState.fromMap(
            Map<Object?, Object?>.from(event as Map),
          ));

  Future<void> setSource(Uri uri) async {
    if (!uri.hasScheme) {
      throw ArgumentError.value(uri, 'uri', 'A URI with a scheme is required.');
    }
    await _invokeAccepted(
      'setSource',
      <String, Object>{'uri': uri.toString()},
    );
  }

  /// Loads a native Media3 queue and selects [startIndex] as the active item.
  /// Queue items are immutable metadata + URI descriptors; native Player objects
  /// never cross the Flutter boundary.
  Future<void> setQueue(
    List<Media3QueueItem> items, {
    int startIndex = 0,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'Queue must not be empty.');
    }
    if (startIndex < 0 || startIndex >= items.length) {
      throw ArgumentError.value(startIndex, 'startIndex', 'Must point to an item in the queue.');
    }
    await _invokeAccepted(
      'setQueue',
      <String, Object>{
        'items': items.map((item) => item.toMap()).toList(growable: false),
        'startIndex': startIndex,
      },
    );
  }

  /// Reconciles a live queue edit while preserving the currently playing item
  /// when possible. An empty list is treated as an explicit queue clear.
  Future<void> synchronizeQueue(List<Media3QueueItem> items) async {
    if (items.isEmpty) {
      await clearQueue();
      return;
    }
    final mappedItems = items.map((item) => item.toMap()).toList(growable: false);
    await _invokeAccepted(
      'synchronizeQueue',
      <String, Object>{'items': mappedItems},
    );
  }

  /// Clears the active queue and any prepared crossfade deck.
  Future<void> clearQueue() => _command('clearQueue');

  Future<void> skipToNext() => _command('skipToNext');
  Future<void> skipToPrevious() => _command('skipToPrevious');

  Future<void> setRepeatMode(String mode) async {
    if (!const {'off', 'one', 'all'}.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'Must be off, one, or all.');
    }
    await _invokeAccepted(
      'setRepeatMode',
      <String, Object>{'mode': mode},
    );
  }

  Future<void> setShuffleMode(bool enabled) async {
    await _invokeAccepted(
      'setShuffleMode',
      <String, Object>{'enabled': enabled},
    );
  }

  Future<void> play() => _command('play');
  Future<void> pause() => _command('pause');
  Future<void> stop() => _command('stop');

  Future<void> seekTo(Duration position) async {
    if (position.isNegative) {
      throw ArgumentError.value(position, 'position', 'Must not be negative.');
    }
    await _invokeAccepted(
      'seekTo',
      <String, Object>{'positionMs': position.inMilliseconds},
    );
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (!speed.isFinite || speed < 0.5 || speed > 2.0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and between 0.5 and 2.0.');
    }
    await _invokeAccepted('setPlaybackSpeed', <String, Object>{'speed': speed});
  }

  Future<void> setDeckPlaybackSpeeds({
    required double activeSpeed,
    required double standbySpeed,
  }) async {
    for (final entry in <String, double>{
      'activeSpeed': activeSpeed,
      'standbySpeed': standbySpeed,
    }.entries) {
      if (!entry.value.isFinite || entry.value < 0.5 || entry.value > 2.0) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'Must be finite and between 0.5 and 2.0.',
        );
      }
    }
    await _invokeAccepted('setDeckPlaybackSpeeds', <String, Object>{
      'activeSpeed': activeSpeed,
      'standbySpeed': standbySpeed,
    });
  }

  /// Applies a temporary EQ curve to one logical deck. The native DSP
  /// registry composes this overlay with the persistent Resonate EQ curve.
  Future<void> setDeckEqOverlay({
    required String deck,
    required List<double> centersHz,
    required List<double> gainsDb,
  }) async {
    if (deck != 'active' && deck != 'standby') {
      throw ArgumentError.value(deck, 'deck', 'Must be active or standby.');
    }
    if (centersHz.isEmpty || centersHz.length != gainsDb.length ||
        centersHz.length > 31) {
      throw ArgumentError('EQ overlay requires 1–31 matching frequency/gain bands.');
    }
    for (var i = 0; i < centersHz.length; i++) {
      final frequency = centersHz[i];
      final gain = gainsDb[i];
      if (!frequency.isFinite || frequency < 20.0 || frequency > 20000.0) {
        throw ArgumentError.value(frequency, 'centersHz[$i]', 'Must be 20–20000 Hz.');
      }
      if (!gain.isFinite || gain < -12.0 || gain > 12.0) {
        throw ArgumentError.value(gain, 'gainsDb[$i]', 'Must be -12–12 dB.');
      }
      if (i > 0 && frequency <= centersHz[i - 1]) {
        throw ArgumentError.value(frequency, 'centersHz[$i]', 'Frequencies must be strictly increasing.');
      }
    }
    await _invokeAccepted('setDeckEqOverlay', <String, Object>{
      'deck': deck,
      'centersHz': centersHz,
      'gainsDb': gainsDb,
    });
  }

  Future<void> clearDeckEqOverlay({required String deck}) async {
    if (deck != 'active' && deck != 'standby') {
      throw ArgumentError.value(deck, 'deck', 'Must be active or standby.');
    }
    await _invokeAccepted('clearDeckEqOverlay', <String, Object>{'deck': deck});
  }

  /// Plays a short sample through the service-owned auxiliary Media3 player.
  /// The main queue, MediaSession and audio-focus owner remain unchanged.
  Future<void> playAuxiliarySound(
    Uri uri, {
    required double volume,
    Duration startPosition = Duration.zero,
    Duration? endPosition,
  }) async {
    if (!uri.hasScheme ||
        !const {'asset', 'file', 'content', 'http', 'https'}.contains(uri.scheme)) {
      throw ArgumentError.value(uri, 'uri', 'A supported media URI is required.');
    }
    if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(volume, 'volume', 'Must be finite and between 0 and 1.');
    }
    if (startPosition.isNegative ||
        (endPosition != null && (endPosition.isNegative || endPosition <= startPosition))) {
      throw ArgumentError('Auxiliary clip end must be greater than its non-negative start.');
    }
    await _invokeAccepted('playAuxiliarySound', <String, Object>{
      'uri': uri.toString(),
      'volume': volume,
      'startPositionMs': startPosition.inMilliseconds,
      if (endPosition != null) 'endPositionMs': endPosition.inMilliseconds,
    });
  }

  Future<void> setAuxiliarySoundVolume(double volume) async {
    if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(volume, 'volume', 'Must be finite and between 0 and 1.');
    }
    await _invokeAccepted('setAuxiliarySoundVolume', <String, Object>{'volume': volume});
  }

  Future<void> stopAuxiliarySound() => _command('stopAuxiliarySound');

  /// Controls whether the Media3 active deck requests Android audio focus.
  /// Disable only when another playback owner has explicitly taken over focus.
  Future<void> setAudioFocusHandling(bool enabled) async {
    await _invokeAccepted(
      "setAudioFocusHandling",
      <String, Object>{"enabled": enabled},
    );
  }

  Future<void> setVolume(double volume) async {
    if (!volume.isFinite) {
      throw ArgumentError.value(volume, 'volume', 'Must be finite.');
    }
    await _invokeAccepted(
      'setVolume',
      <String, Object>{'value': volume.clamp(0.0, 1.0).toDouble()},
    );
  }

  /// Sets the non-crossfade output factors as one atomic gain-policy update.
  /// Track level, sleep fade and focus duck are normalized to [0, 1]. Preamp
  /// is a linear gain in [0, 4] so positive preamp can boost before output cap.
  Future<void> setGainFactors({
    double trackLevel = 1.0,
    double preamp = 1.0,
    double sleepFade = 1.0,
    double focusDuck = 1.0,
  }) async {
    final factors = <String, double>{
      'trackLevel': trackLevel,
      'preamp': preamp,
      'sleepFade': sleepFade,
      'focusDuck': focusDuck,
    };
    for (final entry in factors.entries) {
      final max = entry.key == 'preamp' ? 4.0 : 1.0;
      if (!entry.value.isFinite || entry.value < 0 || entry.value > max) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          entry.key == 'preamp'
              ? 'Must be finite and between 0 and 4.'
              : 'Must be finite and between 0 and 1.',
        );
      }
    }
    await _invokeAccepted('setGainFactors', factors);
  }

  Future<void> preloadNext(
    Media3QueueItem item, {
    List<Media3QueueItem>? queue,
    int startIndex = 0,
    Duration startPosition = Duration.zero,
  }) async {
    if (startPosition.isNegative) {
      throw ArgumentError.value(
        startPosition,
        'startPosition',
        'Must not be negative.',
      );
    }
    final items = queue ?? <Media3QueueItem>[item];
    if (items.isEmpty) {
      throw ArgumentError.value(items.length, 'queue', 'Queue must not be empty.');
    }
    if (startIndex < 0 || startIndex >= items.length) {
      throw ArgumentError.value(startIndex, 'startIndex', 'Must identify the incoming item.');
    }
    if (items[startIndex].id != item.id || items[startIndex].uri != item.uri) {
      throw ArgumentError('The selected queue occurrence must match the incoming item.');
    }
    await _invokeAccepted(
      'preloadNext',
      <String, Object?>{
        'item': item.toMap(),
        'items': items.map((entry) => entry.toMap()).toList(growable: false),
        'startIndex': startIndex,
        'positionMs': startPosition.inMilliseconds,
      },
    );
  }

  Future<void> crossfade({Duration duration = const Duration(seconds: 5)}) async {
    if (duration < const Duration(milliseconds: 250) ||
        duration > const Duration(seconds: 15)) {
      throw ArgumentError.value(duration, 'duration', 'Must be between 250 ms and 15 s.');
    }
    await _invokeAccepted(
      'crossfade',
      <String, Object>{'durationMs': duration.inMilliseconds},
    );
  }

  Future<void> cancelCrossfade() => _command('cancelCrossfade');

  Future<Map<Object?, Object?>> getCrossfadeState() async {
    final state = await _methodChannel.invokeMapMethod<Object?, Object?>('crossfadeState');
    return state ?? <Object?, Object?>{'status': 'unknown'};
  }

  Future<Media3PlaybackState> getState() async {
    final value = await _methodChannel.invokeMapMethod<Object?, Object?>('getState');
    if (value == null) {
      throw StateError('Native Media3 bridge returned no playback state.');
    }
    return Media3PlaybackState.fromMap(value);
  }

  Future<void> _command(String method) async {
    await _invokeAccepted(method);
  }

  /// Native commands acknowledge acceptance with true. Treat false or a
  /// missing acknowledgement as failure so the Dart runtime cannot commit
  /// state for a queue/transport operation the native service rejected.
  Future<void> _invokeAccepted(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final accepted = await _methodChannel.invokeMethod<bool>(method, arguments);
    if (accepted != true) {
      throw PlatformException(
        code: 'MEDIA3_COMMAND_REJECTED',
        message: 'Native Media3 did not accept "$method".',
      );
    }
  }
}


/// Queue descriptor sent to the native Media3 session.
class Media3QueueItem {
  const Media3QueueItem({
    required this.id,
    required this.uri,
    required this.title,
    this.artist,
    this.album,
    this.artworkUri,
  });

  final String id;
  final Uri uri;
  final String title;
  final String? artist;
  final String? album;
  final Uri? artworkUri;

  factory Media3QueueItem.fromSong(Song song) {
    final rawPath = song.filePath.trim();
    if (rawPath.isEmpty) {
      throw ArgumentError.value(song.filePath, 'song.filePath', 'Media path must not be empty.');
    }
    Uri asUri(String value) {
      final parsed = Uri.tryParse(value);
      if (parsed != null && parsed.hasScheme) return parsed;
      return Uri.file(value);
    }

    final art = song.albumArt?.trim() ?? '';
    return Media3QueueItem(
      id: song.id,
      uri: asUri(rawPath),
      title: song.title,
      artist: song.artist,
      album: song.album,
      artworkUri: art.isEmpty ? null : asUri(art),
    );
  }

  Map<String, Object?> toMap() {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Queue item ID must not be empty.');
    }
    if (!uri.hasScheme) {
      throw ArgumentError.value(uri, 'uri', 'A URI with a scheme is required.');
    }
    if (artworkUri != null && !artworkUri!.hasScheme) {
      throw ArgumentError.value(artworkUri, 'artworkUri', 'Artwork URI must have a scheme.');
    }
    return <String, Object?>{
      'id': id,
      'uri': uri.toString(),
      'title': title,
      if (artist != null) 'artist': artist!,
      if (album != null) 'album': album!,
      if (artworkUri != null) 'artworkUri': artworkUri.toString(),
    };
  }
}
