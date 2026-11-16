import 'dart:math' as math;

import '../dj_engine/core/dj_policy.dart';
import '../dj_engine/core/dj_types.dart';
import '../dj_engine/analysis/dj_profile_builder.dart';
import '../dj_engine/dj_engine.dart';
import '../models/dj_analysis.dart';
import '../models/song.dart';
import 'dj_analysis_service.dart';
import 'dj_auto_select_service.dart';

/// The origin of a reviewable DJ suggestion. It does not imply playback.
enum DjSessionScope { library, playlist }

class DjSessionTransition {
  const DjSessionTransition({
    required this.outgoingSongId,
    required this.incomingSongId,
    required this.plan,
  });

  final String outgoingSongId;
  final String incomingSongId;
  final DjExecutionPlan plan;
}

/// A reviewable, reorderable mix proposal. It is intentionally detached from
/// MusicProvider and never mutates the active playback queue.
class DjSuggestionMix {
  DjSuggestionMix({
    required this.scope,
    required this.scopeId,
    required this.sourceSongs,
    required this.orderedSongs,
    required this.profiles,
    required this.transitions,
    required this.analysisCoverage,
    required this.usedDjArrangement,
    required this.revision,
    this.fallbackReason,
  })  : sourceSongs = List.unmodifiable(sourceSongs),
        orderedSongs = List.unmodifiable(orderedSongs),
        profiles = Map.unmodifiable(profiles),
        transitions = List.unmodifiable(transitions);

  final DjSessionScope scope;
  final String? scopeId;
  final List<Song> sourceSongs;
  final List<Song> orderedSongs;
  final Map<String, DjTrackProfile> profiles;
  final List<DjSessionTransition> transitions;
  final double analysisCoverage;
  final bool usedDjArrangement;
  final int revision;
  final String? fallbackReason;

  bool get hasTransitions => transitions.isNotEmpty;
  int get fallbackTransitionCount =>
      transitions.where((transition) => transition.plan.fallback).length;
}

class DjApprovedMix {
  DjApprovedMix({
    required this.songs,
    required this.sourceScope,
    required this.revision,
  }) : songs = List.unmodifiable(songs);

  /// The approved sequence for a caller to hand off explicitly to playback.
  /// Creating this value still does not alter the active queue.
  final List<Song> songs;
  final DjSessionScope sourceScope;
  final int revision;
}

/// Coordinates Auto-Select and adjacent-track transition planning into a
/// reviewable Suggestion Mix. No player, queue, or Media3 dependency exists
/// in this layer.
class DjSessionCoordinator {
  DjSessionCoordinator({
    DjAnalysisService? analysis,
    DjAutoSelectService? autoSelect,
    DjEngine engine = const DjEngine(),
    DjProfileBuilder profileBuilder = const DjProfileBuilder(),
  })  : _analysis = analysis ?? DjAnalysisService(),
        _engine = engine,
        _profileBuilder = profileBuilder,
        _autoSelect = autoSelect ??
            DjAutoSelectService(analysis: analysis ?? DjAnalysisService());

  final DjAnalysisService _analysis;
  final DjAutoSelectService _autoSelect;
  final DjEngine _engine;
  final DjProfileBuilder _profileBuilder;

  Future<DjSuggestionMix> create({
    required List<Song> songs,
    required DjSessionScope scope,
    String? scopeId,
    Map<String, DjListeningSignal> listeningSignals = const {},
    math.Random? random,
    DjPolicy policy = DjPolicy.balanced,
  }) async {
    _validateSource(songs, scope, scopeId);
    final source = List<Song>.unmodifiable(songs);
    final arrangement = await _autoSelect.arrange(
      source,
      random: random,
      listeningSignals: listeningSignals,
    );
    final profiles = await _loadProfiles(source);
    return _buildMix(
      scope: scope,
      scopeId: scopeId,
      sourceSongs: source,
      orderedSongs: arrangement.songs,
      profiles: profiles,
      analysisCoverage: arrangement.analysisCoverage,
      usedDjArrangement: arrangement.usedDjArrangement,
      fallbackReason: arrangement.reason,
      revision: 1,
      policy: policy,
    );
  }

