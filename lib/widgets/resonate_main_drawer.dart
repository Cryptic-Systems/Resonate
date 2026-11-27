import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../experience/experience_provider.dart';
import '../modes/integration/resonate_mode_ports.dart';
import '../modes/models/resonate_mode.dart';
import '../modes/providers/mode_provider.dart';
import '../modes/screens/modes_screen.dart';
import '../screens/audio_leveling_settings_screen.dart';
import '../screens/crossfade_screen.dart';
import '../screens/discovery_screen.dart';
import '../screens/dj_mode_settings_screen.dart';
import '../screens/dj_workspace_screen.dart';
import '../screens/equalizer_screen.dart';
import '../screens/listening_history_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/queue_screen.dart';
import '../screens/settings_screen.dart';

/// One navigation inventory for both Resonate Player and For You.
/// Keep these destinations in sync; only the owning screen's open callback
/// differs between the two entry points.
class ResonateMainDrawer extends StatelessWidget {
  const ResonateMainDrawer({super.key, required this.onOpen});
  final void Function(Widget screen) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 10),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('RESONATE', style: theme.textTheme.labelLarge),
            ),
            ListTile(
              leading: const Icon(Icons.explore_rounded),
              title: const Text('Discovery'),
              onTap: () => onOpen(const DiscoveryScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq_rounded),
              title: const Text('Mix Monitor · Engine A/B'),
              subtitle: const Text('Automatic playback, standby preparation and transition health'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => onOpen(const PlayerMixMonitorScreen()),
            ),
            Consumer<ModeProvider>(
              builder: (_, modes, __) => ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('Listening modes'),
                subtitle: Text('Current: ${modes.mode.label}'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onOpen(ModesScreen(
                  folderPicker: const ResonateModeFolderPickerPort(),
                )),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Listening history'),
              onTap: () => onOpen(const ListeningHistoryScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notifications'),
              subtitle: const Text('Driving alerts and Resonate updates'),
              onTap: () => onOpen(const NotificationCenterScreen()),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Text('PLAYER TOOLS', style: theme.textTheme.labelLarge),
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Queue'),
              onTap: () => onOpen(const QueueScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.equalizer_rounded),
              title: const Text('Equalizer'),
              onTap: () => onOpen(const EqualizerScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.compare_arrows_rounded),
              title: const Text('Crossfade'),
              onTap: () => onOpen(const CrossfadeScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq_rounded),
              title: const Text('Audio leveling'),
              onTap: () => onOpen(const AudioLevelingSettingsScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_rounded),
              title: const Text('Automatic mixing'),
              onTap: () => onOpen(const DjModeSettingsScreen(playerFacing: true)),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.album_rounded),
              title: const Text('Switch to Resonatix DJ'),
              subtitle: const Text('Open the manual performance workspace'),
              onTap: () async {
                Navigator.of(context).pop();
                await context.read<ExperienceProvider>().switchExperience(
                  ResonateExperience.resonatixDj,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () => onOpen(const SettingsScreen()),
            ),
          ],
        ),
      ),
    );
  }
}
