import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import '../ui/resonate_glass.dart';
import 'dsp_settings_screen.dart';

/// Playback automations only. Signal-processing controls live in DSP Engine.
class AudioAutomationSettingsScreen extends StatelessWidget {
  const AudioAutomationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => ResonateGlassScaffold(
        title: const Text('Playback automation'),
        body: Consumer<MusicProvider>(
          builder: (context, music, _) => ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              ResonateGlassCard(
                blurEnabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Audio focus', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Automatic response'),
                      subtitle: Text(
                        music.audioFocusAutomationEnabled
                            ? 'Apply the selected response when other apps request audio focus.'
                            : 'Manual mode; no automatic ducking or resume.',
                      ),
                      value: music.audioFocusAutomationEnabled,
                      onChanged: (value) => music.setAudioFocusAutomation(automatic: value),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.volume_up_rounded),
                      title: const Text('Pause/resume fade'),
                      subtitle: Text(
                        music.pauseResumeFadeEnabled
                            ? 'Brief fade on pause and resume.'
                            : 'Pause and resume immediately.',
                      ),
                      value: music.pauseResumeFadeEnabled,
                      onChanged: music.setPauseResumeFadeEnabled,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ResonateGlassCard(
                blurEnabled: false,
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                      child: Text('Focus response', style: Theme.of(context).textTheme.titleMedium),
                    ),
                    _level(context, music, 1, 'Level 1 · Gentle',
                        'Stronger notification ducking; manual resume after full focus loss.'),
                    _level(context, music, 2, 'Level 2 · Conservative',
                        'Moderate ducking; no automatic resume after full focus loss.'),
                    _level(context, music, 3, 'Level 3 · Short auto-resume',
                        'Auto-resume only after interruptions up to 30 seconds.'),
                    _level(context, music, 4, 'Level 4 · Adaptive',
                        'Auto-resume up to 3 minutes; longer interruptions need manual resume.'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        'Level 2 is the safest choice when another music app may take audio focus. Android does not reliably identify whether every focus loss came from a call or another player, so call-only auto-resume cannot be guaranteed.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ResonateGlassCard(
                blurEnabled: false,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.graphic_eq_rounded),
                  title: const Text('DSP Engine settings'),
                  subtitle: const Text('DVC, limiter, EQ, preamp, speaker protection and output processing'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DspSettingsScreen()),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _level(BuildContext context, MusicProvider music, int value,
          String title, String subtitle) =>
      RadioListTile<int>(
        value: value,
        groupValue: music.audioFocusLevel,
        onChanged: (next) {
          if (next != null) music.setAudioFocusAutomation(level: next);
        },
        title: Text(title),
        subtitle: Text(subtitle),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      );
}
