import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonate/services/resonate_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('diagnostic sanitizer redacts secrets and excludes binary audio payloads', () async {
    await ResonateDiagnostics.record('sanitizer_test', <String, dynamic>{
      'password': 'do-not-export',
      'access_token': 'secret-token',
      'email': 'listener@example.com',
      'error': 'Authorization: Bearer abc.def.ghi https://example.test/?token=hidden',
      'filePath': '/storage/emulated/0/Music/Artist/Track.flac',
      'pcmData': <int>[1, 2, 3, 4],
      'positionMs': 1200,
    });

    final report = await ResonateDiagnostics.snapshot();
    final events = report['events'] as List;
    final event = events.cast<Map>().singleWhere(
      (entry) => entry['type'] == 'sanitizer_test',
    );
    final data = Map<String, dynamic>.from(event['data'] as Map);

    expect(data['password'], '[REDACTED]');
    expect(data['access_token'], '[REDACTED]');
    expect(data['email'], '[REDACTED]');
    expect(data['error'], contains('Bearer [REDACTED]'));
    expect(data['error'], contains('token=[REDACTED]'));
    expect(data['filePath'], 'Track.flac');
    expect(data['pcmData'], '[AUDIO_CONTENT_EXCLUDED]');
    expect(data['positionMs'], 1200);
    expect(report['reportVersion'], 6);
    expect(report['droppedEventCount'], 0);
  });
}
