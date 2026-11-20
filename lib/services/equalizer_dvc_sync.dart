import 'package:flutter/foundation.dart';

import '../playback/playback_control_arbiter.dart';
import 'audio_effects_bridge.dart';
import 'audio_output_route.dart';

Future<void> _withDspControlLease({
  PlaybackControlArbiter? arbiter,
  PlaybackControlLease? lease,
  required PlaybackControlPriority priority,
  required String operation,
  required Future<void> Function(PlaybackControlLease? lease) action,
}) async {
  if (lease != null || arbiter == null) {
    await action(lease);
    return;
  }
  final acquired = await arbiter.acquire(
    owner: 'dsp_profile',
    priority: priority,
  );
  if (acquired == null) return;
  try {
    if (!acquired.authorizeWrite(operation)) return;
    await action(acquired);
  } finally {
    await acquired.release();
  }
}

bool _authorize(PlaybackControlLease? lease, String operation) =>
    lease == null || lease.authorizeWrite(operation);

/// Sends the independent EQ preamp value to the live native DSP preamp stage.
Future<void> syncPreampToNativeDsp(
  double preampDb, {
  bool enabled = true,
  PlaybackControlArbiter? arbiter,
  PlaybackControlLease? lease,
  PlaybackControlPriority priority = PlaybackControlPriority.interactive,
}) async {
  final db = enabled ? preampDb.clamp(-12.0, 12.0) : 0.0;
  await _withDspControlLease(
    arbiter: arbiter,
    lease: lease,
    priority: priority,
    operation: 'sync_dsp_preamp',
    action: (activeLease) async {
      if (!_authorize(activeLease, 'sync_dsp_preamp')) return;
      final result = await AudioEffectsBridge.setLiveDspPreampDb(db.toDouble());
      if (result != null) {
        debugPrint('live DSP preamp db=$db active=${result['active']}');
      }
    },
  );
}

/// Push studio multi-band curve into live native DSP ENGINE EQ (A/B).
Future<void> syncStudioBandsToNativeEq({
  required List<double> centersHz,
  required List<double> gainsDb,
  required bool enabled,
  PlaybackControlArbiter? arbiter,
  PlaybackControlLease? lease,
  PlaybackControlPriority priority = PlaybackControlPriority.interactive,
}) async {
  await _withDspControlLease(
    arbiter: arbiter,
    lease: lease,
    priority: priority,
    operation: 'sync_studio_eq',
    action: (activeLease) async {
      if (!_authorize(activeLease, 'sync_studio_eq')) return;
      try {
        final result = await AudioEffectsBridge.setLiveDspEqBands(
          centersHz: centersHz,
          gainsDb: gainsDb,
          enabled: enabled,
        );
        if (result != null) {
          debugPrint(
            'live EQ bands=${gainsDb.length} enabled=$enabled active=${result['active']}',
          );
        }
      } catch (error) {
        debugPrint('live EQ band update failed: $error');
      }
    },
  );
}

/// Apply speaker-protection + virtual-bass policy from output route.
Future<void> syncSpeakerPolicy({
  required bool needsSpeakerProtection,
  double? virtualBassAmount,
  AudioOutputRoute? route,
  PlaybackControlArbiter? arbiter,
  PlaybackControlLease? lease,
  PlaybackControlPriority priority = PlaybackControlPriority.background,
}) async {
  final resolvedRoute = route ?? AudioOutputRouteService.instance.route;
  final amount = (virtualBassAmount ??
          AudioOutputRouteService.instance.suggestedVirtualBass)
      .clamp(0.0, 1.0)
      .toDouble();

  final bass = needsSpeakerProtection
      ? amount
      : (resolvedRoute == AudioOutputRoute.car ? 0.0 : amount);

  await _withDspControlLease(
    arbiter: arbiter,
    lease: lease,
    priority: priority,
    operation: 'sync_speaker_policy',
    action: (activeLease) async {
      if (!_authorize(activeLease, 'speaker_protection')) return;
      final speakerResult =
          await AudioEffectsBridge.setLiveDspSpeakerMode(
        needsSpeakerProtection,
      );
      if (speakerResult != null) {
        debugPrint(
          'live speakerMode=$needsSpeakerProtection '
          'route=${resolvedRoute.name} active=${speakerResult['active']}',
        );
      }
      if (!_authorize(activeLease, 'virtual_bass')) return;
      final bassResult = await AudioEffectsBridge.setLiveDspVirtualBass(bass);
      if (bassResult != null) {
        debugPrint('live virtualBass=$bass route=${resolvedRoute.name}');
      }
    },
  );
}
