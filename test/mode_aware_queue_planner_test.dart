import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/models/queue_intent.dart';
import 'package:resonate/models/queue_plan.dart';
import 'package:resonate/models/song.dart';
import 'package:resonate/modes/models/resonate_mode.dart';
import 'package:resonate/modes/providers/mode_provider.dart';
import 'package:resonate/services/intelligent_queue_planner.dart';
import 'package:resonate/services/mode_aware_queue_planner.dart';

Song _song(String id, String path) => Song(id: id, title: id, artist: 'Artist', album: 'Album', filePath: path, duration: const Duration(minutes: 3), dateAdded: DateTime(2026));

class _FixedPlanner extends IntelligentQueuePlanner {
  _FixedPlanner(this.result);
  final QueuePlan result;
  @override
  Future<QueuePlan> plan(List<Song> scope, {required QueueIntent intent}) async => result;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Sleep DJ-arranges music slots without moving audiobook or podcast slots', () async {
    final modes = ModeProvider();
    await modes.ready;
    await modes.setMode(ResonateMode.sleep);
    final a = _song('music-a', '/music/a.mp3');
    final book = _song('book', '/audiobooks/book/chapter-1.mp3');
    final b = _song('music-b', '/music/b.mp3');
    final podcast = _song('podcast', '/podcasts/show/episode-1.mp3');
    final c = _song('music-c', '/music/c.mp3');
    final plan = QueuePlan(intentId: QueueIntent.sleep.id, songs: [c, a], status: QueuePlanStatus.partial, analysisCoverage: 1, analyzedTrackCount: 3, eligibleTrackCount: 2, excludedSongIds: ['music-b'], reason: 'One track was outside the profile.');
    final result = await ModeAwareQueuePlanner(planner: _FixedPlanner(plan)).arrange(modes: modes, tracks: [a, book, b, podcast, c]);
    expect(result.songs.map((song) => song.id), ['music-c', 'book', 'music-a', 'podcast', 'music-b']);
    expect(result.songs.where((song) => song.id == 'book').single, same(book));
    expect(result.songs.where((song) => song.id == 'podcast').single, same(podcast));
    expect(result.message, contains('Spoken-content order was preserved'));
    modes.dispose();
  });

  test('Motivation keeps speech anchors in place while DJ arranges music', () async {
    final modes = ModeProvider();
    await modes.ready;
    await modes.setMode(ResonateMode.motivation);
    final speechA = _song('speech-a', '/motivation/speech-a.mp3');
    final musicA = _song('music-a', '/music/a.mp3');
    final speechB = _song('speech-b', '/motivation/speech-b.mp3');
    final musicB = _song('music-b', '/music/b.mp3');
    final plan = QueuePlan(intentId: QueueIntent.motivation.id, songs: [musicB, musicA], status: QueuePlanStatus.ready, analysisCoverage: 1, analyzedTrackCount: 2, eligibleTrackCount: 2);
    final result = await ModeAwareQueuePlanner(planner: _FixedPlanner(plan)).arrange(modes: modes, tracks: [speechA, musicA, speechB, musicB]);
    expect(result.songs.map((song) => song.id), ['speech-a', 'music-b', 'speech-b', 'music-a']);
    modes.dispose();
  });

  test('Work mode preserves allowed spoken anchors while arranging music', () async {
    final modes = ModeProvider();
    await modes.ready;
    await modes.setMode(ResonateMode.work);
    final musicA = _song('music-a', '/music/a.mp3');
    final speech = _song('speech', '/podcasts/work/briefing.mp3');
    final musicB = _song('music-b', '/music/b.mp3');
    final plan = QueuePlan(
      intentId: QueueIntent.focus.id,
      songs: [musicB, musicA],
      status: QueuePlanStatus.ready,
      analysisCoverage: 1,
      analyzedTrackCount: 2,
      eligibleTrackCount: 2,
    );
    final result = await ModeAwareQueuePlanner(
      planner: _FixedPlanner(plan),
    ).arrange(modes: modes, tracks: [musicA, speech, musicB]);
    expect(result.songs.map((song) => song.id), ['music-b', 'speech', 'music-a']);
    modes.dispose();
  });

  test('insufficient DJ analysis preserves the original mixed-media order', () async {
    final modes = ModeProvider();
    await modes.ready;
    await modes.setMode(ResonateMode.sleep);
    final tracks = [_song('music-a', '/music/a.mp3'), _song('book', '/audiobooks/book/chapter-1.mp3'), _song('music-b', '/music/b.mp3')];
    final plan = QueuePlan(intentId: QueueIntent.sleep.id, songs: const [], status: QueuePlanStatus.insufficientAnalysis, analysisCoverage: 0, analyzedTrackCount: 0, eligibleTrackCount: 0, reason: 'DJ analysis is incomplete.');
    final result = await ModeAwareQueuePlanner(planner: _FixedPlanner(plan)).arrange(modes: modes, tracks: tracks);
    expect(result.songs.map((song) => song.id), tracks.map((song) => song.id));
    expect(result.isUsable, isTrue);
    expect(result.message, contains('original mixed-media order was preserved'));
    modes.dispose();
  });

  test('Sleep mode with only spoken content still preserves order against shuffle', () async {
    final modes = ModeProvider();
    await modes.ready;
    await modes.setMode(ResonateMode.sleep);
    final book = _song('book', '/audiobooks/book/chapter-1.mp3');
    final podcast = _song('podcast', '/podcasts/show/episode-1.mp3');
    final result = await ModeAwareQueuePlanner(
      planner: _FixedPlanner(QueuePlan(
        intentId: QueueIntent.sleep.id,
        songs: const [],
        status: QueuePlanStatus.insufficientAnalysis,
        analysisCoverage: 0,
        analyzedTrackCount: 0,
        eligibleTrackCount: 0,
      )),
    ).arrange(modes: modes, tracks: [book, podcast]);
    expect(result.songs.map((song) => song.id), ['book', 'podcast']);
    expect(result.usedDjPlanner, isTrue);
    modes.dispose();
  });

  test('Podcast mode keeps strict spoken sequence and bypasses DJ music ordering', () async {
    final modes = ModeProvider();
    await modes.ready;
    await modes.setMode(ResonateMode.podcast);
    final tracks = [_song('episode-1', '/podcasts/show/episode-1.mp3'), _song('episode-2', '/podcasts/show/episode-2.mp3')];
    final result = await ModeAwareQueuePlanner(planner: _FixedPlanner(QueuePlan(intentId: 'unused', songs: const [], status: QueuePlanStatus.insufficientAnalysis, analysisCoverage: 0, analyzedTrackCount: 0, eligibleTrackCount: 0))).arrange(modes: modes, tracks: tracks);
    expect(result.songs.map((song) => song.id), ['episode-1', 'episode-2']);
    expect(result.usedDjPlanner, isFalse);
    modes.dispose();
  });
}