  /// Reorders only the proposal. The supplied IDs must be an exact
  /// permutation of the source scope; duplicates and omissions are rejected.
  DjSuggestionMix reorder({
    required DjSuggestionMix mix,
    required List<String> orderedSongIds,
    DjPolicy policy = DjPolicy.balanced,
  }) {
    final expected = _counts(mix.sourceSongs.map((song) => song.id));
    final supplied = _counts(orderedSongIds);
    if (!_sameCounts(expected, supplied)) {
      throw ArgumentError.value(
        orderedSongIds,
        'orderedSongIds',
        'Must contain every source track exactly once.',
      );
    }
    final byId = {for (final song in mix.sourceSongs) song.id: song};
    final reordered = orderedSongIds.map((id) => byId[id]!).toList();
    return _buildMix(
      scope: mix.scope,
      scopeId: mix.scopeId,
      sourceSongs: mix.sourceSongs,
      orderedSongs: reordered,
      profiles: mix.profiles,
      analysisCoverage: mix.analysisCoverage,
      usedDjArrangement: mix.usedDjArrangement,
      fallbackReason: mix.fallbackReason,
      revision: mix.revision + 1,
      policy: policy,
    );
  }

  /// Explicit approval returns the reviewed sequence, but does not start
  /// playback or replace MusicProvider's current queue.
  DjApprovedMix approve(DjSuggestionMix mix) {
    final source = _counts(mix.sourceSongs.map((song) => song.id));
    final ordered = _counts(mix.orderedSongs.map((song) => song.id));
    if (!_sameCounts(source, ordered)) {
      throw StateError('Suggestion Mix no longer matches its source scope.');
    }
    return DjApprovedMix(
      songs: mix.orderedSongs,
      sourceScope: mix.scope,
      revision: mix.revision,
    );
  }

  Future<Map<String, DjTrackProfile>> _loadProfiles(
    List<Song> songs,
  ) async {
    final profiles = <String, DjTrackProfile>{};
    for (final song in songs) {
      DjTrackProfile? profile;
      try {
        profile = await _analysis.getProfile(song.id);
      } catch (_) {
        profile = null;
      }
      if (profile == null || profile.songId != song.id) {
        DjAnalysis? row;
        try {
          row = await _analysis.getAnalysis(song.id);
        } catch (_) {
          row = null;
        }
        profile = row != null && row.songId == song.id
            ? _profileBuilder.fromAnalysis(row)
            : DjTrackProfile(
                songId: song.id,
                durationMs: song.duration.inMilliseconds > 0
                    ? song.duration.inMilliseconds
                    : null,
              );
      }
      profiles[song.id] = profile;
    }
    return Map.unmodifiable(profiles);
  }

  DjSuggestionMix _buildMix({
    required DjSessionScope scope,
    required String? scopeId,
    required List<Song> sourceSongs,
    required List<Song> orderedSongs,
    required Map<String, DjTrackProfile> profiles,
    required double analysisCoverage,
    required bool usedDjArrangement,
    required String? fallbackReason,
    required int revision,
    required DjPolicy policy,
  }) {
    final transitions = <DjSessionTransition>[];
    for (var i = 0; i + 1 < orderedSongs.length; i++) {
      final outgoing = profiles[orderedSongs[i].id]!;
      final incoming = profiles[orderedSongs[i + 1].id]!;
      final plan = _engine.planTransition(
        outgoing: outgoing,
        incoming: incoming,
        // The transition brain selects a suitable outgoing cue from the
        // complete profile. Starting at zero avoids inventing a live position.
        outgoingPositionMs: 0,
        policy: policy,
      );
      transitions.add(DjSessionTransition(
        outgoingSongId: outgoing.songId,
        incomingSongId: incoming.songId,
        plan: plan,
      ));
    }
    return DjSuggestionMix(
      scope: scope,
      scopeId: scopeId,
      sourceSongs: sourceSongs,
      orderedSongs: orderedSongs,
      profiles: profiles,
      transitions: transitions,
      analysisCoverage: analysisCoverage.clamp(0.0, 1.0).toDouble(),
      usedDjArrangement: usedDjArrangement,
      fallbackReason: fallbackReason,
      revision: revision,
    );
  }

  static void _validateSource(
    List<Song> songs,
    DjSessionScope scope,
    String? scopeId,
  ) {
    final ids = songs.map((song) => song.id).toList();
    if (ids.any((id) => id.trim().isEmpty) || ids.toSet().length != ids.length) {
      throw ArgumentError('DJ source tracks must have unique, non-empty IDs.');
    }
    if (scope == DjSessionScope.playlist &&
        (scopeId == null || scopeId.trim().isEmpty)) {
      throw ArgumentError('A playlist scope requires its playlist ID.');
    }
  }

  static Map<String, int> _counts(Iterable<String> ids) {
    final result = <String, int>{};
    for (final id in ids) {
      result.update(id, (count) => count + 1, ifAbsent: () => 1);
    }
    return result;
  }

  static bool _sameCounts(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    return a.entries.every((entry) => b[entry.key] == entry.value);
  }
}
