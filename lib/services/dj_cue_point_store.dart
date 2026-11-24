import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists one manual cue point per track identity for the DJ Console.
class DjCuePointStore {
  static const String _storageKey = 'resonate_dj_cue_points_v1';

  Future<Map<String, Duration>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) return <String, Duration>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Duration>{};
      final result = <String, Duration>{};
      for (final entry in decoded.entries) {
        final trackId = entry.key;
        final milliseconds = entry.value;
        if (trackId is! String ||
            trackId.trim().isEmpty ||
            milliseconds is! num ||
            !milliseconds.isFinite ||
            milliseconds < 0) {
          continue;
        }
        result[trackId] = Duration(milliseconds: milliseconds.toInt());
      }
      return result;
    } catch (_) {
      return <String, Duration>{};
    }
  }

  Future<void> saveAll(Map<String, Duration> cuePoints) async {
    final normalized = <String, int>{};
    for (final entry in cuePoints.entries) {
      final trackId = entry.key.trim();
      final position = entry.value;
      if (trackId.isEmpty || position.isNegative) continue;
      normalized[trackId] = position.inMilliseconds;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_storageKey, jsonEncode(normalized));
  }
}
