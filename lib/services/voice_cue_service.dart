import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_cue_router.dart';

/// Manifest-backed short voice feedback. Original recordings and dynamics are
/// preserved; this service does not normalize or transcode audio.
class VoiceCueService {
  VoiceCueService._()
      : _player = AudioPlayer(handleAudioSessionActivation: false);

  static final VoiceCueService instance = VoiceCueService._();
  static const String _manifestAsset =
      'assets/audio/resonate_voice/voice_manifest.json';
  static const String _enabledKey = 'resonate_voice_feedback_enabled';
  static const String _assetRoot = 'assets/audio/resonate_voice/';

  final AudioPlayer _player;
  final VoiceCueRouter _router = VoiceCueRouter();
  Map<String, Map<String, dynamic>>? _manifest;
  bool _speaking = false;
  bool _requestInFlight = false;
  int _generation = 0;
  Future<void>? _loading;

  bool get isSpeaking => _speaking;

  Future<void> setEnabled(bool enabled) async {
    if (!enabled) _generation++;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledKey, enabled);
    if (!enabled) {
      try {
        await _player.stop();
      } catch (_) {}
      _speaking = false;
      _router.resetSession();
    }
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
    } catch (error, stack) {
      completer.completeError(error, stack);
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
    if (_requestInFlight || _speaking) return false;
    _requestInFlight = true;
    final generation = _generation;
    String? reservedGroup;
    try {
      if (!await isEnabled() || generation != _generation) return false;
      await _ensureManifest();
      if (generation != _generation || !await isEnabled()) return false;

      final entry = _manifest?[cueId];
      if (entry == null || entry['runtimeEnabled'] != true) return false;
      final assetPath = entry['assetPath'];
      if (assetPath is! String ||
          !assetPath.startsWith(_assetRoot) ||
          assetPath.contains('..') ||
          assetPath.contains('\\') ||
          !assetPath.endsWith('.mp3')) {
        debugPrint('Resonate voice cue has an unsafe asset path ($cueId)');
        return false;
      }

      final route = _parseRoute(entry['routingProposal']);
      if (route == null) return false;
      final groupValue = entry['semanticGroupProposal'];
      if (groupValue is! String || groupValue.trim().isEmpty) return false;
      final group = groupValue;
      final manifestOrigins = (entry['allowedOrigins'] as List<dynamic>?)
              ?.map(_parseOrigin)
              .whereType<VoiceCueOrigin>()
              .toSet() ??
          <VoiceCueOrigin>{};
      final origins = allowedOrigins == null
          ? manifestOrigins.toList()
          : manifestOrigins.intersection(allowedOrigins.toSet()).toList();
      if (route == VoiceCueRoute.conditional && origins.isEmpty) return false;

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
      reservedGroup = group;

      await _player.setAudioSource(AudioSource.asset(assetPath));
      if (generation != _generation || !await isEnabled()) {
        _router.release(eventId: eventId, semanticGroup: group);
        reservedGroup = null;
        try {
          await _player.stop();
        } catch (_) {}
        return false;
      }

      _speaking = true;
      final playback = _player.play();
      unawaited(playback.catchError((Object error, StackTrace stack) {
        _router.release(eventId: eventId, semanticGroup: group);
        debugPrint('Resonate voice cue failed ($cueId): $error');
      }).whenComplete(() {
        _speaking = false;
      }));
      reservedGroup = null;
      return true;
    } catch (error) {
      _speaking = false;
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
    await _player.dispose();
    _router.resetSession();
  }
}
