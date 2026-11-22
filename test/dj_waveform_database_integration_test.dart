import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:resonate/services/database_helper.dart';

void main() {
  late Database db;
  final helper = DatabaseHelper();

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await helper.createForTesting(db);
    DatabaseHelper.databaseForTesting = db;
  });

  tearDown(() async {
    await db.close();
  });

  test('version 8 database migrates additively to waveform tables', () async {
    final legacy = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await legacy.execute(
      'CREATE TABLE songs (id TEXT PRIMARY KEY, title TEXT NOT NULL, '
      'artist TEXT, album TEXT, file_path TEXT NOT NULL UNIQUE, duration INTEGER, '
      'date_added TEXT, album_art TEXT, play_count INTEGER DEFAULT 0, last_played TEXT)',
    );
    await legacy.insert('songs', {
      'id': 'legacy-song',
      'title': 'Legacy',
      'file_path': '/legacy.mp3',
    });

    await helper.upgradeForTesting(legacy, 8, 9);

    final tables = await legacy.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    expect(names, contains('songs'));
    expect(names, contains('dj_waveform_chunks'));
    expect(names, contains('dj_waveform_manifests'));
    expect(await legacy.query('songs'), hasLength(1));
    await legacy.close();
  });

  test('chunk primary key makes retries idempotent and replaces stale identity', () async {
    await db.insert('songs', {
      'id': 'song-1',
      'title': 'Test',
      'file_path': '/test.mp3',
    });

    final first = <String, Object?>{
      'song_id': 'song-1',
      'analysis_version': 3,
      'chunk_index': 0,
      'requested_start_ms': 0,
      'requested_end_ms': 8000,
      'actual_start_ms': 0,
      'actual_end_ms': 8000,
      'source_fingerprint': 'fingerprint-a',
      'duration_ms': 16000,
      'sample_rate': 44100,
      'channels': 2,
      'peaks_json': '[0.1,0.2]',
      'completed_at': '2026-11-22T00:00:00.000Z',
      'schema_version': 1,
    };
    await db.insert('dj_waveform_chunks', first, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
      'dj_waveform_chunks',
      {...first, 'source_fingerprint': 'fingerprint-b', 'peaks_json': '[0.7,0.8]'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final rows = await db.query('dj_waveform_chunks');
    expect(rows, hasLength(1));
    expect(rows.single['source_fingerprint'], 'fingerprint-b');
    expect(rows.single['peaks_json'], '[0.7,0.8]');
  });

  test('song deletion atomically removes waveform and DJ dependent rows', () async {
    await db.insert('songs', {
      'id': 'song-delete',
      'title': 'Delete me',
      'file_path': '/delete.mp3',
    });
    await db.insert('dj_waveform_chunks', {
      'song_id': 'song-delete',
      'analysis_version': 1,
      'chunk_index': 0,
      'requested_start_ms': 0,
      'requested_end_ms': 8000,
      'actual_start_ms': 0,
      'actual_end_ms': 8000,
      'source_fingerprint': 'fingerprint',
      'duration_ms': 8000,
      'sample_rate': 44100,
      'channels': 2,
      'peaks_json': '[0.2]',
      'completed_at': '2026-11-22T00:00:00.000Z',
      'schema_version': 1,
    });
    await db.insert('dj_waveform_manifests', {
      'song_id': 'song-delete',
      'analysis_version': 1,
      'source_fingerprint': 'fingerprint',
      'duration_ms': 8000,
      'schema_version': 1,
      'expected_chunk_count': 1,
      'completed_indices_json': '[0]',
      'updated_at': '2026-11-22T00:00:00.000Z',
    });
    await db.insert('song_dj_analysis', {
      'song_id': 'song-delete',
      'analysis_version': 1,
    });
    await db.insert('song_dj_profiles', {
      'song_id': 'song-delete',
      'profile_json': '{}',
      'analysis_version': 1,
    });

    expect(await helper.deleteSong('song-delete'), 1);
    expect(await db.query('songs'), isEmpty);
    expect(await db.query('dj_waveform_chunks'), isEmpty);
    expect(await db.query('dj_waveform_manifests'), isEmpty);
    expect(await db.query('song_dj_analysis'), isEmpty);
    expect(await db.query('song_dj_profiles'), isEmpty);
  });

  test('invalid chunk ranges are rejected by SQLite constraints', () async {
    await db.insert('songs', {
      'id': 'song-invalid',
      'title': 'Invalid',
      'file_path': '/invalid.mp3',
    });
    expect(
      () => db.insert('dj_waveform_chunks', {
        'song_id': 'song-invalid',
        'analysis_version': 1,
        'chunk_index': 0,
        'requested_start_ms': 8000,
        'requested_end_ms': 1000,
        'actual_start_ms': 0,
        'actual_end_ms': 100,
        'duration_ms': 10000,
        'sample_rate': 44100,
        'channels': 2,
        'peaks_json': '[0.1]',
        'completed_at': '2026-11-22T00:00:00.000Z',
        'schema_version': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });
}
