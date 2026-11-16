import 'dart:convert';

import '../core/dj_types.dart';

/// Stable JSON boundary for persisted V2 track profiles.
class DjProfileSerializer {
  const DjProfileSerializer();

  String encode(DjTrackProfile profile) => jsonEncode({
        'songId': profile.songId,
        'durationMs': profile.durationMs,
        'fingerprint': profile.fingerprint,
        'analysisVersion': profile.analysisVersion,
        'analysisConfidence': profile.analysisConfidence,
        'beatGrid': {
          'bpm': profile.beatGrid.bpm,
          'confidence': profile.beatGrid.confidence,
          'firstBeatMs': profile.beatGrid.firstBeatMs,
          'beatMs': profile.beatGrid.beatMs,
          'downbeatMs': profile.beatGrid.downbeatMs,
          'downbeatConfidence': profile.beatGrid.downbeatConfidence,
          'barConfidence': profile.beatGrid.barConfidence,
          'phraseConfidence': profile.beatGrid.phraseConfidence,
          'beatsPerBar': profile.beatGrid.beatsPerBar,
          'beatsPerPhrase': profile.beatGrid.beatsPerPhrase,
        },
        'keyRoot': profile.keyRoot,
        'keyMode': profile.keyMode,
        'keyConfidence': profile.keyConfidence,
        'harmonicChanges': profile.harmonicChanges
            .map((p) => {'timeMs': p.timeMs, 'confidence': p.confidence})
            .toList(),
        'sections': profile.sections
            .map((s) => {
                  'type': s.type.name,
                  'startMs': s.startMs,
                  'endMs': s.endMs,
                  'confidence': s.confidence,
                  'energy': s.energy,
                })
            .toList(),
        'energyCurve': profile.energyCurve
            .map((p) => {
                  'timeMs': p.timeMs,
                  'value': p.value,
                  'loudness': p.loudness,
                  'bass': p.bass,
                  'mids': p.mids,
                  'highs': p.highs,
                  'slope': p.slope,
                })
            .toList(),
        'spectrum': {
          'bass': profile.spectrum.bass,
          'mids': profile.spectrum.mids,
          'highs': profile.spectrum.highs,
          'centroid': profile.spectrum.centroid,
          'bassDensity': profile.spectrum.bassDensity,
          'spectralFlux': profile.spectrum.spectralFlux,
          'confidence': profile.spectrum.confidence,
        },
        'silenceRegions': profile.silenceRegions
            .map((region) => {
                  'startMs': region.startMs,
                  'endMs': region.endMs,
                  'minimumDbfs': region.minimumDbfs,
                  'confidence': region.confidence,
                })
            .toList(),
        'transitions': {
          'bestIntroMs': profile.transitions.bestIntroMs,
          'bestOutroMs': profile.transitions.bestOutroMs,
          'safeMixIns': _encodePoints(profile.transitions.safeMixIns),
          'safeMixOuts': _encodePoints(profile.transitions.safeMixOuts),
          'riskyPoints': _encodePoints(profile.transitions.riskyPoints),
        },
      });

