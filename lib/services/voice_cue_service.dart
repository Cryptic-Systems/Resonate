import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_cue_router.dart';
import 'workspace_lifecycle_coordinator.dart';

/// Manifest-backed short voice feedback. Original recordings and dynamics are
/// preserved; this service does not normalize or transcode audio.
class VoiceCueService implements WorkspaceLifecycleParticipant {
  VoiceCueService._();

  static final VoiceCueService instance = VoiceCueService._();
  static const String _manifestAsset =
      'assets/audio/resonate_voice/voice_manifest.json';
  static const String _enabledKey = 'resonate_voice_feedback_enabled';
  static const String _assetRoot = 'assets/audio/resonate_voice/';

  AudioPlayer? _player;
  AudioPlayer get _audioPlayer => _player ??= AudioPlayer(
        // Voice cues must mix over Media3 without requesting audio focus or
        // subscribing to interruption handling that can pause the main track.
        handleAudioSessionActivation: false,
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
      );

  Future<void> _configureVoicePlayer(AudioPlayer player) {
    final existing = _playerConfiguration;
    if (existing != null) return existing;
    final configuration = () async {
      // Android's shared audio_session configuration is owned by the music
      // transport. Give the independent cue player explicit speech attributes on the
      // media output route, without claiming focus or changing Media3's attributes.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await player.setAndroidAudioAttributes(
          const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage.media,
          ),
        );
      }
      await player.setVolume(1.0);
    }();
    _playerConfiguration = configuration;
    return configuration.catchError((Object error) {
      _playerConfiguration = null;
      throw error;
    });
  }

  void _logBlocked(String cueId, String reason) {
    debugPrint('Resonate voice cue blocked (' + cueId + '): ' + reason);
  }
  final VoiceCueRouter _router = VoiceCueRouter();
  Map<String, Map<String, dynamic>>? _manifest;
  bool _speaking = false;
  bool _requestInFlight = false;
  bool _settingsChangeInFlight = false;
  bool? _enabledOverride;
  int _generation = 0;
  int _workspaceGeneration = 0;
  ResonateWorkspace _activeWorkspace = ResonateWorkspace.player;
  WorkspaceLifecycleCoordinator? _workspaceLifecycle;
  VoiceCueOrigin? _speakingOrigin;
  Future<void>? _loading;
  Future<void>? _playerConfiguration;
  Future<void> Function(bool active)? _musicDucking;

  void attachMusicDucking(Future<void> Function(bool active) callback) {
    _musicDucking = callback;
  }

  Future<void> _setMusicDucked(bool active) async {
    try {
      await _musicDucking?.call(active);
    } catch (error) {
      debugPrint('Resonate voice cue music duck update failed: $error');
    }
  }

  bool get isSpeaking => _speaking;

  void attachWorkspaceLifecycle(WorkspaceLifecycleCoordinator coordinator) {
    if (identical(_workspaceLifecycle, coordinator)) return;
    _workspaceLifecycle?.unregister(this);
    _workspaceLifecycle = coordinator;
    _activeWorkspace = coordinator.activeWorkspace;
    coordinator.register(this);
  }

  bool _originAllowedInWorkspace(VoiceCueOrigin origin) =>
      voiceCueOriginAllowedInWorkspace(origin, _activeWorkspace);

  bool _hasFlutterServicesBinding() {
    try {
      ServicesBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> onWorkspaceChanged(ResonateWorkspace workspace) async {
    if (_activeWorkspace == workspace) return;
    _activeWorkspace = workspace;
    _workspaceGeneration++;
    final speakingOrigin = _speakingOrigin;
    if (speakingOrigin != null && !_originAllowedInWorkspace(speakingOrigin)) {
      final player = _player;
      if (player != null) {
        try {
          await player.stop();
        } catch (_) {}
      }
      _speaking = false;
      _speakingOrigin = null;
      await _setMusicDucked(false);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    // Invalidate pending source loads on every preference change and block
    // new requests until persistence/stop work is settled.
    final generation = ++_generation;
    _enabledOverride = enabled;
    _settingsChangeInFlight = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_enabledKey, enabled);
      if (generation != _generation) return;
      if (!enabled) {
        try {
          await _player?.stop();
        } catch (_) {}
        _speaking = false;
        _speakingOrigin = null;
        await _setMusicDucked(false);
        _router.resetSession();
      }
    } finally {
      if (generation == _generation) _settingsChangeInFlight = false;
    }
  }

  Future<bool> isEnabled() async {
    final override = _enabledOverride;
    if (override != null) return override;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? true;
  }

  Future<void> _ensureManifest() async {
    if (_manifest != null) return;
    final pending = _loading;
    if (pending != null) {
      await pending;
      return;
    }
    final completer = Completer<void>();
    _loading = completer.future;
    try {
      final raw = await rootBundle.loadString(_manifestAsset);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['assets'] is! List) {
        throw const FormatException('Invalid Resonate voice manifest structure');
      }
      final indexed = <String, Map<String, dynamic>>{};
      for (final value in decoded['assets'] as List<dynamic>) {
        if (value is! Map<String, dynamic>) continue;
        final id = value['id'];
        if (id is String && id.trim().isNotEmpty && !indexed.containsKey(id)) {
          indexed[id] = value;
        }
      }
      _manifest = indexed;
      completer.complete();
    } catch (_) {
      // The initiating request receives the original error and handles it.
      // Complete the shared waiter normally so an unobserved pending future
      // cannot surface as an uncaught async error in tests or early startup.
      if (!completer.isCompleted) completer.complete();
      rethrow;
    } finally {
      _loading = null;
    }
  }

  Future<bool> speak({
    required String cueId,
    required VoiceCueOrigin origin,
    required String eventId,
    bool confirmed = true,
    List<VoiceCueOrigin>? allowedOrigins,
  }) async {
    if (!_hasFlutterServicesBinding()) {
      _logBlocked(cueId, 'Flutter services binding is not ready');
      return false;
    }
    if (_settingsChangeInFlight) {
      _logBlocked(cueId, 'voice preference update is in progress');
      return false;
    }
    if (_requestInFlight) {
      _logBlocked(cueId, 'another cue is loading');
      return false;
    }
    if (_speaking) {
      _logBlocked(cueId, 'another cue is already playing');
      return false;
    }
    if (!_originAllowedInWorkspace(origin)) {
      _logBlocked(cueId, 'origin is not allowed in the active workspace');
      return false;
    }
    _requestInFlight = true;
    final generation = _generation;
    final workspaceGeneration = _workspaceGeneration;
    String? reservedGroup;
    try {
      if (!await isEnabled() || generation != _generation ||
          workspaceGeneration != _workspaceGeneration ||
          !_originAllowedInWorkspace(origin)) {
        _logBlocked(cueId, 'disabled or request became stale before manifest load');
        return false;
      }
      await _ensureManifest();
      if (generation != _generation ||
          workspaceGeneration != _workspaceGeneration ||
          !_originAllowedInWorkspace(origin) ||
          _settingsChangeInFlight ||
          !await isEnabled()) {
        _logBlocked(cueId, 'disabled or request became stale after manifest load');
        return false;
      }

      final entry = _manifest?[cueId];
      if (entry == null) {
        _logBlocked(cueId, 'cue ID is missing from the manifest');
        return false;
      }
      if (entry['runtimeEnabled'] != true) {
        _logBlocked(cueId, 'cue is not runtime-enabled');
        return false;
      }
      final assetPath = entry['assetPath'];
      final category = entry['category'];
      final filename = entry['filename'];
      if (assetPath is! String ||
          category is! String ||
          filename is! String ||
          !assetPath.startsWith(_assetRoot) ||
          category.codeUnits.contains(92) ||
          filename.contains('/') ||
          filename.codeUnits.contains(92) ||
          assetPath.split('/').contains('..') ||
          assetPath.contains('\\') ||
          !assetPath.endsWith('.mp3') ||
          assetPath != '$_assetRoot$category/$filename') {
        debugPrint('Resonate voice cue has an unsafe asset path ($cueId)');
        return false;
      }

      final route = _parseRoute(entry['routingProposal']);
      if (route == null) {
        _logBlocked(cueId, 'manifest route is invalid');
        return false;
      }
      final groupValue = entry['semanticGroupProposal'];
      if (groupValue is! String || groupValue.trim().isEmpty) {
        _logBlocked(cueId, 'manifest semantic group is invalid');
        return false;
      }
      final group = groupValue;
      final manifestOrigins = (entry['allowedOrigins'] as List<dynamic>?)
              ?.map(_parseOrigin)
              .whereType<VoiceCueOrigin>()
              .toSet() ??
          <VoiceCueOrigin>{};
      final origins = allowedOrigins == null
          ? manifestOrigins.toList()
          : manifestOrigins.intersection(allowedOrigins.toSet()).toList();
      if (route == VoiceCueRoute.conditional && origins.isEmpty) {
        _logBlocked(cueId, 'manifest and call-site origin permissions do not intersect');
        return false;
      }

      final decision = _router.evaluate(VoiceCueRequest(
        cueId: cueId,
        route: route,
        origin: origin,
        eventId: eventId,
        semanticGroup: group,
        voiceFeedbackEnabled: true,
        confirmed: confirmed,
        expiresAt: DateTime.now().add(const Duration(seconds: 20)),
        allowedOrigins: origins,
      ));
      if (!decision.allowed) {
        _logBlocked(cueId, 'router rejected cue: ' + decision.reason.toString());
        return false;
      }
      reservedGroup = group;

      final player = _audioPlayer;
      await _configureVoicePlayer(player);
      await player.setAudioSource(AudioSource.asset(assetPath));
      if (generation != _generation ||
          workspaceGeneration != _workspaceGeneration ||
          !_originAllowedInWorkspace(origin) ||
          _settingsChangeInFlight ||
          !await isEnabled()) {
        _router.release(eventId: eventId, semanticGroup: group);
        reservedGroup = null;
        try {
          await player.stop();
        } catch (_) {}
        _logBlocked(cueId, 'request became stale before native playback started');
        return false;
      }

      _speaking = true;
      _speakingOrigin = origin;
      await _setMusicDucked(true);
      if (generation != _generation ||
          workspaceGeneration != _workspaceGeneration ||
          !_originAllowedInWorkspace(origin) ||
          _settingsChangeInFlight ||
          !await isEnabled()) {
        _speaking = false;
        _speakingOrigin = null;
        await _setMusicDucked(false);
        _router.release(eventId: eventId, semanticGroup: group);
        reservedGroup = null;
        return false;
      }
      debugPrint('Resonate voice cue starting (' + cueId + ', ' + entry['filename'].toString() + ')');
      final playback = player.play();
      unawaited(playback.timeout(const Duration(seconds: 20)).then<void>((_) {
        debugPrint('Resonate voice cue completed (' + cueId + ')');
      }, onError: (Object error, StackTrace stack) async {
        _router.release(eventId: eventId, semanticGroup: group);
        debugPrint('Resonate voice cue failed or timed out (' + cueId + '): ' + error.toString());
        try {
          await player.stop();
        } catch (_) {}
      }).whenComplete(() async {
        _speaking = false;
        _speakingOrigin = null;
        await _setMusicDucked(false);
      }));
      reservedGroup = null;
      return true;
    } catch (error) {
      _speaking = false;
      _speakingOrigin = null;
      await _setMusicDucked(false);
      _logBlocked(cueId, 'playback preparation failed: ' + error.toString());
      if (reservedGroup != null) {
        _router.release(eventId: eventId, semanticGroup: reservedGroup);
      }
      debugPrint('Resonate voice cue could not start ($cueId): $error');
      return false;
    } finally {
      _requestInFlight = false;
    }
  }

  VoiceCueRoute? _parseRoute(dynamic value) {
    switch (value) {
      case 'player_auto':
        return VoiceCueRoute.playerAuto;
      case 'dj_manual':
        return VoiceCueRoute.djManual;
      case 'both_contextual':
        return VoiceCueRoute.bothContextual;
      case 'shared_system':
        return VoiceCueRoute.sharedSystem;
      case 'conditional':
        return VoiceCueRoute.conditional;
      default:
        return null;
    }
  }

  VoiceCueOrigin? _parseOrigin(dynamic value) {
    switch (value) {
      case 'playerAuto':
        return VoiceCueOrigin.playerAuto;
      case 'djManual':
        return VoiceCueOrigin.djManual;
      case 'sharedSystem':
        return VoiceCueOrigin.sharedSystem;
      default:
        return null;
    }
  }

  Future<void> dispose() async {
    _generation++;
    _workspaceLifecycle?.unregister(this);
    _workspaceLifecycle = null;
    final player = _player;
    _player = null;
    if (player != null) await player.dispose();
    await _setMusicDucked(false);
    _musicDucking = null;
    _router.resetSession();
  }
}
