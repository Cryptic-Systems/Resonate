import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dsp_settings.dart';
import '../providers/audio_effects_provider.dart';
import '../providers/equalizer_provider.dart';
import '../services/audio_effects_bridge.dart';

class DspSettingsScreen extends StatefulWidget {
  const DspSettingsScreen({super.key});

  @override
  State<DspSettingsScreen> createState() => _DspSettingsScreenState();
}

class _DspSettingsScreenState extends State<DspSettingsScreen> {
  DspSettings? _settings;
  List<ParametricEqBand> _bands = <ParametricEqBand>[];
  bool _loading = true;
  final ValueNotifier<bool> _saving = ValueNotifier<bool>(false);
  Future<void> _commitTail = Future<void>.value();
  late Future<Map<String, dynamic>?> _statusFuture;
  int _localSliderChangeDepth = 0;
  Timer? _meterPoll;

  static const _filterNames = <String>[
    'Peak', 'Low shelf', 'High shelf', 'Low-pass', 'High-pass',
  ];
  static const _limiterNames = <String>[
    'Fast', 'Lookahead', 'True peak', 'Two-band',
  ];
  static const _ditherNames = <String>['None', 'TPDF', 'Shaped'];

  @override
  void initState() {
    super.initState();
    _statusFuture = AudioEffectsBridge.getLiveDspStatus();
    _meterPoll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || _loading) return;
      setState(() => _statusFuture = AudioEffectsBridge.getLiveDspStatus());
    });
    _load();
  }

  @override
  void dispose() {
    _meterPoll?.cancel();
    _saving.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Wait for the app-wide DSP restore pass before taking a live diagnostics
    // snapshot; otherwise the first screen frame can display default sticky values.
    await context.read<AudioEffectsProvider>().ready;
    if (!mounted) return;
    final canonical = await DspSettings.load();
    if (!mounted) return;
    final eq = context.read<EqualizerProvider>();
    final restored = canonical.parametricEqBands;
    final bands = List<ParametricEqBand>.generate(
      EqualizerProvider.studioFrequencies.length,
      (index) => index < restored.length
          ? restored[index].copyWith()
          : ParametricEqBand(
              frequencyHz: eq.studioBands[index].frequencyHz,
              gainDb: eq.studioBands[index].gainDb,
              q: 4.3,
              type: 0,
            ),
    );
    if (!mounted) return;
    setState(() {
      _settings = canonical;
      _bands = bands;
      _loading = false;
      _statusFuture = AudioEffectsBridge.getLiveDspStatus();
    });
  }

  Future<void> _commit({bool pushBands = false, bool pushSpeaker = false}) {
    final next = _commitTail.then((_) => _performCommit(
          pushBands: pushBands,
          pushSpeaker: pushSpeaker,
        ));
    _commitTail = next.catchError((_) {});
    return next;
  }

  Future<void> _performCommit({
    required bool pushBands,
    required bool pushSpeaker,
  }) async {
    final current = _settings;
    if (!mounted || current == null) return;
    final bandsSnapshot = _bands.map((band) => band.copyWith()).toList();
    final equalizer = context.read<EqualizerProvider>();
    _saving.value = true;
    try {
      if (pushBands) {
        await equalizer.setParametricEqBands(
          bandsSnapshot,
          markCustom: true,
        );
      }
      await equalizer.setPreamp(current.preampDb);
      await DspSettings.update((saved) => saved.copyWith(
            parametricEqBands: bandsSnapshot,
            preampDb: current.preampDb,
            dvcEnabled: current.dvcEnabled,
            dvcDb: current.dvcDb,
            dvcSmoothing: current.dvcSmoothing,
            dvcSmoothingMs: current.dvcSmoothingMs,
            limiterEnabled: current.limiterEnabled,
            limiterMode: current.limiterMode,
            limiterThresholdDb: current.limiterThresholdDb,
            limiterReleaseMs: current.limiterReleaseMs,
            limiterAttackMs: current.limiterAttackMs,
            limiterLookaheadMs: current.limiterLookaheadMs,
            limiterKneeDb: current.limiterKneeDb,
            limiterCeilingDb: current.limiterCeilingDb,
            limiterHighCeilingDb: current.limiterHighCeilingDb,
            limiterLowCeilingDb: current.limiterLowCeilingDb,
            crossoverHz: current.crossoverHz,
            speakerProtectionEnabled: current.speakerProtectionEnabled,
            virtualBassAmount: current.virtualBassAmount,
            headroomBassWeight: current.headroomBassWeight,
            headroomPreampWeight: current.headroomPreampWeight,
            headroomGainWeight: current.headroomGainWeight,
            autoPreampEnabled: current.autoPreampEnabled,
            autoPreampTargetDb: current.autoPreampTargetDb,
            autoVirtualBassEnabled: current.autoVirtualBassEnabled,
            autoVirtualBassTarget: current.autoVirtualBassTarget,
            silenceHygieneEnabled: current.silenceHygieneEnabled,
            silenceThresholdDb: current.silenceThresholdDb,
            silenceHoldMs: current.silenceHoldMs,
            autoBassEnabled: current.autoBassEnabled,
            autoBassTargetDb: current.autoBassTargetDb,
            autoBassMarginDb: current.autoBassMarginDb,
            autoBassFreqHz: current.autoBassFreqHz,
            autoGainEnabled: current.autoGainEnabled,
            autoGainTargetRmsDb: current.autoGainTargetRmsDb,
            autoGainBiasDb: current.autoGainBiasDb,
            autoGainMaxBoostDb: current.autoGainMaxBoostDb,
            autoGainMaxCutDb: current.autoGainMaxCutDb,
            autoGainWindowMs: current.autoGainWindowMs,
            ditherEnabled: current.ditherEnabled,
            ditherMode: current.ditherMode,
          ));
      if (!mounted) return;
      await context.read<AudioEffectsProvider>().applyDspSettings(
        current,
        pushSpeaker: pushSpeaker,
      );
      if (mounted) {
        setState(() => _statusFuture = AudioEffectsBridge.getLiveDspStatus());
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not apply DSP settings: ' + error.toString())),
        );
      }
    } finally {
      if (mounted) _saving.value = false;
    }
  }

  void _changeSettings(DspSettings Function(DspSettings) update) {
    final current = _settings;
    if (current == null) return;
    final next = update(current);
    if (_localSliderChangeDepth > 0) {
      _settings = next;
    } else {
      setState(() => _settings = next);
    }
  }

  void _changeBand(int index, ParametricEqBand band) {
    final next = band.copyWith();
    if (_localSliderChangeDepth > 0) {
      _bands[index] = next;
    } else {
      setState(() => _bands[index] = next);
    }
  }

  double _frequencyToPosition(double hz) =>
      (math.log(hz / 20.0) / math.log(1000.0)).clamp(0.0, 1.0);

  double _positionToFrequency(double value) =>
      20.0 * math.pow(1000.0, value).toDouble();

  Widget _section(String title, String description, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(description, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _valueSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String suffix,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    int? divisions,
  }) {
    return _DspValueSlider(
      label: label,
      value: value,
      min: min,
      max: max,
      suffix: suffix,
      divisions: divisions,
      onChanged: (next) {
        _localSliderChangeDepth++;
        try {
          onChanged(next);
        } finally {
          _localSliderChangeDepth--;
        }
      },
      onChangeEnd: onChangeEnd,
    );
  }

  Widget _statusCard() {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _statusFuture,
      builder: (context, snapshot) {
        final status = snapshot.data;
        final engines = (status?['activeEngines'] as num?)?.toInt() ?? 0;
        final calls = (status?['processCalls'] as num?)?.toInt() ?? 0;
        final avgUs = (status?['avgUs'] as num?)?.toDouble() ?? 0;
        final overruns = (status?['overruns'] as num?)?.toInt() ?? 0;
        final maxUs = (status?['maxUs'] as num?)?.toDouble() ?? 0;
        final dvcGainDb = (status?['dvcDb'] as num?)?.toDouble();
        final virtualBass = (status?['virtualBass'] as num?)?.toDouble() ??
            _settings?.virtualBassAmount;
        final meterSets = status?['liveMetersByDeck'];
        final activeDeck = status?['activeDeckId']?.toString() ?? 'A';
        final metersByDeck = meterSets is Map ? meterSets : const <Object, Object>{};
        final activeMetersRaw = metersByDeck[activeDeck];
        final activeMeters = activeMetersRaw is Map
            ? activeMetersRaw
            : const <Object, Object>{};
        double meter(String key, [double fallback = 0]) =>
            (activeMeters[key] as num?)?.toDouble() ?? fallback;
        final hasMeters = activeMeters.isNotEmpty;
        return _section('Live engine', 'Per-deck Media3 DSP status and PCM diagnostics. Media3 owns output routing and sample-rate conversion; standalone backend and SRC controls are not used in this live path.', [
          _statusRow('Active DSP decks', engines.toString() + ' / 2'),
          _statusRow('PCM blocks processed', calls.toString()),
          _statusRow('Average processing time', avgUs.toStringAsFixed(1) + ' μs'),
          _statusRow('Maximum processing time', maxUs.toStringAsFixed(1) + ' μs'),
          _statusRow('Realtime budget overruns', overruns.toString()),
          _statusRow('DVC gain', dvcGainDb == null ? '—' : dvcGainDb.toStringAsFixed(1) + ' dB'),
          _statusRow('Speaker protection', status?['speakerMode'] == true ? 'On' : 'Off'),
          _statusRow('Virtual bass', virtualBass == null ? '—' : virtualBass.toStringAsFixed(2)),
          _statusRow('DSP engine version', status?['dspVersion']?.toString() ?? '—'),
          if (hasMeters) ...[
            const Divider(height: 20),
            Text('Live signal · Deck $activeDeck',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            _statusRow('Input peak', meter('inputPeakDb').toStringAsFixed(1) + ' dBFS'),
            _statusRow('Input true peak', meter('inputTruePeakDb').toStringAsFixed(1) + ' dBFS'),
            _statusRow('Post-EQ peak', meter('postEqPeakDb').toStringAsFixed(1) + ' dBFS'),
            _statusRow('Headroom', meter('headroomDb').toStringAsFixed(1) + ' dB'),
            _statusRow('Limiter gain reduction', meter('limiterGrDb').toStringAsFixed(1) + ' dB'),
            _statusRow('Limiter peak hold', meter('limiterGrPeakDb').toStringAsFixed(1) + ' dB'),
            _statusRow('Short-term RMS', meter('shortTermRmsDb', -160).toStringAsFixed(1) + ' dBFS'),
            _statusRow('Automatic bass · applied', meter('autoBassAppliedDb').toStringAsFixed(1) + ' dB'),
            _statusRow('Automatic loudness · applied', meter('autoGainAppliedDb').toStringAsFixed(1) + ' dB'),
            _statusRow('Automatic preamp · applied', meter('autoPreampAppliedDb').toStringAsFixed(1) + ' dB'),
            _statusRow('Automatic virtual bass · applied', meter('autoVirtualBassApplied').toStringAsFixed(2)),
            _statusRow('Track analysis hint', activeMeters['analysisHintActive'] == true ? 'Active' : 'Unavailable'),
            if (_settings != null) ...[
              _statusRow('Wanted bass target', _settings!.autoBassTargetDb.toStringAsFixed(1) + ' dB'),
              _statusRow('Wanted loudness target', _settings!.autoGainTargetRmsDb.toStringAsFixed(1) + ' dBFS'),
            ],
          ],
          if (status?['gateTripped'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Safety pass-through is active. DSP has been demoted to protect playback.'),
            ),
          if (snapshot.connectionState == ConnectionState.waiting)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ]);
      },
    );
  }

  Widget _statusRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))],
        ),
      );

  Widget _parametricBandTile(int index, ParametricEqBand band) {
    return ExpansionTile(
      key: ValueKey('dsp-eq-band-' + index.toString()),
      title: Text('Band ' + (index + 1).toString() + ' · ' + band.frequencyHz.toStringAsFixed(0) + ' Hz'),
      subtitle: Text(_filterNames[band.type] + ' · ' + band.gainDb.toStringAsFixed(1) + ' dB · Q ' + band.q.toStringAsFixed(2)),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Filter type')),
            DropdownButton<int>(
              value: band.type,
              items: List.generate(_filterNames.length, (i) =>
                DropdownMenuItem(value: i, child: Text(_filterNames[i]))),
              onChanged: (value) {
                if (value != null) {
                  _changeBand(index, band.copyWith(type: value));
                  _commit(pushBands: true);
                }
              },
            ),
          ],
        ),
        _DspFrequencySlider(
          frequencyHz: band.frequencyHz,
          position: _frequencyToPosition(band.frequencyHz),
          onChanged: (position) {
            _localSliderChangeDepth++;
            try {
              _changeBand(
                index,
                band.copyWith(frequencyHz: _positionToFrequency(position)),
              );
            } finally {
              _localSliderChangeDepth--;
            }
          },
          onChangeEnd: (_) => _commit(pushBands: true),
        ),
        if (band.type < 3)
          _valueSlider(
            label: 'Gain',
            value: band.gainDb,
            min: -24,
            max: 24,
            suffix: 'dB',
            divisions: 96,
            onChanged: (value) => _changeBand(index, band.copyWith(gainDb: value)),
            onChangeEnd: (_) => _commit(pushBands: true),
          ),
        _valueSlider(
          label: 'Bandwidth / Q',
          value: band.q,
          min: 0.1,
          max: 18,
          suffix: 'Q',
          divisions: 179,
          onChanged: (value) => _changeBand(index, band.copyWith(q: value)),
          onChangeEnd: (_) => _commit(pushBands: true),
        ),
      ],
    );
  }

  Widget _advancedSection(String title, String description, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(description, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: children,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('DSP Engine'),
        actions: [
          IconButton(
            tooltip: 'Reset parametric EQ',
            icon: const Icon(Icons.restart_alt_rounded),
            onPressed: settings == null ? null : () {
              setState(() {
                _bands = List.generate(
                  EqualizerProvider.studioFrequencies.length,
                  (i) => ParametricEqBand(
                    frequencyHz: EqualizerProvider.studioFrequencies[i],
                    gainDb: 0,
                    q: 4.3,
                    type: 0,
                  ),
                );
              });
              _commit(pushBands: true);
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _saving,
            builder: (context, saving, child) => IconButton(
              tooltip: 'Apply DSP settings',
              icon: const Icon(Icons.check_rounded),
              onPressed: settings == null || saving
                  ? null
                  : () => _commit(pushBands: true),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : settings == null
              ? const Center(child: Text('DSP settings could not be loaded.'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    _section(
                      'Everyday controls',
                      'Quick controls for overall level and safe peak handling. Choose a sound profile on the Equalizer screen for the biggest tonal changes.',
                      [
                        _valueSlider(
                          label: 'DVC gain',
                          value: settings.dvcDb,
                          min: -24,
                          max: 6,
                          suffix: 'dB',
                          divisions: 60,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(dvcDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enable Direct Volume Control'),
                          subtitle: const Text('Applies a separate, smoothed digital gain stage. Positive gain reduces available headroom.'),
                          value: settings.dvcEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(dvcEnabled: v));
                            _commit();
                          },
                        ),
                        const Divider(height: 20),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enable peak limiter'),
                          subtitle: const Text('Catches peaks to reduce clipping. Leave enabled for a safer default.'),
                          value: settings.limiterEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(limiterEnabled: v));
                            _commit();
                          },
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('DVC response'),
                          subtitle: const Text('Advanced gain smoothing'),
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Smooth gain transitions'),
                              subtitle: const Text('Prevents abrupt level changes when DVC is adjusted.'),
                              value: settings.dvcSmoothing,
                              onChanged: (v) {
                                _changeSettings((s) => s.copyWith(dvcSmoothing: v));
                                _commit();
                              },
                            ),
                            _valueSlider(
                              label: 'Smoothing time',
                              value: settings.dvcSmoothingMs,
                              min: 0,
                              max: 200,
                              suffix: 'ms',
                              divisions: 200,
                              onChanged: (v) => _changeSettings((s) => s.copyWith(dvcSmoothingMs: v)),
                              onChangeEnd: (_) => _commit(),
                            ),
                          ],
                        ),
                      ],
                    ),
                    _advancedSection(
                      'Preamp and headroom',
                      'Digital gain before DVC and limiting. Use negative preamp when applying strong EQ boosts.',
                      [
                        _valueSlider(
                          label: 'Preamp gain',
                          value: settings.preampDb,
                          min: -6,
                          max: 6,
                          suffix: 'dB',
                          divisions: 48,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(preampDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                      ],
                    ),
                    _advancedSection(
                      'Automatic bass and loudness',
                      'Content-aware low-frequency enhancement and short-term loudness matching. Auto loudness owns DVC while enabled; use its bias instead of manual DVC gain.',
                      [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Automatic bass enhancement'),
                          subtitle: const Text('Adds a dedicated low shelf, constrained by live headroom and the configured safety margin.'),
                          value: settings.autoBassEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(autoBassEnabled: v));
                            _commit();
                          },
                        ),
                        _valueSlider(
                          label: 'Wanted bass boost',
                          value: settings.autoBassTargetDb,
                          min: 0,
                          max: 12,
                          suffix: 'dB',
                          divisions: 48,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoBassTargetDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Bass safety margin',
                          value: settings.autoBassMarginDb,
                          min: 0,
                          max: 12,
                          suffix: 'dB',
                          divisions: 48,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoBassMarginDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Bass shelf frequency',
                          value: settings.autoBassFreqHz,
                          min: 40,
                          max: 160,
                          suffix: 'Hz',
                          divisions: 120,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoBassFreqHz: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        const Divider(height: 20),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Automatic loudness matching'),
                          subtitle: const Text('Matches short-term RMS across tracks. The limiter remains the final peak-safety stage.'),
                          value: settings.autoGainEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(autoGainEnabled: v));
                            _commit();
                          },
                        ),
                        _valueSlider(
                          label: 'Loudness target',
                          value: settings.autoGainTargetRmsDb,
                          min: -30,
                          max: -8,
                          suffix: 'dBFS',
                          divisions: 88,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoGainTargetRmsDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Loudness bias',
                          value: settings.autoGainBiasDb,
                          min: -6,
                          max: 6,
                          suffix: 'dB',
                          divisions: 48,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoGainBiasDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Maximum boost',
                          value: settings.autoGainMaxBoostDb,
                          min: 0,
                          max: 12,
                          suffix: 'dB',
                          divisions: 48,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoGainMaxBoostDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Maximum cut',
                          value: settings.autoGainMaxCutDb,
                          min: 0,
                          max: 24,
                          suffix: 'dB',
                          divisions: 96,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoGainMaxCutDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Loudness integration window',
                          value: settings.autoGainWindowMs,
                          min: 200,
                          max: 3000,
                          suffix: 'ms',
                          divisions: 140,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoGainWindowMs: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                      ],
                    ),
                    _advancedSection(
                      'DSP intelligence and headroom',
                      'Adaptive controls are independent of your manual EQ preamp. Headroom weights are normalized by the native engine.',
                      [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Automatic preamp'),
                          subtitle: const Text('DSP adjusts preamp toward the selected target using its live signal analysis.'),
                          value: settings.autoPreampEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(autoPreampEnabled: v));
                            _commit();
                          },
                        ),
                        _valueSlider(
                          label: 'Auto-preamp target',
                          value: settings.autoPreampTargetDb,
                          min: -12,
                          max: 12,
                          suffix: 'dB',
                          divisions: 96,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoPreampTargetDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Automatic virtual bass'),
                          subtitle: const Text('Lets DSP adapt virtual-bass intensity to the configured target.'),
                          value: settings.autoVirtualBassEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(autoVirtualBassEnabled: v));
                            _commit();
                          },
                        ),
                        _valueSlider(
                          label: 'Auto virtual-bass target',
                          value: settings.autoVirtualBassTarget,
                          min: 0,
                          max: 1,
                          suffix: 'level',
                          divisions: 100,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(autoVirtualBassTarget: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Silence hygiene'),
                          subtitle: const Text('Suppresses shaped-dither residue during sustained digital silence.'),
                          value: settings.silenceHygieneEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(silenceHygieneEnabled: v));
                            _commit();
                          },
                        ),
                        _valueSlider(
                          label: 'Silence threshold',
                          value: settings.silenceThresholdDb,
                          min: -120,
                          max: -20,
                          suffix: 'dBFS',
                          divisions: 100,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(silenceThresholdDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Silence hold',
                          value: settings.silenceHoldMs,
                          min: 50,
                          max: 5000,
                          suffix: 'ms',
                          divisions: 99,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(silenceHoldMs: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Bass headroom allocation',
                          value: settings.headroomBassWeight,
                          min: 0,
                          max: 1,
                          suffix: 'weight',
                          divisions: 100,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(headroomBassWeight: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Preamp headroom allocation',
                          value: settings.headroomPreampWeight,
                          min: 0,
                          max: 1,
                          suffix: 'weight',
                          divisions: 100,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(headroomPreampWeight: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Gain headroom allocation',
                          value: settings.headroomGainWeight,
                          min: 0,
                          max: 1,
                          suffix: 'weight',
                          divisions: 100,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(headroomGainWeight: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                      ],
                    ),
                    _advancedSection(
                      'Limiter configuration',
                      'Fine control over limiter timing, character and output ceilings. The everyday limiter switch remains above.',
                      [
                        DropdownButtonFormField<int>(
                          value: settings.limiterMode,
                          decoration: const InputDecoration(labelText: 'Limiter mode'),
                          items: List.generate(_limiterNames.length, (i) =>
                            DropdownMenuItem(value: i, child: Text(_limiterNames[i]))),
                          onChanged: (v) {
                            if (v == null) return;
                            _changeSettings((s) => s.copyWith(limiterMode: v));
                            _commit();
                          },
                        ),
                        _valueSlider(
                          label: 'Threshold',
                          value: settings.limiterThresholdDb,
                          min: -24,
                          max: 0,
                          suffix: 'dB',
                          divisions: 96,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterThresholdDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Release',
                          value: settings.limiterReleaseMs,
                          min: 1,
                          max: 2000,
                          suffix: 'ms',
                          divisions: 1999,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterReleaseMs: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Attack',
                          value: settings.limiterAttackMs,
                          min: 0.01,
                          max: 100,
                          suffix: 'ms',
                          divisions: 999,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterAttackMs: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Lookahead',
                          value: settings.limiterLookaheadMs,
                          min: 0,
                          max: 40,
                          suffix: 'ms',
                          divisions: 80,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterLookaheadMs: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Soft knee',
                          value: settings.limiterKneeDb,
                          min: 0,
                          max: 12,
                          suffix: 'dB',
                          divisions: 48,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterKneeDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'High-band ceiling',
                          value: settings.limiterHighCeilingDb,
                          min: -12,
                          max: -0.05,
                          suffix: 'dBFS',
                          divisions: 1195,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterHighCeilingDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Low-band ceiling',
                          value: settings.limiterLowCeilingDb,
                          min: -6,
                          max: -0.1,
                          suffix: 'dBFS',
                          divisions: 59,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(limiterLowCeilingDb: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                        _valueSlider(
                          label: 'Two-band crossover',
                          value: settings.crossoverHz,
                          min: 80,
                          max: 200,
                          suffix: 'Hz',
                          divisions: 120,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(crossoverHz: v)),
                          onChangeEnd: (_) => _commit(),
                        ),
                      ],
                    ),
                    _advancedSection(
                      'Speaker delivery',
                      'Route-oriented high-pass protection and optional virtual-bass harmonics. Not a headphone calibration feature.',
                      [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Speaker protection'),
                          subtitle: const Text('Applies protective filtering for speaker playback routes.'),
                          value: settings.speakerProtectionEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(speakerProtectionEnabled: v));
                            _commit(pushSpeaker: true);
                          },
                        ),
                        _valueSlider(
                          label: 'Virtual bass',
                          value: settings.virtualBassAmount,
                          min: 0,
                          max: 1,
                          suffix: 'level',
                          divisions: 100,
                          onChanged: (v) => _changeSettings((s) => s.copyWith(virtualBassAmount: v)),
                          onChangeEnd: (_) => _commit(pushSpeaker: true),
                        ),
                      ],
                    ),
                    _advancedSection(
                      'Dither',
                      'Noise shaping for PCM16 output quantization. Most listeners can leave this at its default.',
                      [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enable dither'),
                          value: settings.ditherEnabled,
                          onChanged: (v) {
                            _changeSettings((s) => s.copyWith(ditherEnabled: v));
                            _commit();
                          },
                        ),
                        DropdownButtonFormField<int>(
                          value: settings.ditherMode,
                          decoration: const InputDecoration(labelText: 'Dither mode'),
                          items: List.generate(_ditherNames.length, (i) =>
                            DropdownMenuItem(value: i, child: Text(_ditherNames[i]))),
                          onChanged: (v) {
                            if (v == null) return;
                            _changeSettings((s) => s.copyWith(ditherMode: v));
                            _commit();
                          },
                        ),
                      ],
                    ),
                    _advancedSection(
                      '31-band parametric EQ',
                      'Studio-level control of frequency, gain, Q and filter topology. For normal listening, start with a Resonate sound profile.',
                      [
                        ...List.generate(_bands.length, (i) => _parametricBandTile(i, _bands[i])),
                      ],
                    ),
                    _advancedSection(
                      'Live engine diagnostics',
                      'Read-only per-deck processing and PCM diagnostics.',
                      [_statusCard()],
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: _saving,
                      builder: (context, saving, child) => saving
                          ? const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
    );
  }
}

