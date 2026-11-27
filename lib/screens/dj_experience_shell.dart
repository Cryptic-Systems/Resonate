import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../experience/experience_provider.dart';
import '../navigation/shell_nav.dart';
import '../providers/music_provider.dart';
import '../services/workspace_lifecycle_coordinator.dart';
import '../services/workspace_transition_controller.dart';
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

  late final PageController _pageController;
  late final MusicProvider _music;
  late final WorkspaceLifecycleCoordinator _workspaceLifecycle;
  ShellNav? _shellNav;
  int _selectedIndex = _workspaceTab;
  bool _djSessionStarted = false;
  bool _djSessionCleanupRequired = false;
  bool _consoleOpening = false;
  bool _switchingToPlayer = false;
  Future<void>? _sessionStart;
  Future<void>? _sessionTeardown;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _workspaceTab);
    _music = context.read<MusicProvider>();
    _workspaceLifecycle = context.read<WorkspaceLifecycleCoordinator>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shellNav = context.read<ShellNav>();
      _shellNav?.bind(
        _selectPage,
        playerTabIndex: _workspaceTab,
        onSwitchToPlayer: _switchToPlayer,
      );
      _sessionStart = _startDjSession();
      unawaited(_sessionStart!);
    });
  }

  Future<void> _startDjSession() async {
    try {
      await _workspaceLifecycle.activate(ResonateWorkspace.dj);
      if (!mounted) {
        await _workspaceLifecycle.activate(ResonateWorkspace.player);
        _djSessionStarted = false;
        return;
      }
      _djSessionCleanupRequired = true;
      await _music.beginDjSession();
      _djSessionStarted = true;
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        context
            .read<WorkspaceTransitionController>()
            .markReady(ResonateWorkspace.dj);
      }
    } catch (error) {
      // Startup may have partially initialized the music session. Keep the
      // teardown flag set until endDjSession has had a chance to reconcile it.
      try {
        await _music.endDjSession();
        _djSessionCleanupRequired = false;
      } catch (cleanupError) {
        // Keep cleanup required so a later exit/dispose can retry it.
        debugPrint('DJ startup rollback failed: $cleanupError');
      }
      try {
        await _workspaceLifecycle.activate(ResonateWorkspace.player);
      } catch (lifecycleError) {
        debugPrint('DJ workspace startup rollback failed: $lifecycleError');
      }
      _djSessionStarted = false;
      if (mounted) {
        context
            .read<WorkspaceTransitionController>()
            .markFailed(ResonateWorkspace.dj, error);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not initialize Resonatix DJ: $error')),
        );
      }
    }
  }

  Future<void> _endDjSessionAndRestorePlayer() {
    return _sessionTeardown ??= _finishDjSessionTeardown();
  }

  Future<void> _finishDjSessionTeardown() async {
    try {
      // Never race endDjSession against beginDjSession. Startup owns the
      // transition until it settles, including rollback after partial failure.
      await _sessionStart;
      if (_djSessionStarted || _djSessionCleanupRequired) {
        await _music.endDjSession();
        _djSessionStarted = false;
        _djSessionCleanupRequired = false;
      }
      await _workspaceLifecycle.activate(ResonateWorkspace.player);
    } catch (_) {
      // Permit a later navigation/dispose attempt to retry failed cleanup.
      _sessionTeardown = null;
      rethrow;
    }
  }

  Future<void> _switchToPlayer() async {
    if (_switchingToPlayer ||
        (_sessionStart == null &&
            !_djSessionStarted &&
            !_djSessionCleanupRequired)) {
      return;
    }
    _switchingToPlayer = true;
    final transition = context.read<WorkspaceTransitionController>();
    final experience = context.read<ExperienceProvider>();
    try {
      await transition.transitionTo(
        ResonateWorkspace.player,
        performHandoff: () async {
          await _endDjSessionAndRestorePlayer();
          if (!mounted) return;
          Navigator.of(context).popUntil((route) => route.isFirst);
          await experience.switchExperience(ResonateExperience.player);
        },
      );
    } catch (error) {
      // A destination startup failure must not leave a half-mounted Player.
      // Re-enter DJ through the same readiness barrier when Player was selected.
      if (experience.selected == ResonateExperience.player) {
        try {
          await transition.transitionTo(
            ResonateWorkspace.dj,
            performHandoff: () =>
                experience.switchExperience(ResonateExperience.resonatixDj),
          );
        } catch (rollbackError) {
          debugPrint('DJ workspace recovery after Player failure failed: $rollbackError');
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not return to Resonate Player: $error')),
      );
    } finally {
      _switchingToPlayer = false;
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
    if (_djSessionStarted || _djSessionCleanupRequired || _sessionStart != null) {
      unawaited(_endDjSessionAndRestorePlayer().catchError((Object error) {
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
        selectedIndex: _selectedIndex == _libraryTab ? 2 : 0,
        onDestinationSelected: (index) {
          if (index == 1) {
            unawaited(_openConsole());
            return;
          }
          _selectPage(index == 0 ? _workspaceTab : _libraryTab);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_outlined),
            selectedIcon: Icon(Icons.graphic_eq_rounded),
            label: 'Workspace',
          ),
          NavigationDestination(
            icon: Icon(Icons.album_outlined),
            selectedIcon: Icon(Icons.album_rounded),
            label: 'Console',
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
