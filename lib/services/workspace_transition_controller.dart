import 'dart:async';

import 'package:flutter/foundation.dart';

import 'workspace_lifecycle_coordinator.dart';

/// Coordinates visible Player/DJ handoffs without owning playback services.
///
/// The source workspace remains visible under a blocking transition surface
/// until the destination reports that its first usable frame is mounted.
class WorkspaceTransitionController extends ChangeNotifier {
  static const Duration _readinessTimeout = Duration(seconds: 20);

  Future<void> _tail = Future<void>.value();
  Completer<void>? _destinationReady;
  ResonateWorkspace? _destination;
  bool _isTransitioning = false;
  bool _disposed = false;
  int _generation = 0;

  bool get isTransitioning => _isTransitioning;
  ResonateWorkspace? get destination => _destination;
  String get title => _destination == ResonateWorkspace.dj
      ? 'Preparing DJ Workspace'
      : 'Returning to Player';

  /// Serializes handoffs and waits for the destination shell to signal ready.
  Future<void> transitionTo(
    ResonateWorkspace destination, {
    required Future<void> Function() performHandoff,
  }) {
    final previous = _tail;
    final completion = Completer<void>();
    _tail = completion.future.catchError((Object _) {});
    return _runAfter(previous, completion, destination, performHandoff);
  }

  Future<void> _runAfter(
    Future<void> previous,
    Completer<void> completion,
    ResonateWorkspace destination,
    Future<void> Function() performHandoff,
  ) async {
    try {
      await previous;
      if (_disposed) throw StateError('Workspace transition controller disposed.');

      final generation = ++_generation;
      _destination = destination;
      _destinationReady = Completer<void>();
      _isTransitioning = true;
      notifyListeners();

      await performHandoff();
      if (_disposed || generation != _generation) {
        throw StateError('Workspace transition was superseded.');
      }

      await _destinationReady!.future.timeout(_readinessTimeout);
      if (_disposed || generation != _generation) {
        throw StateError('Workspace transition was superseded.');
      }

      _isTransitioning = false;
      _destination = null;
      _destinationReady = null;
      notifyListeners();
    } catch (_) {
      if (!_disposed) {
        _isTransitioning = false;
        _destination = null;
        _destinationReady = null;
        notifyListeners();
      }
      rethrow;
    } finally {
      if (!completion.isCompleted) completion.complete();
    }
  }

  /// Called by the mounted destination shell after its required startup work.
  void markReady(ResonateWorkspace workspace) {
    if (!_isTransitioning || _destination != workspace) return;
    final ready = _destinationReady;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  /// Fails the active handoff when destination initialization cannot complete.
  void markFailed(ResonateWorkspace workspace, Object error) {
    if (!_isTransitioning || _destination != workspace) return;
    final ready = _destinationReady;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    final ready = _destinationReady;
    if (ready != null && !ready.isCompleted) {
      // Complete normally: the transition may still be awaiting handoff
      // preparation and attach its readiness listener only after that settles.
      ready.complete();
    }
    _destinationReady = null;
    super.dispose();
  }
}
