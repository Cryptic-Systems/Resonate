import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists four manual hot-cue slots per track identity for the DJ Console.
/// Reads the original single-cue format and migrates it into slot 1.
class DjCuePointStore {
  static const String _storageKey = 'resonate_dj_hot_cues_v2';
  static const String _legacyStorageKey = 'resonate_dj_cue_points_v1';
  static const int slotCount = 4;

  Future<Map<String, List<Duration?>>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final result = <String, List<Duration?>>{};
          for (final entry in decoded.entries) {
            final trackId = entry.key;
            final values = entry.value;
            if (trackId is! String || trackId.trim().isEmpty || values is! List) continue;
            final slots = List<Duration?>.filled(slotCount, null);
            for (var index = 0; index < slotCount && index < values.length; index++) {
              final value = values[index];
              if (value is num && value.isFinite && value >= 0) {
                slots[index] = Duration(milliseconds: value.toInt());
              }
            }
            result[trackId] = slots;
          }
          return result;
        }
      } catch (_) { /* Migrate legacy data below when possible. */ }
    }
    final legacyRaw = preferences.getString(_legacyStorageKey);
    if (legacyRaw == null || legacyRaw.isEmpty) return <String, List<Duration?>>{};
    try {
      final decoded = jsonDecode(legacyRaw);
      if (decoded is! Map) return <String, List<Duration?>>{};
      final migrated = <String, List<Duration?>>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (entry.key is String && (entry.key as String).trim().isNotEmpty &&
            value is num && value.isFinite && value >= 0) {
          migrated[entry.key as String] = <Duration?>[
            Duration(milliseconds: value.toInt()), null, null, null,
          ];
        }
      }
      await saveAll(migrated);
      return migrated;
    } catch (_) {
      return <String, List<Duration?>>{};
    }
  }

  Future<void> saveAll(Map<String, List<Duration?>> hotCues) async {
    final normalized = <String, List<int?>>{};
    for (final entry in hotCues.entries) {
      final trackId = entry.key.trim();
      if (trackId.isEmpty) continue;
      final slots = List<int?>.filled(slotCount, null);
      for (var index = 0; index < slotCount && index < entry.value.length; index++) {
        final position = entry.value[index];
        if (position != null && !position.isNegative) slots[index] = position.inMilliseconds;
      }
      if (slots.any((value) => value != null)) normalized[trackId] = slots;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_storageKey, jsonEncode(normalized));
  }
}