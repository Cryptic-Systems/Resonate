import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../dj_engine/core/dj_types.dart';

/// User-authored transition settings for one directed track pair.
/// Pair cues never mutate either track's global DJ analysis profile.
class DjTransitionPreset {
  const DjTransitionPreset({
    required this.outgoingSongId,
    required this.incomingSongId,
    required this.outgoingCueMs,
    required this.incomingCueMs,
    required this.durationMs,
    this.preferredKind,
    this.updatedAt,
  });
  final String outgoingSongId;
  final String incomingSongId;
  final int outgoingCueMs;
  final int incomingCueMs;
  final int durationMs;
  final DjTransitionKind? preferredKind;
  final DateTime? updatedAt;

  bool isUsableFor({
    required int outgoingPositionMs,
    int? outgoingDurationMs,
    int? incomingDurationMs,
  }) {
    if (outgoingSongId.isEmpty || incomingSongId.isEmpty ||
        outgoingCueMs < outgoingPositionMs ||
        incomingCueMs < 0 || durationMs < 2000 || durationMs > 15000) return false;
    if (outgoingDurationMs != null &&
        (outgoingCueMs >= outgoingDurationMs ||
         outgoingDurationMs - outgoingCueMs < 2000)) return false;
    if (incomingDurationMs != null &&
        (incomingCueMs >= incomingDurationMs ||
         incomingDurationMs - incomingCueMs < 2000)) return false;
    return true;
  }

  DjTrackProfile applyOutgoing(DjTrackProfile profile) => _withMarkers(
    profile,
    DjTransitionMarkers(
      bestIntroMs: profile.transitions.bestIntroMs,
      bestOutroMs: outgoingCueMs,
      safeMixIns: profile.transitions.safeMixIns,
      safeMixOuts: [DjTimePoint(outgoingCueMs, confidence: 1)],
      riskyPoints: profile.transitions.riskyPoints,
    ),
  );

  DjTrackProfile applyIncoming(DjTrackProfile profile) => _withMarkers(
    profile,
    DjTransitionMarkers(
      bestIntroMs: incomingCueMs,
      bestOutroMs: profile.transitions.bestOutroMs,
      safeMixIns: [DjTimePoint(incomingCueMs, confidence: 1)],
      safeMixOuts: profile.transitions.safeMixOuts,
      riskyPoints: profile.transitions.riskyPoints,
    ),
  );

  Map<String, dynamic> toJson() => {
    'outgoingSongId': outgoingSongId,
    'incomingSongId': incomingSongId,
    'outgoingCueMs': outgoingCueMs,
    'incomingCueMs': incomingCueMs,
    'durationMs': durationMs,
    if (preferredKind != null) 'preferredKind': preferredKind!.name,
    'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
  };

  static DjTransitionPreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final from = map['outgoingSongId'];
    final to = map['incomingSongId'];
    final out = map['outgoingCueMs'];
    final incoming = map['incomingCueMs'];
    final duration = map['durationMs'];
    if (from is! String || from.isEmpty || to is! String || to.isEmpty ||
        out is! int || incoming is! int || duration is! int ||
        out < 0 || incoming < 0 || duration < 2000 || duration > 15000) return null;
    DjTransitionKind? kind;
    final kindName = map['preferredKind']?.toString();
    for (final value in DjTransitionKind.values) {
      if (value.name == kindName) kind = value;
    }
    return DjTransitionPreset(
      outgoingSongId: from,
      incomingSongId: to,
      outgoingCueMs: out,
      incomingCueMs: incoming,
      durationMs: duration,
      preferredKind: kind,
      updatedAt: DateTime.tryParse(map['updatedAt']?.toString() ?? ''),
    );
  }
}

DjTrackProfile _withMarkers(DjTrackProfile profile, DjTransitionMarkers transitions) =>
    DjTrackProfile(
      songId: profile.songId,
      durationMs: profile.durationMs,
      fingerprint: profile.fingerprint,
      beatGrid: profile.beatGrid,
      keyRoot: profile.keyRoot,
      keyMode: profile.keyMode,
      keyConfidence: profile.keyConfidence,
      harmonicChanges: profile.harmonicChanges,
      sections: profile.sections,
      energyCurve: profile.energyCurve,
      spectrum: profile.spectrum,
      transitions: transitions,
      silenceRegions: profile.silenceRegions,
      analysisConfidence: profile.analysisConfidence,
      analysisVersion: profile.analysisVersion,
    );

/// Bounded, local-only store for directed track-pair presets.
class DjTransitionPresetStore {
  static const _key = 'dj_transition_pair_presets_v1';
  static const _maxPairs = 400;
  static Future<void> _writeTail = Future<void>.value();
  static String _pairKey(String from, String to) => jsonEncode([from, to]);

  static Future<DjTransitionPreset?> get(String from, String to) async {
    if (from.isEmpty || to.isEmpty) return null;
    try {
      await _writeTail;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DjTransitionPreset.fromJson(decoded[_pairKey(from, to)]);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(DjTransitionPreset preset) {
    if (preset.outgoingSongId.isEmpty || preset.incomingSongId.isEmpty ||
        preset.outgoingCueMs < 0 || preset.incomingCueMs < 0 ||
        preset.durationMs < 2000 || preset.durationMs > 15000) {
      return Future<void>.error(ArgumentError('Invalid DJ transition preset'));
    }
    final write = _writeTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final decoded = _decode(prefs.getString(_key));
      decoded[_pairKey(preset.outgoingSongId, preset.incomingSongId)] = preset.toJson();
      if (decoded.length > _maxPairs) {
        final ordered = decoded.entries.toList()..sort((a, b) {
          final ta = DateTime.tryParse((a.value['updatedAt'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final tb = DateTime.tryParse((b.value['updatedAt'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return ta.compareTo(tb);
        });
        for (final entry in ordered.take(decoded.length - _maxPairs)) {
          decoded.remove(entry.key);
        }
      }
      await prefs.setString(_key, jsonEncode(decoded));
    });
    _writeTail = write.catchError((Object _) {});
    return write;
  }

  static Future<void> delete(String from, String to) {
    final write = _writeTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final decoded = _decode(prefs.getString(_key));
      decoded.remove(_pairKey(from, to));
      await prefs.setString(_key, jsonEncode(decoded));
    });
    _writeTail = write.catchError((Object _) {});
    return write;
  }

  static Map<String, Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return {};
      final result = <String, Map<String, dynamic>>{};
      value.forEach((key, row) {
        if (row is Map && DjTransitionPreset.fromJson(row) != null) {
          result[key.toString()] = Map<String, dynamic>.from(row);
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }
}
