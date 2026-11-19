import '../dj_engine/core/dj_types.dart';

/// Snaps an operator cue only when a trusted structural marker is nearby.
/// A distant marker never pulls the cue away from the operator's chosen time.
class DjCueSnapper {
  const DjCueSnapper._();

  static int snap(DjTrackProfile profile, int requestedMs, int durationMs,
      {required bool outgoing}) {
    final duration = durationMs > 0 ? durationMs : profile.durationMs ?? 0;
    if (duration <= 0) return requestedMs < 0 ? 0 : requestedMs;
    final requested = requestedMs.clamp(0, duration);
    final grid = profile.beatGrid;
    final markers = <int>{};
    final confidentGrid = grid.usable && grid.confidence >= 0.55;
    if (confidentGrid) {
      markers.addAll(grid.beatMs.where((v) => v >= 0 && v <= duration));
      if (grid.downbeatConfidence >= 0.6) {
        markers.addAll(grid.downbeatMs.where((v) => v >= 0 && v <= duration));
      }
      if (grid.phraseConfidence >= 0.65 && grid.beatsPerPhrase > 0) {
        final beats = grid.beatMs;
        for (var i = 0; i < beats.length; i += grid.beatsPerPhrase) {
          if (beats[i] >= 0 && beats[i] <= duration) markers.add(beats[i]);
        }
      }
    }
    for (final section in profile.sections) {
      if (section.confidence < 0.7) continue;
      if (section.type == DjSectionType.intro || section.type == DjSectionType.outro ||
          section.type == DjSectionType.breakdown || section.type == DjSectionType.drop ||
          section.type == DjSectionType.build || section.type == DjSectionType.chorus) {
        final boundary = outgoing ? section.endMs : section.startMs;
        if (boundary >= 0 && boundary <= duration) markers.add(boundary);
      }
    }
    final safe = outgoing ? profile.transitions.safeMixOuts : profile.transitions.safeMixIns;
    markers.addAll(safe.where((p) => p.confidence >= 0.65 && p.timeMs >= 0 && p.timeMs <= duration).map((p) => p.timeMs));
    if (markers.isEmpty) return requested;
    final beatTolerance = confidentGrid && grid.bpm != null
        ? ((60000 / grid.bpm!) * 0.22).round().clamp(70, 180)
        : 120;
    var nearest = requested;
    var distance = beatTolerance + 1;
    for (final marker in markers) {
      final delta = (marker - requested).abs();
      if (delta < distance || (delta == distance && marker < nearest)) {
        nearest = marker;
        distance = delta;
      }
    }
    return distance <= beatTolerance ? nearest : requested;
  }
}
