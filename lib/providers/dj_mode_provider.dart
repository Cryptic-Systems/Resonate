import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/dj_analysis_service.dart';
import '../services/dj_idle_analysis_service.dart';
import '../services/dj_mode_settings_store.dart';
import '../dj_engine/core/dj_policy.dart';
import '../services/resonate_diagnostics.dart';
import 'music_provider.dart';

/// Optional DJ Mode layer — same obedience model as Intelligence.
///
/// When [isEnabled] is false (default), every feature gate is off and
/// [MusicProvider] playback / crossfade behavior is unchanged.
class DjModeProvider extends ChangeNotifier {
  DjModeProvider({required this.music, DjAnalysisService? analysis})
      : _analysis = analysis ?? DjAnalysisService() {
    _idle = DjIdleAnalysisService(analysis: _analysis);
    _lastObservedPlaying = music.isPlaying;
    music.addListener(_onMusicChanged);
    ready = _load();
  }

  final MusicProvider music;
  final DjAnalysisService _analysis;
  late final DjIdleAnalysisService _idle;

  bool _enabled = false;
  bool _beatAlign = true;
  bool _tempoMatch = false;
  bool _harmonicMix = false;
  int _maxStretchPercent = 6;
  bool _analyzeIdle = true;
  bool _transitionSfx = true;
  DjAggressiveness _aggressiveness = DjAggressiveness.balanced;
  double _minConfidence = 0.40;
  bool _loaded = false;
  late final Future<void> ready;
  bool _lastObservedPlaying = false;
  Timer? _eventScanDebounce;

  bool get isLoaded => _loaded;
  bool get isEnabled => _enabled;

  /// Effective gates: always false when master is off (like Intelligence).
  bool get beatAlignActive => _enabled && _beatAlign;
  bool get tempoMatchActive => _enabled && _tempoMatch;
  bool get harmonicMixActive => _enabled && _harmonicMix;
  bool get transitionSfx => _transitionSfx;
  DjAggressiveness get aggressiveness => _aggressiveness;
  double get minConfidence => _minConfidence;
  DjPolicy get policy => DjPolicy(
        aggressiveness: _aggressiveness,
        minConfidence: _minConfidence,
        harmonicMix: harmonicMixActive,
      );
  bool get analyzeIdleActive => _analyzeIdle;

  bool get beatAlign => _beatAlign;
  bool get tempoMatch => _tempoMatch;
  bool get harmonicMix => _harmonicMix;
  int get maxStretchPercent => _maxStretchPercent;
  bool get analyzeIdle => _analyzeIdle;

  DjAnalysisService get analysis => _analysis;

  Future<void> _load() async {
    try {
      _enabled = await DjModeSettingsStore.enabled();
      _beatAlign = await DjModeSettingsStore.beatAlign();
      _tempoMatch = await DjModeSettingsStore.tempoMatch();
      _harmonicMix = await DjModeSettingsStore.harmonicMix();
      _maxStretchPercent = await DjModeSettingsStore.maxStretchPercent();
      _analyzeIdle = true; // mandatory library analysis is independent of DJ playback opt-in.
      _transitionSfx = await DjModeSettingsStore.transitionSfx();
      _aggressiveness = await DjModeSettingsStore.aggressiveness();
      _minConfidence = await DjModeSettingsStore.minConfidence();
    } catch (e) {
      debugPrint('DjModeProvider load failed: $e');
    }
    _loaded = true;
    _syncToMusic();
    notifyListeners();
    _maybeStartIdleScan();
  }

