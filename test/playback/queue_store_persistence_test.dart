import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonate/models/song.dart';
import 'package:resonate/playback/queue_store.dart';

Song _song(String id) => Song(
      id: id,
      title: id,
      artist: 'Artist',
      album: 'Album',
      filePath: '/music/$id.mp3',
      duration: const Duration(minutes: 3),
      dateAdded: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('queue persistence snapshots and serializes rapid queue mutations', () async {
    final store = QueueStore()..replace(<Song>[_song('first'), _song('second')], index: 1);

    final firstWrite = store.persist();
    store.replace(<Song>[_song('replacement')], index: 0);
    final secondWrite = store.persist();

    await Future.wait(<Future<void>>[firstWrite, secondWrite]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(QueueStore.savedQueueIdsKey), <String>['replacement']);
    expect(prefs.getInt(QueueStore.savedQueueIndexKey), 0);
  });

  test('a queued clear cannot overwrite a later queue restoration', () async {
    final store = QueueStore()..replace(<Song>[_song('old')]);

    final clearWrite = store.persist();
    store.replace(<Song>[_song('restored'), _song('next')], index: 1);
    final restoreWrite = store.persist();

    await Future.wait(<Future<void>>[clearWrite, restoreWrite]);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList(QueueStore.savedQueueIdsKey),
      <String>['restored', 'next'],
    );
    expect(prefs.getInt(QueueStore.savedQueueIndexKey), 1);
  });
}
