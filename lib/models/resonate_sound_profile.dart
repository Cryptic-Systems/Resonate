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

    final rawSettings = json['settings'];
    if (rawSettings is! Map) {
      throw const FormatException('Sound profile is missing its DSP settings.');
    }
    final rawBuiltIn = json['isBuiltIn'];
    if (rawBuiltIn != null && rawBuiltIn is! bool) {
      throw const FormatException('Invalid sound profile built-in flag.');
    }
    return ResonateSoundProfile(
      id: requiredText('id'),
      name: requiredText('name'),
      description: json['description'] is String ? json['description'] as String : '',
      category: json['category'] is String && (json['category'] as String).trim().isNotEmpty
          ? (json['category'] as String).trim()
          : 'Custom',
      isBuiltIn: rawBuiltIn == true,
      settings: DspSettings.fromJson(Map<String, dynamic>.from(rawSettings)),
    );
  }
}
