import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonate/services/dj_cue_point_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DjCuePointStore', () {
    late DjCuePointStore store;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      store = DjCuePointStore();
    });

    test('persists independent cue points by track identity', () async {
      await store.saveAll(<String, Duration>{
        'track-a': const Duration(seconds: 31, milliseconds: 250),
        'track-b': const Duration(minutes: 1, seconds: 4),
      });

      final loaded = await store.load();
      expect(loaded['track-a'], const Duration(seconds: 31, milliseconds: 250));
      expect(loaded['track-b'], const Duration(minutes: 1, seconds: 4));
    });

    test('ignores malformed or negative cue values', () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'resonate_dj_cue_points_v1',
        '{"valid":12000,"negative":-1,"bad":"not-a-number","":"3000"}',
      );

      expect(
        await store.load(),
        <String, Duration>{'valid': const Duration(seconds: 12)},
      );
    });

    test('drops empty identities and negative positions on save', () async {
      await store.saveAll(<String, Duration>{
        'track-a': const Duration(seconds: 8),
        ' ': const Duration(seconds: 4),
        'track-b': const Duration(milliseconds: -1),
      });

      expect(
        await store.load(),
        <String, Duration>{'track-a': const Duration(seconds: 8)},
      );
    });
  });
}
