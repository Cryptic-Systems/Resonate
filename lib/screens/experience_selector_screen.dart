import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../experience/experience_provider.dart';

/// First-run choice between the everyday player and hands-on DJ environment.
class ExperienceSelectorScreen extends StatefulWidget {
  const ExperienceSelectorScreen({super.key});

  @override
  State<ExperienceSelectorScreen> createState() =>
      _ExperienceSelectorScreenState();
}

class _ExperienceSelectorScreenState extends State<ExperienceSelectorScreen> {
  bool _saving = false;

  Future<void> _choose(ResonateExperience experience) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await context
          .read<ExperienceProvider>()
          .selectInitialExperience(experience);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save your choice: $error')),
      );
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
              children: [
                Icon(Icons.graphic_eq_rounded,
                    size: 54, color: colors.primary),
                const SizedBox(height: 18),
                Text(
                  'How do you want to experience Resonate?',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  'Choose how you want to listen. You can keep this experience '
                  'as your default when you open the app.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 30),
                _ExperienceCard(
                  icon: Icons.headphones_rounded,
                  title: 'Resonate Player',
                  subtitle: 'Let Resonate take care of the listening.',
                  details: const [
                    'Everyday music playback and your library',
                    'Automatic transitions and Autopilot',
                    'DSP, Ask Resonate and listening intelligence',
                  ],
                  color: colors.primary,
                  enabled: !_saving,
                  onTap: () => _choose(ResonateExperience.player),
                ),
                const SizedBox(height: 14),
                _ExperienceCard(
                  icon: Icons.album_rounded,
                  title: 'Resonatix DJ',
                  subtitle: 'Take control and perform your own mixes.',
                  details: const [
                    'Dedicated DJ Workspace and Console',
                    'Integrated access to your music library',
                    'A hands-on DJ environment as it develops',
                  ],
                  color: colors.secondary,
                  enabled: !_saving,
                  onTap: () => _choose(ResonateExperience.resonatixDj),
                ),
                if (_saving) ...[
                  const SizedBox(height: 22),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 8),
                  const Text('Saving your experience…',
                      textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExperienceCard extends StatelessWidget {
  const _ExperienceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.details,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> details;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.14),
                    foregroundColor: color,
                    child: Icon(icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleLarge),
                  ),
                  Icon(Icons.arrow_forward_rounded, color: color),
                ],
              ),
              const SizedBox(height: 8),
              Text(subtitle, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 12),
              ...details.map(
                (detail) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_rounded, size: 18, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(detail, style: theme.textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
