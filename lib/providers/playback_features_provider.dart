import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'music_provider.dart';
import '../services/playback_engine_session.dart';

class PlaybackFeaturesProvider extends ChangeNotifier {
  final MusicProvider music;
  double speed = 1.0;
  double pitch = 1.0;
  bool normalizationEnabled = false;
  double targetLoudness = -14.0;
  int sleepRemainingSeconds = 0;
  String? normalizedSongId;
  double _normalizationGainDb = 0.0;

  double get _normalizationTrackLevel => normalizationEnabled
      ? math.pow(10.0, _normalizationGainDb / 20.0).toDouble().clamp(0.0, 1.0).toDouble()
      : 1.0;
  Timer? _sleepTimer;
  String? _lastSongId;
  String? _lastEngine;
  int _sleepGeneration = 0;
  DateTime? _sleepDeadline;
  bool _sleepTickInFlight = false;
  // Serialize native sleep-fade mutations so a stale tick cannot reapply a
  // fade after cancellation or replacement has already cleared it.
  Future<void> _sleepFadeOperations = Future<void>.value();
  bool _disposed = false;

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _enqueueSleepFade(int generation, {double? scale}) {
    final operation = _sleepFadeOperations.then((_) async {
      if (generation != _sleepGeneration) return;
      if (scale == null) {
        await music.clearSleepFade();
      } else {
        await music.setSleepFadeScale(scale);
      }
    });
    _sleepFadeOperations = operation.catchError((Object error) {
      debugPrint('Sleep fade update failed: $error');
    });
    return _sleepFadeOperations;
  }

  PlaybackFeaturesProvider({required this.music}) {
    music.addListener(_syncEngineIfNeeded);
    _load();
  }

  bool get sleepTimerActive => sleepRemainingSeconds > 0;

  void _syncEngineIfNeeded() {
    if (_disposed) return;
    final songId = music.currentSong?.id;
    final engine = music.activeEngineLabel;
    if (songId == _lastSongId && engine == _lastEngine) return;
    _lastSongId = songId;
    _lastEngine = engine;
    unawaited(applyToActiveEngine());
  }

  Future<void> setSpeed(double value) async {
    // Media3 and the legacy engine share the same user-facing rate range.
    speed = value.clamp(0.5, 2.0).toDouble();
    try {
      final session = music.media3PlaybackSession;
      if (music.media3ProviderSessionActive && session != null) {
        await music.setPlaybackSpeedForFeatures(speed);
      } else {
        await music.setPlaybackSpeedForFeatures(speed);
      }
    } catch (e) {
      debugPrint('Playback speed failed: $e');
    }
    await _save();
    _notifyIfAlive();
  }

  Future<void> setPitch(double value) async {
    pitch = value.clamp(0.5, 2.0).toDouble();
    try {
      final session = music.media3PlaybackSession;
      if (music.media3ProviderSessionActive && session != null) {
        await music.setPlaybackPitchForFeatures(pitch);
      } else {
        await music.setPlaybackPitchForFeatures(pitch);
      }
    } catch (e) {
      debugPrint('Playback pitch failed: $e');
    }
    await _save();
    notifyListeners();
  }

  Future<void> setNormalizationEnabled(bool value) async {
    normalizationEnabled = value;
    await _applyNormalization();
    await _save();
    notifyListeners();
  }

  Future<void> setTargetLoudness(double value) async {
    targetLoudness = value.clamp(-20.0, -8.0).toDouble();
    if (normalizationEnabled) await _applyNormalization();
    await _save();
    notifyListeners();
  }

  Future<void> applyTrackGain(String songId, double gainDb) async {
    normalizedSongId = songId;
    _normalizationGainDb = gainDb.isFinite ? gainDb : 0.0;
    if (!normalizationEnabled) return;
    await _applyNormalization();
    notifyListeners();
  }

  Future<void> _applyNormalization() async {
    try {
      final session = music.media3PlaybackSession;
      if (music.media3ProviderSessionActive && session != null) {
        // Media3 composes track trim with preamp, sleep fade and focus duck
        // atomically. Track normalization is attenuation-only to avoid
        // introducing clipping when the source has unknown headroom.
        await music.setNormalizationForFeatures(
          targetGainMillibels: _normalizationGainDb * 100.0,
          enabled: normalizationEnabled,
          trackLevel: _normalizationTrackLevel,
        );
        return;
      }
      await music.setNormalizationForFeatures(
        targetGainMillibels: _normalizationGainDb * 100.0,
        enabled: normalizationEnabled,
        trackLevel: _normalizationTrackLevel,
      );
    } catch (e) {
      debugPrint('Volume normalization failed: $e');
    }
  }

