import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const manifestPath = 'assets/audio/resonate_voice/voice_manifest.json';

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

  test('extracted filename mappings are enabled but remain listening-review pending', () {
    for (final raw in assets) {
      final entry = raw as Map<String, dynamic>;
      expect(entry['filename'], isA<String>());
      expect((entry['filename'] as String).trim(), isNotEmpty);
      expect(entry['sourceArchive'], isA<String>());
      expect(entry['category'], isA<String>());
      expect(entry['routingProposal'], isA<String>());
      expect(entry['allowedOrigins'], isA<List<dynamic>>());
      expect(entry['allowedOrigins'], isNotEmpty);
      expect(entry['semanticGroupProposal'], isA<String>());
      expect(entry['evidence'], 'filename_and_routing_document_only');
      expect(entry['assetPath'], isA<String>());
      expect(entry['runtimeEnabled'], isTrue);
      final asset = File(entry['assetPath'] as String);
      expect(asset.existsSync(), isTrue, reason: 'Missing cue asset: ${entry['assetPath']}');
      expect(asset.lengthSync(), greaterThan(0), reason: 'Empty cue asset: ${entry['assetPath']}');
    }
  });

  test('every source archive reference resolves to a tracked archive', () {
    final archivePaths = assets
        .map((entry) => (entry as Map<String, dynamic>)['sourceArchive'])
        .toSet();

    expect(archivePaths, hasLength(8));
    for (final path in archivePaths) {
      expect(path, isA<String>());
      final file = File(path as String);
      expect(file.existsSync(), isTrue, reason: 'Missing source archive: $path');
      expect(file.lengthSync(), greaterThan(0), reason: 'Empty source archive: $path');
    }
  });
}
