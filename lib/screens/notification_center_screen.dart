import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../modes/models/driving_intent.dart';
import '../modes/models/resonate_mode.dart';
import '../modes/providers/mode_provider.dart';
import '../ui/resonate_glass.dart';

/// In-app notification surface for context and mode alerts.
/// Android system-notification delivery remains a separate integration layer.
class NotificationCenterScreen extends StatelessWidget {
  const NotificationCenterScreen({super.key});

  String _message(DrivingIntentType type) {
    switch (type) {
      case DrivingIntentType.carContextDetected:
        return 'Car connection detected';
      case DrivingIntentType.carContextLost:
        return 'Car connection ended';
      case DrivingIntentType.suggestDriving:
        return 'Driving Mode is available';
      case DrivingIntentType.drivingActive:
        return 'Driving Mode activated';
      case DrivingIntentType.drivingInactive:
        return 'Driving Mode deactivated';
    }
  }

  IconData _icon(DrivingIntentType type) {
    switch (type) {
      case DrivingIntentType.carContextDetected:
      case DrivingIntentType.carContextLost:
        return Icons.directions_car_rounded;
      case DrivingIntentType.suggestDriving:
        return Icons.lightbulb_outline_rounded;
      case DrivingIntentType.drivingActive:
      case DrivingIntentType.drivingInactive:
        return Icons.route_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: Consumer<ModeProvider>(
          builder: (context, modes, _) {
            final alerts = modes.lastDrivingIntents.reversed.toList(growable: false);
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                ResonateGlassCard(
                  blurEnabled: false,
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        modes.drivingContextActive
                            ? Icons.directions_car_filled_rounded
                            : Icons.notifications_active_outlined,
                        size: 28,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              modes.drivingContextActive
                                  ? 'Car context detected'
                                  : 'No active car context',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Driving-context alerts are collected in this in-app inbox.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text('RECENT DRIVING ALERTS', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                if (alerts.isEmpty)
                  ResonateGlassCard(
                    blurEnabled: false,
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                    child: Column(
                      children: [
                        Icon(Icons.notifications_none_rounded,
                            size: 38, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text('You’re all caught up',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          'Car detection and Driving Mode events will appear here when Resonate receives them.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ...alerts.map((alert) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ResonateGlassCard(
                          blurEnabled: false,
                          margin: EdgeInsets.zero,
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: Icon(_icon(alert.type),
                                color: theme.colorScheme.primary),
                            title: Text(_message(alert.type)),
                            subtitle: Text(
                              '${alert.mode.label} · ${alert.at.toLocal().toString().substring(0, 16)}',
                            ),
                          ),
                        ),
                      )),
                const SizedBox(height: 12),
                Text(
                  'These are in-app context events. Android notification delivery can be added separately.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
