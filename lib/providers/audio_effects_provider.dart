import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/dsp_settings.dart';
import '../services/audio_effects_bridge.dart';
import '../services/playback_engine_session.dart';
import '../services/media3_provider_state_bridge.dart';

class AudioEffectsProvider extends ChangeNotifier {
  /// The single source of playback session IDs for auxiliary effects.
  /// Media3 reports both active and standby deck sessions during crossfade.
  final PlaybackEngineSession? playbackSession;
  double reverb = 0.0;
  double bassBoost = 0.0;
  double virtualizer = 0.0;
  double loudness = 0.0;
  bool effectsEnabled = true;

  StreamSubscription<Media3ProviderState>? _media3SessionSubscription;
  final Set<int> _media3SessionIds = <int>{};
  Future<void> _nativeApplyQueue = Future<void>.value();

  AudioEffectsProvider({this.playbackSession}) {
    // Media3 exposes both physical deck sessions. Subscribe to its canonical
    // state stream so auxiliary effects follow preload, overlap, and promotion.
    if (playbackSession != null) {
      // Both physical Media3 decks have independent Android audio sessions.
      // Attach session-bound Reverb/Virtualizer to the standby deck before it
      // is promoted, rather than waiting for the active-session ID to change.
      _media3SessionSubscription = playbackSession!.stateStream.listen(
        _onMedia3State,
        onError: (Object error) {
          debugPrint('Media3 audio-effects state stream failed: $error');
        },
      );
    }
    _load();
  }

  bool _isSessionTracked(int sessionId) =>
      _media3SessionIds.contains(sessionId);

  void _onMedia3State(Media3ProviderState state) {
    final nextIds = <int>{
      if (state.audioSessionId != null && state.audioSessionId! > 0)
        state.audioSessionId!,
      if (state.standbyAudioSessionId != null &&
          state.standbyAudioSessionId! > 0)
        state.standbyAudioSessionId!,
    };
    final removed = _media3SessionIds.difference(nextIds);
    final added = nextIds.difference(_media3SessionIds);
    _media3SessionIds
      ..clear()
      ..addAll(nextIds);
    for (final id in removed) {
      if (!_isSessionTracked(id)) unawaited(_detachNativeSession(id));
    }
    if (added.isNotEmpty) {
      // Serialize attach + effect application for each newly prepared deck.
      for (final id in added) {
        unawaited(_applyNative(sessionIdOverride: id));
      }
    }
  }

  Future<void> setEffectsEnabled(bool value) async {
    effectsEnabled = value;
    await _applyNative();
    await _save();
    notifyListeners();
  }

  Future<void> setReverb(double value) async {
    reverb = value.clamp(0.0, 1.0).toDouble();
    await _applyNative();
    await _save();
    notifyListeners();
  }

  /// Legacy bass control retained for settings compatibility.
  ///
  /// BassBoost is intentionally not applied to the audio session anymore:
  /// the mature Resonate DSP owns bass shaping, speaker protection and
  /// virtual-bass processing. Keeping this value prevents old preferences/UI
  /// state from breaking while avoiding a second bass processor.
  Future<void> setBassBoost(double value) async {
    bassBoost = value.clamp(0.0, 1.0).toDouble();
    await _disableLegacyBassBoost();
    await _save();
    notifyListeners();
  }

  Future<void> setVirtualizer(double value) async {
    virtualizer = value.clamp(0.0, 1.0).toDouble();
    await _applyNative();
    await _save();
    notifyListeners();
  }

  /// Loudness enhancer is retired — Resonate DSP preamp owns overall level.
  /// Kept as a no-op so older saved prefs cannot re-enable it.
  Future<void> setLoudness(double value) async {
    loudness = 0.0;
    await _save();
    notifyListeners();
  }

  Future<void> _detachNativeSession(int sessionId) {
    _nativeApplyQueue = _nativeApplyQueue
        .catchError((_) {})
        .then((_) => AudioEffectsBridge.detachFromSession(sessionId));
    return _nativeApplyQueue;
  }

  Future<void> _applyNative({int? sessionIdOverride}) {
    // AndroidEffectsBridge has a current-session selector, so each attach +
    // apply sequence must be serialized to prevent A/B calls interleaving.
    _nativeApplyQueue = _nativeApplyQueue
        .catchError((_) {})
        .then((_) => _applyNativeNow(sessionIdOverride: sessionIdOverride));
    return _nativeApplyQueue;
  }

