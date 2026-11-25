import 'package:flutter/material.dart';

import '../ui/resonate_glass.dart';

/// In-app notification inbox. Event producers can add their alerts here as
/// notification sources are connected; Android system notifications remain a
/// separate delivery layer.
class NotificationCenterScreen extends StatelessWidget {
  const NotificationCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ResonateGlassCard(
              blurEnabled: false,
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
              child: Column(
                children: [
                  Icon(Icons.notifications_none_rounded,
                      size: 44, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('You’re all caught up',
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    'Resonate alerts will appear here, including driving-context and car-detection notices when that event source is connected.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
