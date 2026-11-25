import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/intelligence_provider.dart';
import '../providers/library_provider.dart';
import '../ui/resonate_glass.dart';
import '../widgets/autopilot_home_card.dart';
import '../widgets/resonate_logo.dart';
import 'discovery_screen.dart';
import 'settings_screen.dart';
import 'listening_history_screen.dart';
import '../modes/screens/modes_screen.dart';
import '../modes/integration/resonate_mode_ports.dart';
import '../experience/experience_provider.dart';

class HomeDashboard extends StatelessWidget {
  const HomeDashboard();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final intelligence = context.watch<IntelligenceProvider>();
    final songs = library.allSongs;
    return ResonateGlassScaffold(
      title: const ResonateLogo(size: 58, full: true, showWord: false),
      leading: Builder(
        builder: (context) => IconButton(
          tooltip: 'For You menu',
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      ),
      drawer: _ForYouSideDrawer(
        onOpen: (screen) {
          Navigator.of(context).pop();
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
        },
      ),
      body: RefreshIndicator(
        onRefresh: intelligence.refreshRecommendations,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
          children: [
            AutopilotHomeCard(songCount: songs.length),
            const SizedBox(height: 16),
            ResonateGlassCard(
              blurEnabled: false,
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.explore_rounded, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 9),
                    Text('Discover your next listen', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 7),
                  Text(
                    intelligence.isEnabled
                        ? 'Explore recommendations, evolving mixes and listening experiences shaped around your current context.'
                        : 'Explore your library through listening modes, mixes and personalised discovery.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const DiscoveryScreen()),
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('Open Discovery'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const ResonateGlassCard(
              blurEnabled: false,
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(Icons.library_music_rounded),
                title: Text('Your music stays organised in Library'),
                subtitle: Text('Browse your collection, playlists, favourites and listening history there.'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}


class _ForYouSideDrawer extends StatelessWidget {
  const _ForYouSideDrawer({required this.onOpen});
  final void Function(Widget screen) onOpen;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 10),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Text('RESONATE', style: Theme.of(context).textTheme.labelLarge),
            ),
            ListTile(
              leading: const Icon(Icons.explore_rounded),
              title: const Text('Discovery'),
              onTap: () => onOpen(const DiscoveryScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Listening modes'),
              onTap: () => onOpen(ModesScreen(folderPicker: const ResonateModeFolderPickerPort())),
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Listening history'),
              onTap: () => onOpen(const ListeningHistoryScreen()),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.album_rounded),
              title: const Text('Switch to Resonatix DJ'),
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
