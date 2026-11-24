import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Tab shell coordinator for [HomeScreen].
///
/// Prefer this over [Navigator.push] of [PlayerScreen] so the bottom navigation
/// bar stays visible and only one player surface exists.
class ShellNav extends ChangeNotifier {
  void Function(int index)? _goToTab;
  int _playerTabIndex = 2;\n  Future<void> Function()? _switchToPlayer;

  void bind(void Function(int index) goToTab, {int playerTabIndex = 2}) {
    _goToTab = goToTab;
    _playerTabIndex = playerTabIndex;
  }

  void unbind() {
    _goToTab = null;
  }

  void goToTab(int index) {
    _goToTab?.call(index);
  }

  /// Player tab index in the main shell (For You=0, Library=1, Player=2, Settings=3).
  void goToPlayer() => goToTab(_playerTabIndex);\n\n  /// Leaves Resonatix DJ through its owning shell so the DJ session is\n  /// normalized before the Player experience is mounted.\n  Future<void> switchToPlayer() async {\n    final action = _switchToPlayer;\n    if (action != null) {\n      await action();\n    } else {\n      goToPlayer();\n    }\n  }
}

/// Switch to the shell Player tab and drop any routes stacked above the shell.
///
/// Call after starting playback from Library, Album, Queue, etc.
void openShellPlayer(BuildContext context) {
  final shell = context.read<ShellNav>();
  final navigator = Navigator.of(context);
  shell.goToPlayer();
  if (navigator.canPop()) {
    navigator.popUntil((route) => route.isFirst);
  }
}
