import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:resonate/modes/providers/mode_provider.dart';
import 'package:resonate/providers/music_provider.dart';
import 'package:resonate/screens/dj_console_screen.dart';
import 'package:resonate/screens/settings_screen.dart';
import 'package:resonate/screens/voice_feedback_settings_screen.dart';
import 'package:resonate/services/companion_command_executor.dart';
import 'package:resonate/services/voice_cue_service.dart';
import 'package:resonate/services/workspace_lifecycle_coordinator.dart';
import 'package:resonate/providers/audio_visualization_provider.dart';
import 'package:resonate/providers/playback_features_provider.dart';

void _typeCheck<T>() {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('voice cue manifest is bundled and contains the ready test cue', () async {
    final manifest = await rootBundle.loadString(
      'assets/audio/resonate_voice/voice_manifest.json',
    );
    expect(
      manifest,
      contains('system_consent_status.voice_system_ready'),
    );
  });

  test('voice cue service can be resolved before Flutter audio binding', () {
    expect(VoiceCueService.instance.isSpeaking, isFalse);
  });

  test('voice cue call sites and settings compile together', () {
    _typeCheck<VoiceCueService>();
    _typeCheck<WorkspaceLifecycleCoordinator>();
    _typeCheck<AudioVisualizationProvider>();
    _typeCheck<PlaybackFeaturesProvider>();
    _typeCheck<ModeProvider>();
    _typeCheck<MusicProvider>();
    _typeCheck<DjConsoleScreen>();
    _typeCheck<SettingsScreen>();
    _typeCheck<VoiceFeedbackSettingsScreen>();
    _typeCheck<CompanionCommandExecutor>();
    expect(true, isTrue);
  });
}