  Future<void> applyToActiveEngine() async {
    if (_disposed) return;
    try {
      final session = music.media3PlaybackSession;
      if (music.media3ProviderSessionActive && session != null) {
        await music.setPlaybackSpeedForFeatures(speed.clamp(0.5, 2.0).toDouble());
        await music.setPlaybackPitchForFeatures(pitch.clamp(0.5, 2.0).toDouble());
        // Restore track trim on the newly active session/deck alongside rate
        // and pitch; the native gain policy preserves sleep/focus/preamp factors.
        await music.setNormalizationForFeatures(targetGainMillibels: _normalizationGainDb * 100.0, enabled: normalizationEnabled, trackLevel: _normalizationTrackLevel);
      } else {
        await music.setPlaybackSpeedForFeatures(speed);
        await music.setPlaybackPitchForFeatures(pitch);
      }
      if (!music.media3ProviderSessionActive && normalizationEnabled) {
        await _applyNormalization();
      } else if (!music.media3ProviderSessionActive) {
        await music.setNormalizationForFeatures(targetGainMillibels: 0.0, enabled: false, trackLevel: 1.0);
      }
    } catch (e) {
      debugPrint('Active playback feature sync failed: $e');
    }
  }

  static const int _fadeOutSeconds = 45;

  Future<void> startSleepTimer(Duration duration) async {
    if (_disposed) return;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final gen = ++_sleepGeneration;
    sleepRemainingSeconds = duration.inSeconds.clamp(1, 24 * 60 * 60);
    _sleepDeadline = DateTime.now().add(Duration(seconds: sleepRemainingSeconds));
    // Clear the previous fade before arming this timer. A newer start or
    // cancellation invalidates this queued operation by generation.
    await _enqueueSleepFade(gen);
    if (_disposed || gen != _sleepGeneration) return;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (gen != _sleepGeneration) {
        timer.cancel();
        return;
      }
      unawaited(_onSleepTick(timer, gen));
    });
    notifyListeners();
  }

  Future<void> _onSleepTick(Timer timer, int gen) async {
    if (gen != _sleepGeneration || _sleepTickInFlight) return;
    _sleepTickInFlight = true;
    try {
      final deadline = _sleepDeadline;
      if (deadline != null) {
        sleepRemainingSeconds = deadline.difference(DateTime.now()).inSeconds.clamp(0, 24 * 60 * 60);
      }
      if (sleepRemainingSeconds <= 0) {
        timer.cancel();
        sleepRemainingSeconds = 0;
        // Revalidate immediately before issuing the transport command. A timer
        // cancelled/replaced while a prior tick was awaiting must not pause audio.
        if (gen != _sleepGeneration) return;
        try {
          // Must go through MusicProvider so _userWantsPlaying is cleared.
          await music.pause(source: 'sleep_timer');
        } catch (e) {
          debugPrint('Sleep timer pause failed: $e');
        }
        await _enqueueSleepFade(gen);
        if (gen == _sleepGeneration) {
          _sleepDeadline = null;
          _notifyIfAlive();
        }
        return;
      }

      sleepRemainingSeconds =
          sleepRemainingSeconds.clamp(0, 24 * 60 * 60);
      if (sleepRemainingSeconds <= _fadeOutSeconds &&
          gen == _sleepGeneration) {
        final t =
            (sleepRemainingSeconds / _fadeOutSeconds).clamp(0.0, 1.0);
        await _enqueueSleepFade(gen, scale: t);
      }
      if (gen == _sleepGeneration) _notifyIfAlive();
    } finally {
      _sleepTickInFlight = false;
    }
  }

  void cancelSleepTimer() {
    if (_disposed) return;
    _sleepGeneration++;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepRemainingSeconds = 0;
    _sleepDeadline = null;
    unawaited(_enqueueSleepFade(_sleepGeneration));
    notifyListeners();
  }

  String get sleepTimerLabel {
    if (sleepRemainingSeconds <= 0) return 'Off';
    final hours = sleepRemainingSeconds ~/ 3600;
    final minutes = (sleepRemainingSeconds % 3600) ~/ 60;
    final seconds = sleepRemainingSeconds % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      speed = prefs.getDouble('playback_speed') ?? 1.0;
      pitch = prefs.getDouble('playback_pitch') ?? 1.0;
      normalizationEnabled = prefs.getBool('normalization_enabled') ?? false;
      targetLoudness = prefs.getDouble('target_loudness') ?? -14.0;
      await applyToActiveEngine();
      if (_disposed) return;
      _lastSongId = music.currentSong?.id;
      _lastEngine = music.activeEngineLabel;
    } catch (e) {
      debugPrint('Playback settings load failed: $e');
    }
    _notifyIfAlive();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playback_speed', speed);
      await prefs.setDouble('playback_pitch', pitch);
      await prefs.setBool('normalization_enabled', normalizationEnabled);
      await prefs.setDouble('target_loudness', targetLoudness);
    } catch (e) {
      debugPrint('Playback settings save failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    music.removeListener(_syncEngineIfNeeded);
    // Invalidate any asynchronous tick already in flight. Without advancing
    // the generation, a tick awaiting a fade update could still pause playback
    // after this provider has been torn down.
    _sleepGeneration++;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    sleepRemainingSeconds = 0;
    // Provider disposal must not leave a native/Media3 gain fade applied.
    unawaited(_enqueueSleepFade(_sleepGeneration));
    super.dispose();
  }
}
