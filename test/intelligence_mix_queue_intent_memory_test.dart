import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/models/intelligence_mix.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/services/intelligence_mix_memory.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stores queue intent with each mix edition for restoration and evolution', () async {
    final song = Song(
      id: 'calm-track',
      title: 'Calm Track',
      artist: 'Artist',
      album: 'Album',
      filePath: '/music/calm.mp3',
      duration: const Duration(minutes: 3),
      dateAdded: DateTime(2026),
    );
    const memory = IntelligenceMixMemory();
    await memory.remember(IntelligenceMix(
      id: 'mix-calmer-1',
      title: 'Calmer local mix',
      description: 'A calm DJ-arranged sequence',
      songs: [song],
      targetDuration: const Duration(minutes: 30),
      createdAt: DateTime(2026),
      reason: 'Calmer flow',
      queueIntentId: 'calmer_mix',
    ));

    final entries = await memory.recent();
    expect(entries, hasLength(1));
    expect(entries.single['queueIntentId'], 'calmer_mix');
    expect(entries.single['songIds'], ['calm-track']);
  });

  test('re-remembering an evolved edition replaces its intermediate sequence', () async {
    final a = Song(
      id: 'track-a', title: 'A', artist: 'Artist', album: 'Album',
      filePath: '/music/a.mp3', duration: const Duration(minutes: 3),
      dateAdded: DateTime(2026),
    );
    final b = Song(
      id: 'track-b', title: 'B', artist: 'Artist', album: 'Album',
      filePath: '/music/b.mp3', duration: const Duration(minutes: 3),
      dateAdded: DateTime(2026),
    );
    const memory = IntelligenceMixMemory();
    final intermediate = IntelligenceMix(
      id: 'mix-evolved', title: 'Calmer • Refined', description: 'intermediate',
      songs: [a], targetDuration: const Duration(minutes: 30),
      createdAt: DateTime(2026), reason: 'Refined',
      parentMixId: 'mix-original', queueIntentId: 'calmer_mix', edition: 2,
    );
    await memory.remember(intermediate);
    await memory.remember(IntelligenceMix(
      id: 'mix-evolved', title: 'Calmer • Refined', description: 'final',
      songs: [b], targetDuration: const Duration(minutes: 30),
      createdAt: DateTime(2026), reason: 'Refined',
      parentMixId: 'mix-original', queueIntentId: 'calmer_mix', edition: 2,
    ));

    final entries = await memory.recent();
    expect(entries, hasLength(1));
    expect(entries.single['songIds'], ['track-b']);
    expect(entries.single['queueIntentId'], 'calmer_mix');
    expect(entries.single['parentMixId'], 'mix-original');
  });
}
