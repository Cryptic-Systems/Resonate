import 'package:flutter_test/flutter_test.dart';

import '../../modes/providers/mode_provider.dart';
import '../../providers/music_provider.dart';
import '../../screens/dj_console_screen.dart';
import '../../screens/settings_screen.dart';
import '../../screens/voice_feedback_settings_screen.dart';
import '../../services/companion_command_executor.dart';
import '../../services/voice_cue_service.dart';

void main() {
  test('voice cue call sites and settings compile together', () {
    expect(VoiceCueService.instance, isNotNull);
    expect(ModeProvider, isNotNull);
    expect(MusicProvider, isNotNull);
    expect(DjConsoleScreen, isNotNull);
    expect(SettingsScreen, isNotNull);
    expect(VoiceFeedbackSettingsScreen, isNotNull);
    expect(CompanionCommandExecutor, isNotNull);
  });
}
