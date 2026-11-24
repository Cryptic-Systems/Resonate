import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/music_provider.dart';
import '../experience/experience_provider.dart';

import '../navigation/shell_nav.dart';
import 'dj_workspace_screen.dart';
import 'dj_library_screen.dart';\nimport 'dj_console_screen.dart';

/// Dedicated navigation shell for Resonatix DJ.
///
/// The integrated library is shared with Resonate Player, while the Workspace
/// remains the DJ landing surface. The Console is opened from Workspace as a
/// pushed landscape route so its orientation lifecycle stays scoped to it.
class DjExperienceShell extends StatefulWidget {
  const DjExperienceShell({super.key});

  @override
  State<DjExperienceShell> createState() => _DjExperienceShellState();
}

class _DjExperienceShellState extends State<DjExperienceShell> {
  static const int _workspaceTab = 0;
  static const int _libraryTab = 1;

  late final PageController _pageController;
  late final MusicProvider _music;
  ShellNav? _shellNav;
  int _selectedIndex = _workspaceTab;
  bool _djSessionStarted = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _workspaceTab);
    _music = context.read<MusicProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shellNav = context.read<ShellNav>();
      _shellNav?.bind(\n        _selectPage,\n        playerTabIndex: _workspaceTab,\n        onSwitchToPlayer: _switchToPlayer,\n      );
      unawaited(_startDjSession());
    });
  }

  Future<void> _switchToPlayer() async {\n    if (!_djSessionStarted) return;\n    try {\n      await _music.endDjSession();\n      _djSessionStarted = false;\n      if (!mounted) return;\n      await context.read<ExperienceProvider>().switchExperience(\n            ResonateExperience.player,\n          );\n    } catch (error) {\n      if (!mounted) return;\n      ScaffoldMessenger.of(context).showSnackBar(\n        SnackBar(content: Text('Could not return to Resonate Player: $error')),\n      );\n    }\n  }\n\n  Future<void> _startDjSession() async {
    // Mark the shell as responsible for cleanup before the first await. If
    // initialization partially succeeds or is retried from the Library tab,
    // dispose still performs the guarded native cleanup.
    _djSessionStarted = true;
    try {
      await _music.beginDjSession();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not initialize Resonatix DJ: $error')),
      );
    }
  }

  void _selectPage(int index) {
    if (index < _workspaceTab || index > _libraryTab || index == _selectedIndex) {
      return;
    }
    setState(() => _selectedIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _shellNav?.unbind();
    if (_djSessionStarted) {
      unawaited(_music.endDjSession().catchError((Object error) {
        debugPrint('DJ session cleanup failed: $error');
      }));
    }
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _selectedIndex = index),
        children: const [
          DjWorkspaceScreen(),
          DjLibraryScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {\n          if (index == 2) {\n            Navigator.of(context).push(\n              MaterialPageRoute(builder: (_) => const DjConsoleScreen()),\n            );\n            return;\n          }\n          _selectPage(index);\n        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_outlined),
            selectedIcon: Icon(Icons.graphic_eq_rounded),
            label: 'Workspace',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music_rounded),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}
