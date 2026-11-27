/// Converts native per-deck DSP telemetry into display-safe, optional readings.
///
/// This policy intentionally reads only liveMetersByDeck. Configuration fields
/// in the native status map are never treated as measurements.
class DspLiveMeterSnapshot {
  const DspLiveMeterSnapshot({
    required this.decks,
    required this.activeDeckId,
  });

  final Map<String, DspDeckMeterReading> decks;
  final String? activeDeckId;

  static DspLiveMeterSnapshot? fromNativeStatus(
    Map<String, dynamic>? status,
  ) {
    if (status == null) return null;
    final rawDecks = status['liveMetersByDeck'];
    if (rawDecks is! Map) return null;

    final decks = <String, DspDeckMeterReading>{};
    for (final entry in rawDecks.entries) {
      final deckId = entry.key.toString().trim().toUpperCase();
      if (deckId != 'A' && deckId != 'B' || entry.value is! Map) continue;
      final reading = DspDeckMeterReading.fromNativeMap(
        deckId,
        Map<dynamic, dynamic>.from(entry.value as Map),
      );
      if (reading.hasAnyReading) decks[deckId] = reading;
    }
    if (decks.isEmpty) return null;

    final active = status['activeDeckId']?.toString().trim().toUpperCase();
    return DspLiveMeterSnapshot(
      decks: Map.unmodifiable(decks),
      activeDeckId: active == 'A' || active == 'B' ? active : null,
    );
  }

  /// Maps a dBFS value onto a circular dial spanning [minimumDb, maximumDb].
  /// The source value remains unchanged for its numeric readout.
  static double normalizeDbfs(
    double value, {
    double minimumDb = -60,
    double maximumDb = 0,
  }) {
    if (!value.isFinite || !minimumDb.isFinite || !maximumDb.isFinite ||
        maximumDb <= minimumDb) {
      return 0;
    }
    return ((value.clamp(minimumDb, maximumDb) - minimumDb) /
            (maximumDb - minimumDb))
        .toDouble();
  }

  /// Maps a signed applied-gain reading onto a centered display scale.
  static double normalizeSignedDb(
    double value, {
    double minimumDb = -12,
    double maximumDb = 12,
  }) {
    if (!value.isFinite || !minimumDb.isFinite || !maximumDb.isFinite ||
        maximumDb <= minimumDb) {
      return 0.5;
    }
    return ((value.clamp(minimumDb, maximumDb) - minimumDb) /
            (maximumDb - minimumDb))
        .toDouble();
  }
}

class DspDeckMeterReading {
  const DspDeckMeterReading({
    required this.deckId,
    required this.inputPeakDb,
    required this.inputTruePeakDb,
    required this.postEqPeakDb,
    required this.bassBandPeakDb,
    required this.headroomDb,
    required this.shortTermRmsDb,
    required this.limiterGrDb,
    required this.limiterGrPeakDb,
    required this.autoBassAppliedDb,
    required this.autoGainAppliedDb,
    required this.autoPreampAppliedDb,
    required this.autoVirtualBassApplied,
  });

  final String deckId;
  final double? inputPeakDb;
  final double? inputTruePeakDb;
  final double? postEqPeakDb;
  final double? bassBandPeakDb;
  final double? headroomDb;
  final double? shortTermRmsDb;
  final double? limiterGrDb;
  final double? limiterGrPeakDb;
  final double? autoBassAppliedDb;
  final double? autoGainAppliedDb;
  final double? autoPreampAppliedDb;
  final double? autoVirtualBassApplied;

  bool get hasAnyReading => [
        inputPeakDb,
        inputTruePeakDb,
        postEqPeakDb,
        bassBandPeakDb,
        headroomDb,
        shortTermRmsDb,
        limiterGrDb,
        limiterGrPeakDb,
        autoBassAppliedDb,
        autoGainAppliedDb,
        autoPreampAppliedDb,
        autoVirtualBassApplied,
      ].any((value) => value != null);

  factory DspDeckMeterReading.fromNativeMap(
    String deckId,
    Map<dynamic, dynamic> values,
  ) {
    double? read(String key) {
      final value = values[key];
      if (value is! num) return null;
      final result = value.toDouble();
      return result.isFinite ? result : null;
    }

    return DspDeckMeterReading(
      deckId: deckId,
      inputPeakDb: read('inputPeakDb'),
      inputTruePeakDb: read('inputTruePeakDb'),
      postEqPeakDb: read('postEqPeakDb'),
      bassBandPeakDb: read('bassBandPeakDb'),
      headroomDb: read('headroomDb'),
      shortTermRmsDb: read('shortTermRmsDb'),
      limiterGrDb: read('limiterGrDb'),
      limiterGrPeakDb: read('limiterGrPeakDb'),
      autoBassAppliedDb: read('autoBassAppliedDb'),
      autoGainAppliedDb: read('autoGainAppliedDb'),
      autoPreampAppliedDb: read('autoPreampAppliedDb'),
      autoVirtualBassApplied: read('autoVirtualBassApplied'),
    );
  }
}