  void _syncToMusic() {
    try {
      music.configureDjMode(
        beatAlignActive: beatAlignActive,
        tempoMatchActive: tempoMatchActive,
        maxStretchPercent: _maxStretchPercent,
        sfxActive: _enabled && _transitionSfx,
        analysis: _analysis,
        policy: policy,
      );
    } catch (e) {
      debugPrint('DjMode sync to music failed: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _syncToMusic();
    notifyListeners();
    try {
      await DjModeSettingsStore.setEnabled(value);
    } catch (e) {
      debugPrint('DjMode setEnabled failed: $e');
    }
    // Disabling DJ playback must not cancel the required library analysis queue.
    _maybeStartIdleScan();
  }

  Future<void> setBeatAlign(bool value) async {
    _beatAlign = value;
    _syncToMusic();
    notifyListeners();
    await DjModeSettingsStore.setBeatAlign(value);
  }

  Future<void> setTempoMatch(bool value) async {
    _tempoMatch = value;
    _syncToMusic();
    notifyListeners();
    await DjModeSettingsStore.setTempoMatch(value);
  }

  Future<void> setHarmonicMix(bool value) async {
    _harmonicMix = value;
    _syncToMusic();
    notifyListeners();
    await DjModeSettingsStore.setHarmonicMix(value);
  }

  Future<void> setMaxStretchPercent(int value) async {
    _maxStretchPercent = value.clamp(3, 6);
    _syncToMusic();
    notifyListeners();
    await DjModeSettingsStore.setMaxStretchPercent(_maxStretchPercent);
  }

  Future<void> setTransitionSfx(bool value) async {
    _transitionSfx = value;
    notifyListeners();
    await DjModeSettingsStore.setTransitionSfx(value);
    _syncToMusic();
  }


  Future<void> setAggressiveness(DjAggressiveness value) async {
    _aggressiveness = value;
    _syncToMusic();
    notifyListeners();
    await DjModeSettingsStore.setAggressiveness(value);
  }

  Future<void> setMinConfidence(double value) async {
    _minConfidence = value.clamp(0.20, 0.80);
    _syncToMusic();
    notifyListeners();
    await DjModeSettingsStore.setMinConfidence(_minConfidence);
  }

  Future<void> setAnalyzeIdle(bool value) async {
    // Compatibility setter: the old opt-out is retired because DJ analysis
    // is now a mandatory library capability, independent of playback mode.
    _analyzeIdle = true;
    notifyListeners();
    await DjModeSettingsStore.setAnalyzeIdle(true);
    _maybeStartIdleScan();
  }

  void _maybeStartIdleScan() {
    if (!_loaded || music.isPlaying) return;
    // One resumable pass covers the complete library. Each completed track is
    // persisted before advancing, so a process stop resumes by skipping it.
    unawaited(_idle.startIfNeeded(
      maxSongs: 1 << 30,
      maxWaveformChunks: 2,
      isStillIdle: _isAnalysisStillIdle,
    ));
  }

  bool _isAnalysisStillIdle() =>
      !music.isPlaying && !music.transitionInProgress;

  /// Called by app lifecycle and audio-route events. Work is intentionally
  /// small and rate-limited so unlock/BT event bursts do not start many scans.
  void onAnalysisOpportunity(String reason) {
    if (!_loaded) return;
    _eventScanDebounce?.cancel();
    _eventScanDebounce = Timer(const Duration(seconds: 8), () {
      if (music.isPlaying || _idle.isRunning) {
        return;
      }

      unawaited(ResonateDiagnostics.recordDj(
        stage: 'idle_scan_trigger',
        outcome: 'scheduled',
        reason: reason,
      ));
      unawaited(_idle.startIfNeeded(
        maxSongs: 1 << 30,
        maxWaveformChunks: 2,
        isStillIdle: _isAnalysisStillIdle,
      ));
    });
  }

  void _onMusicChanged() {
    final playing = music.isPlaying;
    if (playing == _lastObservedPlaying) return;
    _lastObservedPlaying = playing;
    if (playing) {
      _eventScanDebounce?.cancel();
      _idle.stop();
    } else {
      _maybeStartIdleScan();
    }
  }

  @override
  void dispose() {
    _eventScanDebounce?.cancel();
    music.removeListener(_onMusicChanged);
    _idle.stop();
    super.dispose();
  }

  /// Manual trigger from settings / diagnostics.
  Future<void> runIdleScanNow({int maxSongs = 1 << 30}) async {
    await _idle.startIfNeeded(
      maxSongs: maxSongs,
      maxWaveformChunks: 2,
      isStillIdle: _isAnalysisStillIdle,
    );
  }
}
