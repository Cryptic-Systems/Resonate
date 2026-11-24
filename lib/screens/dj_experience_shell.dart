import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../experience/experience_provider.dart';
import '../navigation/shell_nav.dart';
import '../providers/music_provider.dart';
import 'dj_console_screen.dart';
import 'dj_library_screen.dart';
import 'dj_workspace_screen.dart';

/// Dedicated navigation shell for Resonatix DJ.
class DjExperienceShell extends StatefulWidget {
  const DjExperienceShell({super.key});

  @override
  State<DjExperienceShell> createState() => _DjExperienceShellState();
}

class _DjExperienceShellState extends State<DjExperienceShell> {
  static const int _workspaceTab = 0;
  static const int _libraryTab = 1;
  static const int _consoleTab = 2;

  late final PageController _pageController;
  late final MusicProvider _music;
  ShellNav? _shellNav;
  int _selectedIndex = _workspaceTab;
  bool _djSessionStarted = false;
  bool _consoleOpening = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _workspaceTab);
    _music = context.read<MusicProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shellNav = context.read<ShellNav>();
      _shellNav?.bind(
        _selectPage,
        playerTabIndex: _workspaceTab,
        onSwitchToPlayer: _switchToPlayer,
      );
      unawaited(_startDjSession());
    });
  }

  Future<void> _startDjSession() async {
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

  Future<void> _switchToPlayer() async {
    if (!_djSessionStarted) return;
    try {
      await _music.endDjSession();
      _djSessionStarted = false;
      if (!mounted) return;
      await context.read<ExperienceProvider>().switchExperience(
            ResonateExperience.player,
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not return to Resonate Player: $error')),
      );
    }
  }

  Future<void> _openConsole() async {
    if (_consoleOpening || !mounted) return;
    _consoleOpening = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DjConsoleScreen()),
      );
    } finally {
      _consoleOpening = false;
    }
  }

  void _selectPage(int index) {
    if (index < _workspaceTab || index > _libraryTab || index == _selectedIndex) {
      return;
    }
    setState(() => _selectedIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
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
        children: [
          DjWorkspaceScreen(onSwitchToPlayer: _switchToPlayer),
          const DjLibraryScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          if (index == _consoleTab) {
            unawaited(_openConsole());
            return;
          }
          _selectPage(index);
        },
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
          NavigationDestination(
            icon: Icon(Icons.album_outlined),
            selectedIcon: Icon(Icons.album_rounded),
            label: 'Console',
          ),
        ],
      ),
    );
  }
}