/// Keeps high-frequency slider drag updates local to the control. The screen
/// model is still updated synchronously, but unrelated DSP sections and live
/// diagnostics are not rebuilt for every pointer movement.
class _DspValueSlider extends StatefulWidget {
  const _DspValueSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    required this.onChangeEnd,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_DspValueSlider> createState() => _DspValueSliderState();
}

class _DspValueSliderState extends State<_DspValueSlider> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(covariant _DspValueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label)),
            Text(
              _value.toStringAsFixed(1) + ' ' + widget.suffix,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ),
        Slider(
          value: _value.clamp(widget.min, widget.max).toDouble(),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: (next) {
            setState(() => _value = next);
            widget.onChanged(next);
          },
          onChangeEnd: widget.onChangeEnd,
        ),
      ],
    );
  }
}


class _DspFrequencySlider extends StatefulWidget {
  const _DspFrequencySlider({
    required this.frequencyHz,
    required this.position,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double frequencyHz;
  final double position;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_DspFrequencySlider> createState() => _DspFrequencySliderState();
}

class _DspFrequencySliderState extends State<_DspFrequencySlider> {
  late double _position;

  @override
  void initState() {
    super.initState();
    _position = widget.position;
  }

  @override
  void didUpdateWidget(covariant _DspFrequencySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) _position = widget.position;
  }

  @override
  Widget build(BuildContext context) {
    final hz = 20.0 * math.pow(1000.0, _position).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Frequency · ' + hz.toStringAsFixed(0) + ' Hz'),
        Slider(
          value: _position.clamp(0.0, 1.0).toDouble(),
          onChanged: (next) {
            setState(() => _position = next);
            widget.onChanged(next);
          },
          onChangeEnd: widget.onChangeEnd,
        ),
      ],
    );
  }
}
