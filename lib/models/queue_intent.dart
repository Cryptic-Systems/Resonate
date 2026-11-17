import '../modes/models/resonate_mode.dart';

/// A listening goal translated into musical constraints for queue planning.
/// These constraints select/order tracks only; they never alter playback speed,
/// pitch, gain, or DSP settings.
class QueueIntent {
  const QueueIntent({
    required this.id, required this.label, this.minBpm, this.maxBpm,
    this.minEnergy, this.maxEnergy, this.targetEnergy = 0.5,
    this.requireBeatGrid = false, this.requireEnergy = false,
    this.minAnalysisConfidence = 0.35,
  });
  final String id;
  final String label;
  final double? minBpm, maxBpm, minEnergy, maxEnergy;
  final double targetEnergy;
  final bool requireBeatGrid, requireEnergy;
  final double minAnalysisConfidence;

  static const calmerMix = QueueIntent(
    id: 'calmer_mix', label: 'Calmer Mix', minBpm: 60, maxBpm: 115,
    minEnergy: 0.0, maxEnergy: 0.48, targetEnergy: 0.28,
    requireBeatGrid: true, requireEnergy: true,
  );
  static const highEnergy = QueueIntent(
    id: 'high_energy', label: 'High Energy', minBpm: 120, maxBpm: 180,
    minEnergy: 0.52, maxEnergy: 1.0, targetEnergy: 0.78,
    requireBeatGrid: true, requireEnergy: true, minAnalysisConfidence: 0.40,
  );
  static const workout = QueueIntent(
    id: 'workout', label: 'Workout', minBpm: 120, maxBpm: 160,
    minEnergy: 0.48, maxEnergy: 1.0, targetEnergy: 0.76,
    requireBeatGrid: true, requireEnergy: true, minAnalysisConfidence: 0.40,
  );
  static const focus = QueueIntent(
    id: 'focus', label: 'Focus', minBpm: 65, maxBpm: 125,
    minEnergy: 0.12, maxEnergy: 0.58, targetEnergy: 0.34,
    requireBeatGrid: true, requireEnergy: true,
  );
  static const sleep = QueueIntent(
    id: 'sleep', label: 'Sleep', minBpm: 55, maxBpm: 105,
    minEnergy: 0.0, maxEnergy: 0.38, targetEnergy: 0.20,
    requireBeatGrid: true, requireEnergy: true,
  );
  static const motivation = QueueIntent(
    id: 'motivation', label: 'Motivation', minBpm: 95, maxBpm: 155,
    minEnergy: 0.45, maxEnergy: 1.0, targetEnergy: 0.72,
    requireBeatGrid: true, requireEnergy: true, minAnalysisConfidence: 0.40,
  );
  static const driving = QueueIntent(
    id: 'driving', label: 'Driving', minBpm: 85, maxBpm: 135,
    minEnergy: 0.30, maxEnergy: 0.78, targetEnergy: 0.54,
    requireBeatGrid: true, requireEnergy: true,
  );
  static const balanced = QueueIntent(id: 'balanced', label: 'Balanced Mix');

  static QueueIntent? forMode(ResonateMode mode) => switch (mode) {
    // These modes explicitly target music and can safely apply DJ constraints.
    ResonateMode.running || ResonateMode.workout => workout,
    ResonateMode.work => focus,
    // The shared planner arranges music and preserves allowed spoken-content
    // anchors for mixed-media modes.
    ResonateMode.driving => driving,
    ResonateMode.motivation => motivation,
    ResonateMode.sleep => sleep,
    ResonateMode.normal ||
    ResonateMode.podcast ||
    ResonateMode.audiobook => null,
  };
}
