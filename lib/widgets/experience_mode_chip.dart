import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../experience/experience_provider.dart';

/// Compact product-mode switch for Resonate Player surfaces.
class ExperienceModeChip extends StatelessWidget {
  const ExperienceModeChip({super.key});

  Future<void> _showSwitcher(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.music_note_rounded),
                title: const Text('Resonate Player'),
                subtitle: const Text('Everyday listening and automation'),
                trailing: const Icon(Icons.check_circle_rounded),
                onTap: () => Navigator.of(sheetContext).pop(),
              ),
              ListTile(
                leading: const Icon(Icons.album_rounded),
                title: const Text('Resonatix DJ'),
                subtitle: const Text('Manual decks and performance workspace'),
                trailing: const Icon(Icons.arrow_forward_rounded),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await context.read<ExperienceProvider>().switchExperience(
                        ResonateExperience.resonatixDj,
                      );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: const Icon(Icons.music_note_rounded, size: 16),
      label: const Text('Resonate Player'),
      onPressed: () => _showSwitcher(context),
    );
  }
}
