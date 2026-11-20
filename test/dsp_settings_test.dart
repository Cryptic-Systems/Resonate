import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/models/dsp_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DspSettings', () {
    test('round trips every independent field in a versioned snapshot', () {
      final settings = DspSettings(
        masterEnabled: true,
        eqEnabled: false,
        preset: 'Custom',
        eqBandGainsDb: [3, -2, 1],
        preampDb: -4,
        autoEqHeadroom: true,
        dvcDb: 2.5,
        dvcEnabled: false,
        dvcSmoothing: false,
        dvcSmoothingMs: 28,
        limiterEnabled: false,
        limiterMode: 3,
        limiterThresholdDb: -4,
        limiterReleaseMs: 240,
        limiterAttackMs: 1.5,
        limiterLookaheadMs: 5,
        limiterKneeDb: 2,
        ditherEnabled: true,
        ditherMode: 2,
        limiterCeilingDb: -3,
        limiterHighCeilingDb: -2.5,
        limiterLowCeilingDb: -1.5,
        crossoverHz: 160,
        speakerProtectionEnabled: true,
        virtualBassAmount: 0.4,
        headroomBassWeight: 0.4,
        headroomPreampWeight: 0.35,
        headroomGainWeight: 0.25,
        autoPreampEnabled: true,
        autoPreampTargetDb: -2.5,
        autoVirtualBassEnabled: true,
        autoVirtualBassTarget: 0.72,
        silenceHygieneEnabled: true,
        silenceThresholdDb: -82,
        silenceHoldMs: 850,
        effectsEnabled: false,
        reverbAmount: 0.3,
        virtualizerAmount: 0.7,
      );
      final restored = DspSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored.masterEnabled, isTrue);
      expect(restored.eqEnabled, isTrue);
      expect(restored.preset, 'Custom');
      expect(restored.preampDb, -4);
      expect(restored.autoEqHeadroom, isTrue);
      expect(restored.dvcDb, 2.5);
      expect(restored.dvcEnabled, isFalse);
      expect(restored.dvcSmoothing, isFalse);
      expect(restored.dvcSmoothingMs, 28);
      expect(restored.limiterEnabled, isFalse);
      expect(restored.limiterMode, 3);
      expect(restored.limiterThresholdDb, -4);
      expect(restored.limiterReleaseMs, 240);
      expect(restored.limiterAttackMs, 1.5);
      expect(restored.limiterLookaheadMs, 5);
      expect(restored.limiterKneeDb, 2);
      expect(restored.ditherEnabled, isTrue);
      expect(restored.ditherMode, 2);
      expect(restored.limiterCeilingDb, -3);
      expect(restored.limiterHighCeilingDb, -2.5);
      expect(restored.limiterLowCeilingDb, -1.5);
      expect(restored.crossoverHz, 160);
      expect(restored.speakerProtectionEnabled, isTrue);
      expect(restored.eqBandGainsDb, [3, -2, 1]);
      expect(restored.virtualBassAmount, 0.4);
      expect(restored.headroomBassWeight, 0.4);
      expect(restored.headroomPreampWeight, 0.35);
      expect(restored.headroomGainWeight, 0.25);
      expect(restored.autoPreampEnabled, isTrue);
      expect(restored.autoPreampTargetDb, -2.5);
      expect(restored.autoVirtualBassEnabled, isTrue);
      expect(restored.autoVirtualBassTarget, 0.72);
      expect(restored.silenceHygieneEnabled, isTrue);
      expect(restored.silenceThresholdDb, -82);
      expect(restored.silenceHoldMs, 850);
      expect(restored.effectsEnabled, isFalse);
      expect(restored.reverbAmount, 0.3);
      expect(restored.virtualizerAmount, 0.7);
    });

    test('round trips full parametric band shape and clamps invalid values', () {
      final settings = DspSettings(
        parametricEqBands: const [
          ParametricEqBand(frequencyHz: 80, gainDb: 4.5, q: 1.7, type: 0),
          ParametricEqBand(frequencyHz: 12000, gainDb: -3, q: 0.8, type: 2),
        ],
      );
      final restored = DspSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored.parametricEqBands, hasLength(2));
      expect(restored.parametricEqBands[0].frequencyHz, 80);
      expect(restored.parametricEqBands[0].gainDb, 4.5);
      expect(restored.parametricEqBands[0].q, 1.7);
      expect(restored.parametricEqBands[0].type, 0);
      expect(restored.parametricEqBands[1].type, 2);

      final clamped = ParametricEqBand.fromJson({
        'frequencyHz': 30000,
        'gainDb': -40,
        'q': 0,
        'type': 99,
      });
      expect(clamped.frequencyHz, 20000);
      expect(clamped.gainDb, -24);
      expect(clamped.q, 0.1);
      expect(clamped.type, 4);

      final nonFinite = const ParametricEqBand(
        frequencyHz: 1000,
        q: 1,
      ).copyWith(frequencyHz: double.nan, q: double.infinity);
      expect(nonFinite.frequencyHz, 20);
      expect(nonFinite.q, 0.1);
    });

    test('migrates legacy 31-band graphic EQ into equivalent peak filters', () {
      final restored = DspSettings.fromJson({
        'version': 2,
        'eqBandGainsDb': List<double>.generate(31, (i) => i == 17 ? 5 : 0),
      });
      expect(restored.parametricEqBands, hasLength(31));
      expect(restored.parametricEqBands[17].frequencyHz, 1000);
      expect(restored.parametricEqBands[17].gainDb, 5);
      expect(restored.parametricEqBands[17].q, 4.3);
      expect(restored.parametricEqBands[17].type, 0);
    });

    test('schema v4 broad studio filters migrate but tuned parametric Q is preserved', () {
      const frequencies = [
        20.0, 25, 32, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
      ];
      final oldStudioBank = DspSettings.fromJson({
        'version': 4,
        'parametricEqBands': [
          for (final hz in frequencies)
            {'frequencyHz': hz, 'gainDb': 0, 'q': 1, 'type': 0},
        ],
      });
      expect(oldStudioBank.parametricEqBands.every((band) => band.q == 4.3), isTrue);
      expect(oldStudioBank.toJson()['version'], 6);

      final customBank = DspSettings.fromJson({
        'version': 4,
        'parametricEqBands': [
          for (var i = 0; i < frequencies.length; i++)
            {
              'frequencyHz': frequencies[i],
              'gainDb': 0,
              'q': i == 17 ? 1.0 : 2.5,
              'type': 0,
            },
        ],
      });
      expect(customBank.parametricEqBands[17].q, 1.0);
      expect(customBank.parametricEqBands[16].q, 2.5);
    });

    test('schema v5 migrates intelligence controls to safe independent defaults', () {
      final restored = DspSettings.fromJson({
        'version': 5,
        'preampDb': -3,
        'autoEqHeadroom': true,
      });
      expect(restored.preampDb, -3);
      expect(restored.autoEqHeadroom, isTrue);
      expect(restored.autoPreampEnabled, isFalse);
      expect(restored.autoPreampTargetDb, 0);
      expect(restored.autoVirtualBassEnabled, isFalse);
      expect(restored.autoVirtualBassTarget, 0.55);
      expect(restored.silenceHygieneEnabled, isFalse);
      expect(restored.silenceThresholdDb, -70);
      expect(restored.silenceHoldMs, 500);
      expect(restored.headroomBassWeight, 0.50);
      expect(restored.headroomPreampWeight, 0.20);
      expect(restored.headroomGainWeight, 0.30);
      expect(restored.toJson()['version'], 6);
    });

    test('an explicitly empty parametric list stays empty', () {
      final restored = DspSettings.fromJson({
        'version': 3,
        'eqBandGainsDb': [4.0, 2.0],
        'parametricEqBands': [],
      });
      expect(restored.parametricEqBands, isEmpty);
    });

    test('clamps controls independently and rejects unknown schema', () {
      final settings = DspSettings().copyWith(
        preampDb: 20,
        dvcDb: -500,
        dvcSmoothingMs: 500,
        limiterMode: 9,
        limiterThresholdDb: -30,
        limiterReleaseMs: 5000,
        limiterAttackMs: 0,
        limiterLookaheadMs: 100,
        limiterKneeDb: 20,
        ditherMode: 9,
        limiterCeilingDb: -30,
        limiterHighCeilingDb: -30,
        limiterLowCeilingDb: 2,
        crossoverHz: 500,
        virtualBassAmount: 2,
        reverbAmount: double.nan,
      );
      expect(settings.preampDb, 6);
      expect(settings.dvcDb, -120);
      expect(settings.dvcSmoothingMs, 200);
      expect(settings.limiterMode, 3);
      expect(settings.limiterThresholdDb, -24);
      expect(settings.limiterReleaseMs, 2000);
      expect(settings.limiterAttackMs, 0.01);
      expect(settings.limiterLookaheadMs, 40);
      expect(settings.limiterKneeDb, 12);
      expect(settings.ditherMode, 2);
      expect(settings.limiterCeilingDb, -12);
      expect(settings.limiterHighCeilingDb, -12);
      expect(settings.limiterLowCeilingDb, -0.05);
      expect(settings.crossoverHz, 200);
      expect(settings.virtualBassAmount, 1);
      expect(settings.reverbAmount, 0);
      expect(
        () => DspSettings.fromJson({'version': 999}),
        throwsFormatException,
      );
    });

    test('migrates schema v1 limiter ceiling into both bands and adds crossover default', () {
      final restored = DspSettings.fromJson({
        'version': 1,
        'masterEnabled': true,
        'limiterCeilingDb': -2.0,
      });
      expect(restored.masterEnabled, isTrue);
      expect(restored.limiterHighCeilingDb, -2);
      expect(restored.limiterLowCeilingDb, -2);
      expect(restored.crossoverHz, 120);
      expect(restored.toJson()['version'], DspSettings.schemaVersion);
    });

    test('migrates legacy DVC and EQ values to the versioned document', () async {
      SharedPreferences.setMockInitialValues({
        'live_dsp_dvc_db_v1': 3.0,
        'equalizer_enabled': false,
        'equalizer_preamp': -2.0,
        'eq_studio_band_1': 4.0,
      });
      final settings = await DspSettings.load();
      expect(settings.dvcDb, 3);
      expect(settings.eqEnabled, isTrue);
      expect(settings.preampDb, -2);
      expect(settings.eqBandGainsDb.length, 31);
      expect(settings.eqBandGainsDb[0], 0);
      expect(settings.eqBandGainsDb[1], 4);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DspSettings.preferenceKey), isNotNull);
    });

    test('replaces a corrupt canonical document from safe legacy defaults', () async {
      SharedPreferences.setMockInitialValues({
        DspSettings.preferenceKey: '{"version":999,"dvcDb":99}',
        'live_dsp_dvc_db_v1': -8.0,
        'equalizer_native_dsp': true,
      });
      final restored = await DspSettings.load();
      expect(restored.dvcDb, -8);
      expect(restored.masterEnabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(DspSettings.preferenceKey)!)
          as Map<String, dynamic>;
      expect(saved['version'], DspSettings.schemaVersion);
      expect(saved['dvcDb'], -8);
    });

    test('serialized field updates preserve each other under overlap', () async {
      await DspSettings.save(DspSettings(
        masterEnabled: true,
        dvcDb: 1,
        reverbAmount: 0.2,
        virtualizerAmount: 0.1,
      ));
      await Future.wait([
        DspSettings.update((current) => current.copyWith(dvcDb: 4)),
        DspSettings.update((current) => current.copyWith(reverbAmount: 0.8)),
        DspSettings.update((current) => current.copyWith(virtualizerAmount: 0.6)),
      ]);
      final restored = await DspSettings.load();
      expect(restored.masterEnabled, isTrue);
      expect(restored.dvcDb, 4);
      expect(restored.reverbAmount, 0.8);
      expect(restored.virtualizerAmount, 0.6);
    });

    test('DVC and limiter settings survive repeated field updates and reload', () async {
      await DspSettings.save(DspSettings(
        dvcDb: -3.5,
        dvcEnabled: false,
        dvcSmoothing: false,
        dvcSmoothingMs: 42,
        limiterEnabled: true,
        limiterMode: 3,
        limiterThresholdDb: -5,
        limiterAttackMs: 0.8,
        limiterReleaseMs: 180,
        limiterLookaheadMs: 4,
        limiterKneeDb: 3,
        limiterHighCeilingDb: -1.2,
        limiterLowCeilingDb: -2.4,
        crossoverHz: 150,
      ));

      await Future.wait([
        DspSettings.update((s) => s.copyWith(dvcDb: 2.0)),
        DspSettings.update((s) => s.copyWith(limiterEnabled: false)),
        DspSettings.update((s) => s.copyWith(dvcSmoothingMs: 64)),
        DspSettings.update((s) => s.copyWith(limiterHighCeilingDb: -0.8)),
      ]);

      final restored = await DspSettings.load();
      expect(restored.dvcDb, 2);
      expect(restored.dvcEnabled, isFalse);
      expect(restored.dvcSmoothing, isFalse);
      expect(restored.dvcSmoothingMs, 64);
      expect(restored.limiterEnabled, isFalse);
      expect(restored.limiterMode, 3);
      expect(restored.limiterThresholdDb, -5);
      expect(restored.limiterAttackMs, 0.8);
      expect(restored.limiterReleaseMs, 180);
      expect(restored.limiterLookaheadMs, 4);
      expect(restored.limiterKneeDb, 3);
      expect(restored.limiterHighCeilingDb, -0.8);
      expect(restored.limiterLowCeilingDb, -2.4);
      expect(restored.crossoverHz, 150);
    });

    test('non-finite EQ band values fall back safely', () {
      final settings = DspSettings(eqBandGainsDb: [double.infinity, 20, -20]);
      expect(settings.eqBandGainsDb, [0, 12, -12]);
    });
  });
}
