import '../models/dsp_settings.dart';

/// A complete, portable Resonate sound profile.
///
/// Unlike the legacy EqualizerPreset (which stores only a graphic-EQ curve),
/// this snapshot captures every user-facing native DSP setting. The nested
/// DspSettings document retains its own schema version and migration rules.
class ResonateSoundProfile {
  static const int schemaVersion = 1;
  static const String format = 'resonate-sound-profile';

  final String id;
  final String name;
  final String description;
  final String category;
  final bool isBuiltIn;
  final DspSettings settings;

  const ResonateSoundProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.category = 'Custom',
    this.isBuiltIn = false,
    required this.settings,
  });

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': schemaVersion,
        'id': id,
        'name': name,
        'description': description,
        'category': category,
        'isBuiltIn': isBuiltIn,
        'settings': settings.toJson(),
      };

  factory ResonateSoundProfile.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format || json['version'] != schemaVersion) {
      throw const FormatException('Unsupported Resonate sound profile format.');
    }
    String requiredText(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Sound profile $key must be a non-empty string.');
      }
      return value.trim();
    }

    final id = requiredText('id');
    final name = requiredText('name');
    if (id.length > 128 || name.length > 64) {
      throw const FormatException('Sound profile id or name exceeds its length limit.');
    }
    final rawDescription = json['description'];
    if (rawDescription != null && rawDescription is! String) {
      throw const FormatException('Invalid sound profile description.');
    }
    final description = rawDescription as String? ?? '';
    if (description.length > 280) {
      throw const FormatException('Sound profile descriptions must be 280 characters or fewer.');
    }
    final rawSettings = json['settings'];
    if (rawSettings is! Map) {
      throw const FormatException('Sound profile is missing its DSP settings.');
    }
    final settingsJson = Map<String, dynamic>.from(rawSettings);
    final rawEq = settingsJson['eqBandGainsDb'];
    if (rawEq != null &&
        (rawEq is! List ||
            rawEq.length > 31 ||
            rawEq.any((value) => value is! num || !value.toDouble().isFinite))) {
      throw const FormatException('Sound profile graphic EQ data is malformed.');
    }
    final rawParametric = settingsJson['parametricEqBands'];
    if (rawParametric != null) {
      if (rawParametric is! List || rawParametric.length > 31) {
        throw const FormatException('Sound profile parametric EQ data exceeds 31 bands.');
      }
      for (final band in rawParametric) {
        if (band is! Map) {
          throw const FormatException('Sound profile contains a malformed parametric EQ band.');
        }
        for (final key in ['frequencyHz', 'gainDb', 'q']) {
          final value = band[key];
          if (value is! num || !value.toDouble().isFinite) {
            throw FormatException('Parametric EQ $key must be a finite number.');
          }
        }
        final type = band['type'];
        if (type != null && (type is! num || type.toInt() < 0 || type.toInt() > 4)) {
          throw const FormatException('Parametric EQ filter type is invalid.');
        }
      }
    }
    final rawBuiltIn = json['isBuiltIn'];
    if (rawBuiltIn != null && rawBuiltIn is! bool) {
      throw const FormatException('Invalid sound profile built-in flag.');
    }
    return ResonateSoundProfile(
      id: id,
      name: name,
      description: description,
      category: json['category'] is String && (json['category'] as String).trim().isNotEmpty
          ? (json['category'] as String).trim()
          : 'Custom',
      isBuiltIn: rawBuiltIn == true,
      settings: DspSettings.fromJson(settingsJson),
    );
  }
}
