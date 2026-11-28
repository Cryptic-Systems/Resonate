import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const manifestPath = 'assets/audio/resonate_voice/voice_manifest.json';
  const assetRoot = 'assets/audio/resonate_voice/';

  late Map<String, dynamic> manifest;
  late List<dynamic> assets;

  setUpAll(() {
    final decoded = jsonDecode(File(manifestPath).readAsStringSync());
    expect(decoded, isA<Map<String, dynamic>>());
    manifest = decoded as Map<String, dynamic>;
    assets = manifest['assets'] as List<dynamic>;
  });

  test('manifest contains 84 unique, filename-audited entries', () {
    expect(manifest['schemaVersion'], 1);
    expect(manifest['status'],
        'filename_routes_enabled_audio_assets_extracted_listening_review_pending');
    expect(assets, hasLength(84));

    final ids = assets.map((entry) => (entry as Map)['id']).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.every((id) => id is String && id.trim().isNotEmpty), isTrue);
  });

  test('mode-change cues are enabled for shared-system playback', () {
    final modeCues = assets
        .where((raw) => (raw as Map<String, dynamic>)['id']
            .toString()
            .startsWith('mode_policy.voice_mode_'))
        .cast<Map<String, dynamic>>()
        .toList();

    expect(modeCues, hasLength(9));
    for (final cue in modeCues) {
      expect(cue['runtimeEnabled'], isTrue, reason: cue['id'].toString());
      expect(cue['allowedOrigins'], contains('sharedSystem'),
          reason: cue['id'].toString());
      expect(cue['routingProposal'], 'conditional',
          reason: cue['id'].toString());
      final path = cue['assetPath'] as String;
      expect(File(path).existsSync(), isTrue, reason: cue['id'].toString());
    }
  });

  test('all enabled entries have safe unique paths and known policy values', () {
    const routes = {
      'player_auto',
      'dj_manual',
      'both_contextual',
      'shared_system',
      'conditional',
    };
    const origins = {'playerAuto', 'djManual', 'sharedSystem'};
    final assetPaths = <String>{};

    for (final raw in assets) {
      final entry = raw as Map<String, dynamic>;
      expect(entry['filename'], isA<String>());
      expect((entry['filename'] as String).trim(), isNotEmpty);
      expect(entry['sourceArchive'], isA<String>());
      expect(entry['category'], isA<String>());
      expect(routes, contains(entry['routingProposal']));
      expect(entry['allowedOrigins'], isA<List<dynamic>>());
      expect(entry['allowedOrigins'], isNotEmpty);
      for (final origin in (entry['allowedOrigins'] as List<dynamic>)) {
        expect(origins, contains(origin));
      }
      expect(entry['semanticGroupProposal'], isA<String>());
      expect((entry['semanticGroupProposal'] as String).trim(), isNotEmpty);
      expect(entry['evidence'], 'filename_and_routing_document_only');
      expect(entry['assetPath'], isA<String>());
      final path = entry['assetPath'] as String;
      expect(path, startsWith(assetRoot));
      expect(path.split('/'), isNot(contains('..')));
      expect(path, isNot(contains('\\')));
      expect(path, endsWith('.mp3'));
      expect(assetPaths.add(path), isTrue, reason: 'Duplicate asset path: $path');
      expect(entry['runtimeEnabled'], isTrue);

      final asset = File(path);
      expect(asset.existsSync(), isTrue, reason: 'Missing cue asset: $path');
      expect(asset.lengthSync(), greaterThan(0), reason: 'Empty cue asset: $path');
    }
  });

  test('every source archive reference resolves to a tracked archive', () {
    final archivePaths = assets
        .map((entry) => (entry as Map<String, dynamic>)['sourceArchive'])
        .toSet();

    expect(archivePaths, hasLength(8));
    for (final path in archivePaths) {
      expect(path, isA<String>());
      final archivePath = path as String;
      expect(archivePath, startsWith('${assetRoot}source_archives/'));
      expect(archivePath.split('/'), isNot(contains('..')));
      final file = File(archivePath);
      expect(file.existsSync(), isTrue, reason: 'Missing source archive: $path');
      expect(file.lengthSync(), greaterThan(0), reason: 'Empty source archive: $path');
    }
  });
}
