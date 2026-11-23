import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation/shell_nav.dart';
import 'dj_workspace_screen.dart';
import 'library_screen.dart';

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
  ShellNav? _shellNav;
  int _selectedIndex = _workspaceTab;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _workspaceTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shellNav = context.read<ShellNav>();
      _shellNav?.bind(_selectPage, playerTabIndex: _workspaceTab);
    });
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
          LibraryScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _selectPage,
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
