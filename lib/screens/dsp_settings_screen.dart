import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dsp_settings.dart';
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
  bool _saving = false;

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
    _load();
  }

  Future<void> _load() async {
    final canonical = await DspSettings.load();
    if (!mounted) return;
    final eq = context.read<EqualizerProvider>();
    final restored = canonical.parametricEqBands;
    final bands = restored.length == EqualizerProvider.studioFrequencies.length
        ? restored.map((band) => band.copyWith()).toList()
        : List<ParametricEqBand>.generate(
            EqualizerProvider.studioFrequencies.length,
            (index) => ParametricEqBand(
              frequencyHz: eq.studioBands[index].frequencyHz,
              gainDb: eq.studioBands[index].gainDb,
              q: 1,
              type: 0,
            ),
          );
    if (!mounted) return;
    setState(() {
      _settings = canonical;
      _bands = bands;
      _loading = false;
    });
  }

  Future<void> _commit({bool pushBands = false}) async {
    final current = _settings;
    if (current == null || _saving) return;
    setState(() => _saving = true);
    try {
      await DspSettings.update((saved) => saved.copyWith(
            parametricEqBands: _bands,
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
            ditherEnabled: current.ditherEnabled,
            ditherMode: current.ditherMode,
          ));
      if (!mounted) return;
      if (pushBands) {
        await context.read<EqualizerProvider>().setParametricEqBands(_bands);
      } else {
        await AudioEffectsBridge.setLiveDspParametricEqBands(
          frequenciesHz: _bands.map((band) => band.frequencyHz).toList(),
          gainsDb: _bands.map((band) => band.gainDb).toList(),
          qs: _bands.map((band) => band.q).toList(),
          types: _bands.map((band) => band.type).toList(),
        );
      }
      await context.read<EqualizerProvider>().setPreamp(current.preampDb);
      await AudioEffectsBridge.setLiveDspDvc(
        enabled: current.dvcEnabled,
        db: current.dvcDb,
        smoothing: current.dvcSmoothing,
        smoothingMs: current.dvcSmoothingMs,
      );
      await AudioEffectsBridge.setLiveDspLimiterConfig(
        enabled: current.limiterEnabled,
        mode: current.limiterMode,
        thresholdDb: current.limiterThresholdDb,
        releaseMs: current.limiterReleaseMs,
        attackMs: current.limiterAttackMs,
        lookaheadMs: current.limiterLookaheadMs,
        kneeDb: current.limiterKneeDb,
      );
      await AudioEffectsBridge.setLiveDspLimiterCeiling(
        highDb: current.limiterHighCeilingDb,
        lowDb: current.limiterLowCeilingDb,
      );
      await AudioEffectsBridge.setLiveDspCrossoverHz(current.crossoverHz);
      await AudioEffectsBridge.setLiveDspSpeakerMode(current.speakerProtectionEnabled);
      await AudioEffectsBridge.setLiveDspVirtualBass(current.virtualBassAmount);
      await AudioEffectsBridge.setLiveDspDither(
        enabled: current.ditherEnabled,
        mode: current.ditherMode,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _changeSettings(DspSettings Function(DspSettings) update) {
    final current = _settings;
    if (current == null) return;
    setState(() => _settings = update(current));
  }

  void _changeBand(int index, ParametricEqBand band) {
    setState(() => _bands[index] = band.copyWith());
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(value.toStringAsFixed(1) + ' ' + suffix,
                style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  Widget _statusCard() {
    return FutureBuilder<Map<String, dynamic>?>(
      future: AudioEffectsBridge.getLiveDspStatus(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        final engines = (status?['activeEngines'] as num?)?.toInt() ?? 0;
        final calls = (status?['processCalls'] as num?)?.toInt() ?? 0;
        final avgUs = (status?['avgUs'] as num?)?.toDouble() ?? 0;
        final overruns = (status?['overruns'] as num?)?.toInt() ?? 0;
        final maxUs = (status?['maxUs'] as num?)?.toDouble() ?? 0;
        return _section('Live engine', 'Per-deck Media3 DSP status and PCM processing diagnostics.', [
          _statusRow('Active DSP decks', engines.toString() + ' / 2'),
          _statusRow('PCM blocks processed', calls.toString()),
          _statusRow('Average processing time', avgUs.toStringAsFixed(1) + ' μs'),
          _statusRow('Maximum processing time', maxUs.toStringAsFixed(1) + ' μs'),
          _statusRow('Realtime budget overruns', overruns.toString()),
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
        Text('Frequency · ' + band.frequencyHz.toStringAsFixed(0) + ' Hz'),
        Slider(
          value: _frequencyToPosition(band.frequencyHz),
          onChanged: (position) => _changeBand(
            index, band.copyWith(frequencyHz: _positionToFrequency(position))),
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
                    q: 1,
                    type: 0,
                  ),
                );
              });
              _commit(pushBands: true);
            },
          ),
          IconButton(
            tooltip: 'Apply DSP settings',
            icon: const Icon(Icons.check_rounded),
            onPressed: settings == null || _saving ? null : () => _commit(pushBands: true),
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
                    _statusCard(),
                    _section('Preamp', 'Gain before DVC and limiting. EQ headroom remains managed by the Equalizer screen.', [
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
                    ]),
                    _section('Direct Volume Control', 'A dedicated, smoothed gain stage independent of EQ preamp.', [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Enable DVC'),
                        value: settings.dvcEnabled,
                        onChanged: (v) {
                          _changeSettings((s) => s.copyWith(dvcEnabled: v));
                          _commit();
                        },
                      ),
                      _valueSlider(
                        label: 'DVC gain',
                        value: settings.dvcDb,
                        min: -24,
                        max: 6,
                        suffix: 'dB',
                        divisions: 120,
                        onChanged: (v) => _changeSettings((s) => s.copyWith(dvcDb: v)),
                        onChangeEnd: (_) => _commit(),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Smooth gain transitions'),
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
                    ]),
                    _section('Limiter', 'Peak protection with fast, lookahead, true-peak and two-band modes.', [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Enable limiter'),
                        value: settings.limiterEnabled,
                        onChanged: (v) {
                          _changeSettings((s) => s.copyWith(limiterEnabled: v));
                          _commit();
                        },
                      ),
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
                        max: 1000,
                        suffix: 'ms',
                        divisions: 999,
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
                        min: -6,
                        max: -0.1,
                        suffix: 'dBFS',
                        divisions: 59,
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
                    ]),
                    _section('Speaker delivery', 'High-pass protection and optional virtual-bass harmonics for small speakers.', [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Speaker protection'),
                        value: settings.speakerProtectionEnabled,
                        onChanged: (v) {
                          _changeSettings((s) => s.copyWith(speakerProtectionEnabled: v));
                          _commit();
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
                        onChangeEnd: (_) => _commit(),
                      ),
                    ]),
                    _section('Dither', 'Noise shaping for PCM16 output quantization.', [
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
                    ]),
                    _section('31-band parametric EQ', 'Each band exposes frequency, gain, Q and filter topology. Changes apply to both Media3 decks.', [
                      for (var i = 0; i < _bands.length; i++)
                        _parametricBandTile(i, _bands[i]),
                    ]),
                    if (_saving)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
    );
  }
}
