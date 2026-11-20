import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/dsp_settings.dart';
import '../playback/playback_control_arbiter.dart';
import '../services/audio_effects_bridge.dart';
import '../services/playback_engine_session.dart';
import '../services/media3_provider_state_bridge.dart';

class AudioEffectsProvider extends ChangeNotifier {
  /// The single source of playback session IDs for auxiliary effects.
  /// Media3 reports both active and standby deck sessions during crossfade.
  final PlaybackEngineSession? playbackSession;
  final PlaybackControlArbiter? playbackControlArbiter;
  double reverb = 0.0;
  double bassBoost = 0.0;
  double virtualizer = 0.0;
  double loudness = 0.0;
  bool effectsEnabled = true;

  StreamSubscription<Media3ProviderState>? _media3SessionSubscription;
  final Set<int> _media3SessionIds = <int>{};
  Future<void> _nativeApplyQueue = Future<void>.value();
  late final Future<void> ready;

  AudioEffectsProvider({this.playbackSession, this.playbackControlArbiter}) {
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
    ready = _load();
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
        unawaited(_applyNative(
          sessionIdOverride: id,
          priority: PlaybackControlPriority.background,
        ));
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

  Future<void> _applyNative({
    int? sessionIdOverride,
    PlaybackControlPriority priority = PlaybackControlPriority.interactive,
  }) {
    // AndroidEffectsBridge has a current-session selector, so each attach +
    // apply sequence must be serialized to prevent A/B calls interleaving.
    _nativeApplyQueue = _nativeApplyQueue
        .catchError((_) {})
        .then((_) => _applyNativeNow(
              sessionIdOverride: sessionIdOverride,
              priority: priority,
            ));
    return _nativeApplyQueue;
  }

  Future<void> _applyNativeNow({
    int? sessionIdOverride,
    required PlaybackControlPriority priority,
  }) async {
    final sessionIds = sessionIdOverride != null
        ? <int>{sessionIdOverride}
        : <int>{..._media3SessionIds};
    if (sessionIds.isEmpty) return;

    final enabled = effectsEnabled;
    await _withDspProfileLease(
      operation: 'audio_effects_profile',
      priority: priority,
      action: (lease) async {
        for (final sessionId in sessionIds) {
          try {
            if (!_authorizeDspWrite(lease, 'attach_session:$sessionId')) return;
            await AudioEffectsBridge.attachToSession(sessionId);
            if (!_authorizeDspWrite(lease, 'disable_legacy_bass')) return;
            // BassBoost is retired from the active path. Mature DSP owns all
            // bass processing; applying it here would stack another EQ.
            await AudioEffectsBridge.setBassBoost(0.0);
            if (!_authorizeDspWrite(lease, 'virtualizer:$sessionId')) return;
            await AudioEffectsBridge.setVirtualizer(
              enabled ? virtualizer : 0.0,
            );
            if (!_authorizeDspWrite(lease, 'reverb:$sessionId')) return;
            await AudioEffectsBridge.setReverb(enabled ? reverb : 0.0);
          } catch (e) {
            debugPrint('Native audio effects failed for session $sessionId: $e');
          }
        }
      },
    );
  }

  Future<void> _withDspProfileLease({
    required String operation,
    required PlaybackControlPriority priority,
    required Future<void> Function(PlaybackControlLease? lease) action,
  }) async {
    final arbiter = playbackControlArbiter;
    if (arbiter == null) {
      await action(null);
      return;
    }
    final lease = await arbiter.acquire(
      owner: 'dsp_profile_${priority.name}',
      priority: priority,
    );
    if (lease == null) return;
    try {
      if (!lease.authorizeWrite(operation)) return;
      await action(lease);
    } finally {
      await lease.release();
    }
  }

  bool _authorizeDspWrite(PlaybackControlLease? lease, String operation) =>
      lease == null || lease.authorizeWrite(operation);

  Future<void> _disableLegacyBassBoost() async {
    await _withDspProfileLease(
      operation: 'disable_legacy_bass',
      priority: PlaybackControlPriority.interactive,
      action: (lease) async {
        if (_authorizeDspWrite(lease, 'disable_legacy_bass')) {
          await AudioEffectsBridge.setBassBoost(0.0);
        }
      },
    );
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final canonical = await DspSettings.load();
      // Startup restoration is background work. It must not interrupt a
      // live DJ transition; sticky registry state will be applied to later
      // A/B sinks once this profile write is admitted.
      await _withDspProfileLease(
        operation: 'restore_dsp_profile',
        priority: PlaybackControlPriority.background,
        action: (lease) async {
          if (!_authorizeDspWrite(lease, 'limiter_ceiling')) return;
          await AudioEffectsBridge.setLiveDspLimiterCeiling(
            highDb: canonical.limiterHighCeilingDb,
            lowDb: canonical.limiterLowCeilingDb,
          );
          if (!_authorizeDspWrite(lease, 'crossover')) return;
          await AudioEffectsBridge.setLiveDspCrossoverHz(canonical.crossoverHz);
          if (!_authorizeDspWrite(lease, 'speaker_protection')) return;
          await AudioEffectsBridge.setLiveDspSpeakerMode(
            canonical.speakerProtectionEnabled,
          );
          if (!_authorizeDspWrite(lease, 'virtual_bass')) return;
          await AudioEffectsBridge.setLiveDspVirtualBass(
            canonical.virtualBassAmount,
          );
          if (!_authorizeDspWrite(lease, 'dvc')) return;
          await AudioEffectsBridge.setLiveDspDvc(
            enabled: canonical.dvcEnabled,
            db: canonical.dvcDb,
            smoothing: canonical.dvcSmoothing,
            smoothingMs: canonical.dvcSmoothingMs,
          );
          if (!_authorizeDspWrite(lease, 'limiter_config')) return;
          await AudioEffectsBridge.setLiveDspLimiterConfig(
            enabled: canonical.limiterEnabled,
            mode: canonical.limiterMode,
            thresholdDb: canonical.limiterThresholdDb,
            releaseMs: canonical.limiterReleaseMs,
            attackMs: canonical.limiterAttackMs,
            lookaheadMs: canonical.limiterLookaheadMs,
            kneeDb: canonical.limiterKneeDb,
          );
          if (!_authorizeDspWrite(lease, 'dither')) return;
          await AudioEffectsBridge.setLiveDspDither(
            enabled: canonical.ditherEnabled,
            mode: canonical.ditherMode,
          );
        },
      );
      effectsEnabled = canonical.effectsEnabled;
      reverb = canonical.reverbAmount;
      virtualizer = canonical.virtualizerAmount;
      bassBoost = prefs.getDouble('bassBoost') ?? 0.0;
      // Always force loudness off (legacy prefs ignored).
      loudness = 0.0;
      // If playback/session creation raced the preference load, apply the
      // restored settings now to every currently known A/B session.
      await _applyNative(priority: PlaybackControlPriority.background);
      notifyListeners();
    } catch (e) {
      debugPrint('Audio effects load failed: $e');
    }
  }

  /// Synchronize the session-bound effects represented by a full sound profile.
  /// The method reuses the serialized A/B session queue so both decks receive
  /// the same settings before either can become audible.
  Future<void> applySoundProfileSettings(DspSettings settings) async {
    effectsEnabled = settings.effectsEnabled;
    reverb = settings.reverbAmount.clamp(0.0, 1.0).toDouble();
    virtualizer = settings.virtualizerAmount.clamp(0.0, 1.0).toDouble();
    bassBoost = 0.0;
    loudness = 0.0;
    await _disableLegacyBassBoost();
    await _applyNative();
    await _save();
    notifyListeners();
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
