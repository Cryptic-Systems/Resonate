import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/models/dsp_settings.dart';
import 'package:resonate/models/resonate_sound_profile.dart';

void main() {
  group('ResonateSoundProfile', () {
    test('round trips a complete DSP snapshot and profile metadata', () {
      final profile = ResonateSoundProfile(
        id: 'user:studio-reference',
        name: 'Studio Reference',
        description: 'A complete saved listening configuration',
        category: 'Custom',
        settings: DspSettings(
          preset: 'Custom',
          eqBandGainsDb: [1, -1, 0.5],
          parametricEqBands: const [
            ParametricEqBand(frequencyHz: 80, gainDb: 2, q: 0.8),
            ParametricEqBand(frequencyHz: 3200, gainDb: -1.5, q: 1.2, type: 0),
          ],
          preampDb: -2,
          autoEqHeadroom: true,
          dvcEnabled: true,
          dvcDb: 1.5,
          dvcSmoothing: true,
          dvcSmoothingMs: 24,
          limiterEnabled: true,
          limiterMode: 3,
          limiterThresholdDb: -2,
          limiterAttackMs: 0.5,
          limiterReleaseMs: 180,
          limiterLookaheadMs: 4,
          limiterKneeDb: 2,
          limiterHighCeilingDb: -1,
          limiterLowCeilingDb: -1.5,
          crossoverHz: 145,
          speakerProtectionEnabled: true,
          virtualBassAmount: 0.25,
          ditherEnabled: true,
          ditherMode: 2,
          effectsEnabled: true,
          reverbAmount: 0.1,
          virtualizerAmount: 0.3,
        ),
      );

      final restored = ResonateSoundProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );

      expect(restored.id, profile.id);
      expect(restored.name, profile.name);
      expect(restored.description, profile.description);
      expect(restored.category, profile.category);
      expect(restored.isBuiltIn, isFalse);
      expect(restored.settings.toJson(), profile.settings.toJson());
    });

    test('requires a supported profile schema and complete DSP settings', () {
      expect(
        () => ResonateSoundProfile.fromJson({
          'format': ResonateSoundProfile.format,
          'version': 99,
          'id': 'profile:test',
          'name': 'Test',
          'settings': DspSettings().toJson(),
        }),
        throwsFormatException,
      );
      expect(
        () => ResonateSoundProfile.fromJson({
          'format': ResonateSoundProfile.format,
          'version': ResonateSoundProfile.schemaVersion,
          'id': 'profile:test',
          'name': 'Test',
          'settings': {},
        }),
        throwsFormatException,
      );
      expect(
        () => ResonateSoundProfile.fromJson({
          'format': ResonateSoundProfile.format,
          'version': ResonateSoundProfile.schemaVersion,
          'id': ' ',
          'name': 'Test',
          'settings': DspSettings().toJson(),
        }),
        throwsFormatException,
      );
    });

    test('rejects oversized and malformed portable profile data', () {
      final base = {
        'format': ResonateSoundProfile.format,
        'version': ResonateSoundProfile.schemaVersion,
        'id': 'profile:test',
        'name': 'Test',
        'settings': DspSettings().toJson(),
      };
      expect(
        () => ResonateSoundProfile.fromJson({
          ...base,
          'name': 'x' * 65,
        }),
        throwsFormatException,
      );
      expect(
        () => ResonateSoundProfile.fromJson({
          ...base,
          'description': 'x' * 281,
        }),
        throwsFormatException,
      );
      expect(
        () => ResonateSoundProfile.fromJson({
          ...base,
          'settings': {
            ...DspSettings().toJson(),
            'parametricEqBands': List.generate(
              32,
              (index) => {
                'frequencyHz': 100 + index,
                'gainDb': 0,
                'q': 1,
                'type': 0,
              },
            ),
          },
        }),
        throwsFormatException,
      );
      expect(
        () => ResonateSoundProfile.fromJson({
          ...base,
          'settings': {
            ...DspSettings().toJson(),
            'parametricEqBands': [
              {'frequencyHz': 100, 'gainDb': 0, 'q': 1, 'type': 8},
            ],
          },
        }),
        throwsFormatException,
      );
    });

    test('retains built-in metadata without allowing it to alter DSP schema', () {
      final profile = ResonateSoundProfile(
        id: 'resonate:signature',
        name: 'Resonate Signature',
        category: 'Resonate',
        isBuiltIn: true,
        settings: DspSettings(),
      );
      final restored = ResonateSoundProfile.fromJson(profile.toJson());
      expect(restored.isBuiltIn, isTrue);
      expect(restored.id, 'resonate:signature');
      expect(restored.settings.toJson()['version'], DspSettings.schemaVersion);
    });
  });
}