  Future<void> _applyNativeNow({int? sessionIdOverride}) async {
    final sessionIds = sessionIdOverride != null
        ? <int>{sessionIdOverride}
        : <int>{..._media3SessionIds};
    if (sessionIds.isEmpty) return;

    final enabled = effectsEnabled;
    for (final sessionId in sessionIds) {
      try {
        await AudioEffectsBridge.attachToSession(sessionId);
        // BassBoost is retired from the active path. Mature DSP owns all bass
        // processing; applying Android BassBoost here would stack another EQ.
        await AudioEffectsBridge.setBassBoost(0.0);
        await AudioEffectsBridge.setVirtualizer(enabled ? virtualizer : 0.0);
        await AudioEffectsBridge.setReverb(enabled ? reverb : 0.0);
      } catch (e) {
        debugPrint('Native audio effects failed for session $sessionId: $e');
      }
    }

  }

  Future<void> _disableLegacyBassBoost() async {
    try {
      await AudioEffectsBridge.setBassBoost(0.0);
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final canonical = await DspSettings.load();
      // Restore the canonical native protection profile at startup. Registry
      // sticky state carries these values to both Media3 decks, including a
      // sink created after this provider finishes loading.
      await AudioEffectsBridge.setLiveDspLimiterCeiling(
        highDb: canonical.limiterHighCeilingDb,
        lowDb: canonical.limiterLowCeilingDb,
      );
      await AudioEffectsBridge.setLiveDspCrossoverHz(canonical.crossoverHz);
      // DVC is independent from EQ preamp and must be restored even when the
      // user has not opened Audio automation in this process. Registry state
      // carries it to both current and subsequently-created A/B sinks.
      await AudioEffectsBridge.setLiveDspDvc(
        enabled: canonical.dvcEnabled,
        db: canonical.dvcDb,
        smoothing: canonical.dvcSmoothing,
        smoothingMs: canonical.dvcSmoothingMs,
      );
      await AudioEffectsBridge.setLiveDspLimiterConfig(
        enabled: canonical.limiterEnabled,
        mode: canonical.limiterMode,
        thresholdDb: canonical.limiterThresholdDb,
        releaseMs: canonical.limiterReleaseMs,
        attackMs: canonical.limiterAttackMs,
        lookaheadMs: canonical.limiterLookaheadMs,
        kneeDb: canonical.limiterKneeDb,
      );
      await AudioEffectsBridge.setLiveDspDither(
        enabled: canonical.ditherEnabled,
        mode: canonical.ditherMode,
      );
      effectsEnabled = canonical.effectsEnabled;
      reverb = canonical.reverbAmount;
      virtualizer = canonical.virtualizerAmount;
      bassBoost = prefs.getDouble('bassBoost') ?? 0.0;
      // Always force loudness off (legacy prefs ignored).
      loudness = 0.0;
      // If playback/session creation raced the preference load, apply the
      // restored settings now to every currently known A/B session.
      await _applyNative();
      notifyListeners();
    } catch (e) {
      debugPrint('Audio effects load failed: $e');
    }
  }

  Future<void> reset() async {
    effectsEnabled = true;
    reverb = 0.0;
    bassBoost = 0.0;
    virtualizer = 0.0;
    loudness = 0.0;
    await _disableLegacyBassBoost();
    await _applyNative();
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('bassBoost', bassBoost);
      await prefs.setDouble('loudness', loudness);
      // Keep legacy keys readable by older builds while canonical state owns
      // effect enable/reverb/virtualizer settings.
      await prefs.setBool('effects_enabled', effectsEnabled);
      await prefs.setDouble('reverb', reverb);
      await prefs.setDouble('virtualizer', virtualizer);
      await DspSettings.update((settings) => settings.copyWith(
            effectsEnabled: effectsEnabled,
            reverbAmount: reverb,
            virtualizerAmount: virtualizer,
          ));
    } catch (e) {
      debugPrint('Audio effects save failed: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_media3SessionSubscription?.cancel());
    _media3SessionSubscription = null;
    _media3SessionIds.clear();
    AudioEffectsBridge.release();
    super.dispose();
  }
}
