import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level product experience. This is intentionally separate from
/// ResonateMode (listening context) and DjModeProvider (DJ feature policy).
enum ResonateExperience {
  player,
  resonatixDj;

  String get storageValue => switch (this) {
        ResonateExperience.player => 'player',
        ResonateExperience.resonatixDj => 'resonatix_dj',
      };

  static ResonateExperience? fromStorage(String? value) => switch (value) {
        'player' => ResonateExperience.player,
        'resonatix_dj' => ResonateExperience.resonatixDj,
        _ => null,
      };
}

/// Persists the user's top-level experience choice.
///
/// This first milestone only supports first-run selection. Changing an
/// already-selected experience is deliberately reserved for the safe
/// switching coordinator, which must stop and normalize playback first.
class ExperienceProvider extends ChangeNotifier {
  static const String _storageKey = 'resonate_selected_experience';

  ResonateExperience? _selected;
  bool _isReady = false;
  Object? _loadError;

  ResonateExperience? get selected => _selected;
  bool get isReady => _isReady;
  bool get needsInitialSelection => _isReady && _selected == null;
  Object? get loadError => _loadError;

  ExperienceProvider() {
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _selected = ResonateExperience.fromStorage(prefs.getString(_storageKey));
    } catch (error) {
      _loadError = error;
      // Fail closed to the chooser; do not silently assume a prior selection.
    } finally {
      _isReady = true;
      notifyListeners();
    }
  }

  Future<void> selectInitialExperience(ResonateExperience experience) async {
    if (!_isReady) {
      throw StateError('Experience preferences have not finished loading.');
    }
    if (_selected != null) {
      throw StateError(
        'An experience is already selected. Use the safe switching flow.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, experience.storageValue);
    _selected = experience;
    _loadError = null;
    notifyListeners();
  }
}
