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

    test('persists four independent hot-cue slots per track', () async {
      await store.saveAll(<String, List<Duration?>>{
        'track-a': <Duration?>[const Duration(seconds: 12), const Duration(seconds: 48), null, const Duration(minutes: 2)],
      });
      expect(await store.load(), <String, List<Duration?>>{
        'track-a': <Duration?>[const Duration(seconds: 12), const Duration(seconds: 48), null, const Duration(minutes: 2)],
      });
    });

    test('migrates legacy single cue into hot-cue slot one', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'resonate_dj_cue_points_v1': '{"track-old":37500,"negative":-1,"bad":"nope"}',
      });
      expect(await store.load(), <String, List<Duration?>>{
        'track-old': <Duration?>[const Duration(milliseconds: 37500), null, null, null],
      });
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('resonate_dj_hot_cues_v2'), isNotNull);
    });

    test('normalizes slot count and drops empty identities and negative positions', () async {
      await store.saveAll(<String, List<Duration?>>{
        'track-a': <Duration?>[const Duration(seconds: 8), const Duration(milliseconds: -1)],
        ' ': <Duration?>[const Duration(seconds: 4)],
      });
      expect(await store.load(), <String, List<Duration?>>{
        'track-a': <Duration?>[const Duration(seconds: 8), null, null, null],
      });
    });
  });
}