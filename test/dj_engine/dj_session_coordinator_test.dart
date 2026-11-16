import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';
import 'package:resonate/models/dj_analysis.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/services/dj_analysis_service.dart';
import 'package:resonate/services/dj_session_coordinator.dart';

class _MemoryDjAnalysisService extends DjAnalysisService {
  _MemoryDjAnalysisService(this.rows);

  final Map<String, DjAnalysis> rows;

  @override
  Future<DjAnalysis?> getAnalysis(String songId) async => rows[songId];

  @override
  Future<DjTrackProfile?> getProfile(String songId) async => null;
}

Song _song(String id) => Song(
      id: id,
      title: 'Track $id',
      artist: 'Artist $id',
      album: 'Album',
      filePath: '/music/$id.mp3',
      duration: const Duration(minutes: 4),
      dateAdded: DateTime(2025, 1, 1),
    );

DjAnalysis _analysis(String id, {required double energy, required int key}) =>
    DjAnalysis(
      songId: id,
      bpm: 126 + key.toDouble(),
      bpmConfidence: 0.96,
      beatOffsetMs: 120,
      bpmSource: 'pcm_profile_v2',
      keyRoot: key,
      keyMode: 'minor',
      durationMs: 240000,
      energy: energy,
      loudness: energy,
      introHintMs: 12000,
      outroHintMs: 210000,
    );

void main() {
  test('creates a library Suggestion Mix without touching playback state', () async {
    final songs = [_song('a'), _song('b'), _song('c')];
    final analysis = _MemoryDjAnalysisService({
      'a': _analysis('a', energy: 0.25, key: 0),
      'b': _analysis('b', energy: 0.65, key: 2),
      'c': _analysis('c', energy: 0.90, key: 4),
    });
    final coordinator = DjSessionCoordinator(analysis: analysis);

    final mix = await coordinator.create(
      songs: songs,
      scope: DjSessionScope.library,
      random: math.Random(7),
    );

    expect(mix.scope, DjSessionScope.library);
    expect(mix.sourceSongs.map((song) => song.id), ['a', 'b', 'c']);
    expect(mix.orderedSongs.map((song) => song.id).toSet(), {'a', 'b', 'c'});
    expect(mix.orderedSongs, hasLength(3));
    expect(mix.usedDjArrangement, isTrue);
    expect(mix.analysisCoverage, 1);
    expect(mix.transitions, hasLength(2));
    expect(mix.transitions.first.outgoingSongId, mix.orderedSongs[0].id);
    expect(mix.transitions.first.incomingSongId, mix.orderedSongs[1].id);
    expect(mix.revision, 1);
  });

  test('reorder recomputes adjacent plans and increments revision', () async {
    final songs = [_song('a'), _song('b'), _song('c')];
    final analysis = _MemoryDjAnalysisService({
      'a': _analysis('a', energy: 0.25, key: 0),
      'b': _analysis('b', energy: 0.65, key: 2),
      'c': _analysis('c', energy: 0.90, key: 4),
    });
    final coordinator = DjSessionCoordinator(analysis: analysis);
    final mix = await coordinator.create(
      songs: songs,
      scope: DjSessionScope.playlist,
      scopeId: 'playlist-1',
      random: math.Random(7),
    );

    final reordered = coordinator.reorder(
      mix: mix,
      orderedSongIds: ['c', 'a', 'b'],
    );

    expect(reordered.scope, DjSessionScope.playlist);
    expect(reordered.scopeId, 'playlist-1');
    expect(reordered.orderedSongs.map((song) => song.id), ['c', 'a', 'b']);
    expect(reordered.transitions, hasLength(2));
    expect(reordered.transitions.first.outgoingSongId, 'c');
    expect(reordered.transitions.first.incomingSongId, 'a');
    expect(reordered.revision, 2);
    expect(mix.orderedSongs.map((song) => song.id).toSet(), {'a', 'b', 'c'});
  });

  test('rejects reorder operations that omit or duplicate source tracks', () async {
    final songs = [_song('a'), _song('b'), _song('c')];
    final analysis = _MemoryDjAnalysisService({
      'a': _analysis('a', energy: 0.25, key: 0),
      'b': _analysis('b', energy: 0.65, key: 2),
      'c': _analysis('c', energy: 0.90, key: 4),
    });
    final coordinator = DjSessionCoordinator(analysis: analysis);
    final mix = await coordinator.create(
      songs: songs,
      scope: DjSessionScope.library,
      random: math.Random(7),
    );

    expect(
      () => coordinator.reorder(mix: mix, orderedSongIds: ['a', 'b', 'b']),
      throwsArgumentError,
    );
    expect(
      () => coordinator.reorder(mix: mix, orderedSongIds: ['a', 'b']),
      throwsArgumentError,
    );
  });

  test('approval returns the reviewed order without changing its source', () async {
    final songs = [_song('a'), _song('b'), _song('c')];
    final analysis = _MemoryDjAnalysisService({
      'a': _analysis('a', energy: 0.25, key: 0),
      'b': _analysis('b', energy: 0.65, key: 2),
      'c': _analysis('c', energy: 0.90, key: 4),
    });
    final coordinator = DjSessionCoordinator(analysis: analysis);
    final mix = await coordinator.create(
      songs: songs,
      scope: DjSessionScope.library,
      random: math.Random(7),
    );
    final reviewed = coordinator.reorder(
      mix: mix,
      orderedSongIds: ['b', 'c', 'a'],
    );

    final approved = coordinator.approve(reviewed);

    expect(approved.songs.map((song) => song.id), ['b', 'c', 'a']);
    expect(approved.sourceScope, DjSessionScope.library);
    expect(approved.revision, 2);
    expect(mix.sourceSongs.map((song) => song.id), ['a', 'b', 'c']);
  });


  test('degrades to a safe profile when cached analysis metadata is incomplete', () async {
    final songs = [_song('a'), _song('b')];
    final rows = {
      for (final id in ['a', 'b'])
        id: DjAnalysis(
          songId: id,
          bpm: 128,
          bpmConfidence: 0.96,
          bpmSource: 'pcm_profile_v2',
          durationMs: null,
          outroHintMs: 210000,
        ),
    };
    final coordinator = DjSessionCoordinator(
      analysis: _MemoryDjAnalysisService(rows),
    );

    final mix = await coordinator.create(
      songs: songs,
      scope: DjSessionScope.library,
      random: math.Random(3),
    );

    expect(mix.orderedSongs, hasLength(2));
    expect(mix.profiles.values.every((profile) => profile.analysisConfidence == 0), isTrue);
    expect(mix.transitions, hasLength(1));
    expect(mix.transitions.single.plan.fallback, isTrue);
  });

  test('playlist scope requires an explicit playlist ID', () async {
    final coordinator = DjSessionCoordinator(
      analysis: _MemoryDjAnalysisService({}),
    );

    await expectLater(
      coordinator.create(
        songs: [_song('a')],
        scope: DjSessionScope.playlist,
      ),
      throwsArgumentError,
    );
  });
}