  DjTrackProfile decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final durationMs = (map['durationMs'] as num?)?.toInt();
    final beat = _map(map['beatGrid']);
    final spectrum = _map(map['spectrum']);
    final transition = _map(map['transitions']);
    return DjTrackProfile(
      songId: map['songId'] as String,
      durationMs: durationMs,
      fingerprint: map['fingerprint'] as String?,
      analysisVersion: (map['analysisVersion'] as num?)?.toInt() ?? 1,
      analysisConfidence: (map['analysisConfidence'] as num?)?.toDouble() ?? 0,
      beatGrid: DjBeatGrid(
        bpm: (beat['bpm'] as num?)?.toDouble(),
        confidence: (beat['confidence'] as num?)?.toDouble() ?? 0,
        firstBeatMs: _time(beat['firstBeatMs'], durationMs),
        beatMs: _orderedTimes(beat['beatMs'], durationMs),
        beatsPerBar: (beat['beatsPerBar'] as num?)?.toInt() ?? 4,
        beatsPerPhrase: (beat['beatsPerPhrase'] as num?)?.toInt() ?? 16,
        downbeatMs: _orderedTimes(beat['downbeatMs'], durationMs),
        downbeatConfidence: (beat['downbeatConfidence'] as num?)?.toDouble() ?? 0,
        barConfidence: (beat['barConfidence'] as num?)?.toDouble() ?? 0,
        phraseConfidence: (beat['phraseConfidence'] as num?)?.toDouble() ?? 0,
      ),
      keyRoot: (map['keyRoot'] as num?)?.toInt(),
      keyMode: map['keyMode'] as String?,
      keyConfidence: (map['keyConfidence'] as num?)?.toDouble() ?? 0,
      harmonicChanges: _points(map['harmonicChanges'], durationMs),
      sections: _sections(map['sections'], durationMs),
      energyCurve: _energy(map['energyCurve'], durationMs),
      spectrum: DjSpectralProfile(
        bass: (spectrum['bass'] as num?)?.toDouble() ?? 0.5,
        mids: (spectrum['mids'] as num?)?.toDouble() ?? 0.5,
        highs: (spectrum['highs'] as num?)?.toDouble() ?? 0.5,
        centroid: (spectrum['centroid'] as num?)?.toDouble() ?? 0.5,
        bassDensity: (spectrum['bassDensity'] as num?)?.toDouble() ?? 0.5,
        spectralFlux: (spectrum['spectralFlux'] as num?)?.toDouble() ?? 0.5,
        confidence: (spectrum['confidence'] as num?)?.toDouble() ?? 0,
      ),
      silenceRegions: _silenceRegions(map['silenceRegions'], durationMs),
      transitions: DjTransitionMarkers(
        bestIntroMs: _time(transition['bestIntroMs'], durationMs),
        bestOutroMs: _time(transition['bestOutroMs'], durationMs),
        safeMixIns: _points(transition['safeMixIns'], durationMs),
        safeMixOuts: _points(transition['safeMixOuts'], durationMs),
        riskyPoints: _points(transition['riskyPoints'], durationMs),
      ),
    );
  }

  List<Map<String, dynamic>> _encodePoints(List<DjTimePoint> values) => values
      .map((p) => {
            'timeMs': p.timeMs,
            'confidence': p.confidence,
          })
      .toList();

  int? _time(dynamic value, int? durationMs) {
    if (value is! num || !value.isFinite) return null;
    final time = value.toInt();
    if (time < 0 || (durationMs != null && (durationMs <= 0 || time > durationMs))) {
      return null;
    }
    return time;
  }

  List<int> _orderedTimes(dynamic value, int? durationMs) {
    if (value is! List) return const [];
    final result = <int>[];
    for (final item in value) {
      final time = _time(item, durationMs);
      if (time == null || (result.isNotEmpty && time <= result.last)) continue;
      result.add(time);
    }
    return result;
  }

  List<DjTimePoint> _points(dynamic value, int? durationMs) {
    if (value is! List) return const [];
    final points = <DjTimePoint>[];
    for (final raw in value.whereType<Map>()) {
      final time = _time(raw['timeMs'], durationMs);
      final confidence = (raw['confidence'] as num?)?.toDouble() ?? 0;
      if (time == null || !confidence.isFinite || confidence < 0 || confidence > 1) {
        continue;
      }
      points.add(DjTimePoint(time, confidence: confidence));
    }
    points.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return points;
  }

  List<DjSilenceRegion> _silenceRegions(dynamic value, int? durationMs) {
    if (value is! List) return const [];
    final regions = <DjSilenceRegion>[];
    for (final raw in value.whereType<Map>()) {
      final start = _time(raw['startMs'], durationMs);
      final end = _time(raw['endMs'], durationMs);
      final confidence = (raw['confidence'] as num?)?.toDouble() ?? 0;
      final minimumDbfs = (raw['minimumDbfs'] as num?)?.toDouble() ?? 0;
      if (start == null || end == null || end <= start ||
          !confidence.isFinite || confidence < 0 || confidence > 1 ||
          !minimumDbfs.isFinite || minimumDbfs > 0 || minimumDbfs < -160) {
        continue;
      }
      regions.add(DjSilenceRegion(
        startMs: start,
        endMs: end,
        minimumDbfs: minimumDbfs,
        confidence: confidence,
      ));
    }
    regions.sort((a, b) => a.startMs.compareTo(b.startMs));
    return regions;
  }

  List<DjSection> _sections(dynamic value, int? durationMs) {
    if (value is! List) return const [];
    final sections = <DjSection>[];
    for (final raw in value.whereType<Map>()) {
      final start = _time(raw['startMs'], durationMs);
      final end = _time(raw['endMs'], durationMs);
      final confidence = (raw['confidence'] as num?)?.toDouble() ?? 0;
      final energy = (raw['energy'] as num?)?.toDouble() ?? 0.5;
      if (start == null || end == null || end <= start ||
          !confidence.isFinite || confidence < 0 || confidence > 1 ||
          !energy.isFinite || energy < 0 || energy > 1) {
        continue;
      }
      sections.add(DjSection(
        type: _sectionType(raw['type']?.toString()),
        startMs: start,
        endMs: end,
        confidence: confidence,
        energy: energy,
      ));
    }
    sections.sort((a, b) => a.startMs.compareTo(b.startMs));
    return sections;
  }

  List<DjEnergyPoint> _energy(dynamic value, int? durationMs) {
    if (value is! List) return const [];
    final points = <DjEnergyPoint>[];
    for (final raw in value.whereType<Map>()) {
      final time = _time(raw['timeMs'], durationMs);
      final fields = [
        (raw['value'] as num?)?.toDouble() ?? 0.5,
        (raw['loudness'] as num?)?.toDouble() ?? 0.5,
        (raw['bass'] as num?)?.toDouble() ?? 0.5,
        (raw['mids'] as num?)?.toDouble() ?? 0.5,
        (raw['highs'] as num?)?.toDouble() ?? 0.5,
        (raw['slope'] as num?)?.toDouble() ?? 0,
      ];
      if (time == null ||
          fields.any((v) => !v.isFinite) ||
          fields.take(5).any((v) => v < 0 || v > 1)) {
        continue;
      }
      points.add(DjEnergyPoint(
        timeMs: time,
        value: fields[0],
        loudness: fields[1],
        bass: fields[2],
        mids: fields[3],
        highs: fields[4],
        slope: fields[5],
      ));
    }
    points.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return points;
  }

  DjSectionType _sectionType(String? value) {
    for (final type in DjSectionType.values) {
      if (type.name == value) return type;
    }
    return DjSectionType.unknown;
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
