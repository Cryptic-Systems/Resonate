/// Tracks ownership of asynchronous Intelligence mix requests.
/// A result is usable only while it is the newest request, playback still
/// has the source track that initiated it, and Intelligence remains enabled.
class IntelligenceMixRequestGuard {
  int _generation = 0;

  int begin() => ++_generation;

  bool isLatest(int requestGeneration) => requestGeneration == _generation;

  int get currentGeneration => _generation;

  void invalidate() => _generation++;

  bool owns({
    required int requestGeneration,
    required String? sourceSongId,
    required String? currentSongId,
    required bool intelligenceEnabled,
  }) =>
      requestGeneration == _generation &&
      sourceSongId == currentSongId &&
      intelligenceEnabled;
}
