import '../modes/models/playback_policy.dart';

/// Pure interpretation of Mode policy for Autopilot.
///
/// This class decides what Autopilot may prefer; it never performs playback,
/// queue mutation, or consent changes. MusicProvider remains authoritative.
class AutopilotModePolicy {
  const AutopilotModePolicy._();

  /// Playback mutation is allowed only while all three independent gates are
  /// still open. Keep this pure so consent races can be regression-tested.
  static bool mayMutatePlayback({
    required bool consentGranted,
    required bool intelligenceEnabled,
    required bool autopilotEnabled,
  }) =>
      consentGranted && intelligenceEnabled && autopilotEnabled;

  static bool allowsAutomaticNext(PlaybackPolicy? policy) =>
      policy?.autoNextPreferred != false;

  static bool shouldUseCrossfade({
    required bool userCrossfadeEnabled,
    PlaybackPolicy? policy,
  }) =>
      userCrossfadeEnabled &&
      (policy?.preferCrossfade ?? true) &&
      (policy?.crossfadeAllowed ?? true);

  static int predictedSequenceCount(PlaybackPolicy? policy) =>
      policy?.preferLongSessions == true ? 4 : 2;

  /// Human-readable reason Autopilot is or is not currently able to act.
  /// Reporting readiness never grants playback authority.
  static String readinessMessage({
    required bool intelligenceEnabled,
    required bool autopilotSelected,
    required bool consentGranted,
    required bool hasPendingTakeover,
    required bool transitionInFlight,
    required bool hasCurrentSong,
    required bool isPlaying,
    required bool automaticNextAllowed,
    required bool hasConfidentCandidate,
    required Duration? remaining,
  }) {
    if (!intelligenceEnabled) return 'Intelligence is off. Playback remains fully manual.';
    if (!autopilotSelected) return 'Autopilot is not selected. Choose it in Intelligence settings to enable automatic transition decisions.';
    if (hasPendingTakeover) return 'A next-track choice is waiting for your approval.';
    if (!consentGranted) return 'Autopilot is advisory only. Grant playback consent before it can enqueue or change tracks.';
    if (!hasCurrentSong) return 'Start a track. Autopilot monitors playback and prepares a next-track choice.';
    if (!isPlaying) return 'Playback is paused. Autopilot will resume monitoring when you press play.';
    if (!automaticNextAllowed) return 'The active listening mode has disabled automatic next-track decisions.';
    if (transitionInFlight) return 'Autopilot is carrying out an approved track transition.';
    if (!hasConfidentCandidate) return 'Still learning this session. No next-track recommendation currently meets your confidence threshold.';
    if (remaining == null) return 'Monitoring playback. Waiting for reliable track-duration information.';
    if (remaining > const Duration(seconds: 10)) return 'Monitoring playback. The next-track decision is evaluated during the final 10 seconds.';
    return 'A confident next-track choice is ready for the transition window.';
  }

}
