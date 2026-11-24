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
/// Runtime changes are exposed separately from first-run selection so the
/// owning experience shell can normalize playback before switching products.
class ExperienceProvider extends ChangeNotifier {
  static const String _storageKey = 'resonate_selected_experience';

  ResonateExperience? _selected;
  bool _isReady = false;
  Object? _loadError;
  late final Future<void> ready;

  ResonateExperience? get selected => _selected;
  bool get isReady => _isReady;
  bool get needsInitialSelection => _isReady && _selected == null;
  Object? get loadError => _loadError;

  ExperienceProvider() {
    ready = _load();
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

  /// Switches the active product experience after the caller has safely handed\n  /// playback ownership back to the destination shell.\n  Future<void> switchExperience(ResonateExperience experience) async {\n    if (!_isReady) {\n      throw StateError('Experience preferences have not finished loading.');\n    }\n    if (_selected == experience) return;\n    final prefs = await SharedPreferences.getInstance();\n    await prefs.setString(_storageKey, experience.storageValue);\n    _selected = experience;\n    _loadError = null;\n    notifyListeners();\n  }\n\n  Future<void> selectInitialExperience(ResonateExperience experience) async {
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
