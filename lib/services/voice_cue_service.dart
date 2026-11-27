import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_cue_router.dart';

/// Filename-manifest-backed voice playback.
///
/// The cue player is separate from the music player and does not request audio
/// focus, so short voice feedback can layer over ongoing music. Original MP3
/// dynamics are preserved; this service does not normalize or alter gain.
class VoiceCueService {
  VoiceCueService._()
      : _player = AudioPlayer(handleAudioSessionActivation: false);

  static final VoiceCueService instance = VoiceCueService._();

  static const String _manifestAsset =
      'assets/audio/resonate_voice/voice_manifest.json';
  static const String _enabledKey = 'resonate_voice_feedback_enabled';

  final AudioPlayer _player;
  final VoiceCueRouter _router = VoiceCueRouter();
  Map<String, Map<String, dynamic>>? _manifest;
  bool _speaking = false;
  Future<void>? _loading;

  bool get isSpeaking => _speaking;

  Future<void> setEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledKey, enabled);
  }

  Future<bool> isEnabled() async {
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
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final entries = decoded['assets'] as List<dynamic>;
      final indexed = <String, Map<String, dynamic>>{};
      for (final value in entries) {
        final entry = value as Map<String, dynamic>;
        final id = entry['id'] as String?;
        if (id != null && id.isNotEmpty) indexed[id] = entry;
      }
      _manifest = indexed;
      completer.complete();
    } catch (error, stack) {
      completer.completeError(error, stack);
      rethrow;
    } finally {
      _loading = null;
    }
  }

  /// Play one stable manifest cue for a confirmed application event.
  ///
  /// Callers provide a unique event ID. Repeated variants for the same event
  /// and semantic group are deduplicated by [VoiceCueRouter].
  Future<bool> speak({
    required String cueId,
    required VoiceCueOrigin origin,
    required String eventId,
    bool confirmed = true,
    List<VoiceCueOrigin>? allowedOrigins,
  }) async {
    if (_speaking || !await isEnabled()) return false;

    try {
      await _ensureManifest();
      final entry = _manifest?[cueId];
      if (entry == null ||
          entry['runtimeEnabled'] != true ||
          entry['assetPath'] is! String) {
        return false;
      }

      final route = _parseRoute(entry['routingProposal'] as String?);
      if (route == null) return false;
      final group = entry['semanticGroupProposal'] as String? ?? '';
      final origins = allowedOrigins ??
          (entry['allowedOrigins'] as List<dynamic>?)
              ?.map(_parseOrigin)
              .whereType<VoiceCueOrigin>()
              .toList();

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
      if (!decision.allowed) return false;

      final assetPath = entry['assetPath'] as String;
      try {
        await _player.setAudioSource(AudioSource.asset(assetPath));
        _speaking = true;
        final playback = _player.play();
        unawaited(playback.catchError((Object error, StackTrace stack) {
          _router.release(eventId: eventId, semanticGroup: group);
          debugPrint('Resonate voice cue failed ($cueId): $error');
        }).whenComplete(() {
          _speaking = false;
        }));
        return true;
      } catch (error) {
        _speaking = false;
        _router.release(eventId: eventId, semanticGroup: group);
        debugPrint('Resonate voice cue could not start ($cueId): $error');
        return false;
      }
    } catch (error) {
      debugPrint('Resonate voice manifest unavailable: $error');
      return false;
    }
  }

  VoiceCueRoute? _parseRoute(String? value) {
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
    await _player.dispose();
    _router.resetSession();
  }
}
