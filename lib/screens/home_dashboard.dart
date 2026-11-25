import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/intelligence_provider.dart';
import '../providers/library_provider.dart';
import '../ui/resonate_glass.dart';
import '../widgets/autopilot_home_card.dart';
import '../widgets/experience_mode_chip.dart';
import '../widgets/resonate_logo.dart';
import '../widgets/resonate_mode_chip.dart';
import 'discovery_screen.dart';

class HomeDashboard extends StatelessWidget {
  const HomeDashboard();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final intelligence = context.watch<IntelligenceProvider>();
    final songs = library.allSongs;
    return ResonateGlassScaffold(
      title: const ResonateLogo(size: 58, full: true, showWord: false),
      actions: const [ExperienceModeChip(dense: true), ResonateModeChip(dense: true)],
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
