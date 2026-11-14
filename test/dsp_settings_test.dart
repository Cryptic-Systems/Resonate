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
        limiterCeilingDb: -3,
        limiterHighCeilingDb: -2.5,
        limiterLowCeilingDb: -1.5,
        crossoverHz: 160,
        speakerProtectionEnabled: true,
        virtualBassAmount: 0.4,
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
      expect(restored.limiterCeilingDb, -3);
      expect(restored.limiterHighCeilingDb, -2.5);
      expect(restored.limiterLowCeilingDb, -1.5);
      expect(restored.crossoverHz, 160);
      expect(restored.speakerProtectionEnabled, isTrue);
      expect(restored.eqBandGainsDb, [3, -2, 1]);
      expect(restored.virtualBassAmount, 0.4);
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
    });

    test('migrates legacy 31-band graphic EQ into equivalent peak filters', () {
      final restored = DspSettings.fromJson({
        'version': 2,
        'eqBandGainsDb': List<double>.generate(31, (i) => i == 7 ? 5 : 0),
      });
      expect(restored.parametricEqBands, hasLength(31));
      expect(restored.parametricEqBands[7].frequencyHz, 1000);
      expect(restored.parametricEqBands[7].gainDb, 5);
      expect(restored.parametricEqBands[7].q, 1);
      expect(restored.parametricEqBands[7].type, 0);
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
        dvcDb: -50,
        limiterCeilingDb: -30,
        limiterHighCeilingDb: -30,
        limiterLowCeilingDb: 2,
        crossoverHz: 500,
        virtualBassAmount: 2,
        reverbAmount: double.nan,
      );
      expect(settings.preampDb, 6);
      expect(settings.dvcDb, -24);
      expect(settings.limiterCeilingDb, -12);
      expect(settings.limiterHighCeilingDb, -6);
      expect(settings.limiterLowCeilingDb, -0.1);
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

    test('non-finite EQ band values fall back safely', () {
      final settings = DspSettings(eqBandGainsDb: [double.infinity, 20, -20]);
      expect(settings.eqBandGainsDb, [0, 12, -12]);
    });
  });
}
