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
        'dspAnalysis': {
          'samplePeakDb': profile.dspAnalysis.samplePeakDb,
          'truePeakDb': profile.dspAnalysis.truePeakDb,
          'rmsDb': profile.dspAnalysis.rmsDb,
          'crestDb': profile.dspAnalysis.crestDb,
          'bassEnergyDb': profile.dspAnalysis.bassEnergyDb,
          'maxSafeBassDb': profile.dspAnalysis.maxSafeBassDb,
        },
        'spectrum': {
          'bass': profile.spectrum.bass,
          'mids': profile.spectrum.mids,
          'highs': profile.spectrum.highs,
          'centroid': profile.spectrum.centroid,
          'bassDensity': profile.spectrum.bassDensity,
          'spectralFlux': profile.spectrum.spectralFlux,
          'confidence': profile.spectrum.confidence,
        },
        'waveformSegments': profile.waveformSegments
            .map((segment) => {
                  'startMs': segment.startMs,
                  'endMs': segment.endMs,
                  'peaks': segment.peaks,
                })
            .toList(),
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
    final rawDuration = map['durationMs'];
    final durationMs = rawDuration is num && rawDuration.isFinite && rawDuration > 0
        ? rawDuration.toInt()
        : null;
    final beat = _map(map['beatGrid']);
    final spectrum = _map(map['spectrum']);
    final dsp = _map(map['dspAnalysis']);
    final transition = _map(map['transitions']);
    return DjTrackProfile(
      songId: map['songId'] as String,
      durationMs: durationMs,
      fingerprint: map['fingerprint'] as String?,
      analysisVersion: (map['analysisVersion'] as num?)?.toInt() ?? 1,
      analysisConfidence: _unit(map['analysisConfidence'], fallback: 0),
      beatGrid: DjBeatGrid(
        bpm: _bpm(beat['bpm']),
        confidence: _unit(beat['confidence'], fallback: 0),
        firstBeatMs: _time(beat['firstBeatMs'], durationMs),
        beatMs: _orderedTimes(beat['beatMs'], durationMs),
        beatsPerBar: _boundedInt(beat['beatsPerBar'], 1, 12, 4),
        beatsPerPhrase: _boundedInt(beat['beatsPerPhrase'], 1, 64, 16),
        downbeatMs: _orderedTimes(beat['downbeatMs'], durationMs),
        downbeatConfidence: _unit(beat['downbeatConfidence'], fallback: 0),
        barConfidence: _unit(beat['barConfidence'], fallback: 0),
        phraseConfidence: _unit(beat['phraseConfidence'], fallback: 0),
      ),
      keyRoot: _keyRoot(map['keyRoot']),
      keyMode: map['keyMode'] as String?,
      keyConfidence: _unit(map['keyConfidence'], fallback: 0),
      harmonicChanges: _points(map['harmonicChanges'], durationMs),
      sections: _sections(map['sections'], durationMs),
      energyCurve: _energy(map['energyCurve'], durationMs),
      dspAnalysis: _dspAnalysis(dsp),
      spectrum: DjSpectralProfile(
        bass: _unit(spectrum['bass'], fallback: 0.5),
        mids: _unit(spectrum['mids'], fallback: 0.5),
        highs: _unit(spectrum['highs'], fallback: 0.5),
        centroid: _unit(spectrum['centroid'], fallback: 0.5),
        bassDensity: _unit(spectrum['bassDensity'], fallback: 0.5),
        spectralFlux: _unit(spectrum['spectralFlux'], fallback: 0.5),
        confidence: _unit(spectrum['confidence'], fallback: 0),
      ),
      silenceRegions: _silenceRegions(map['silenceRegions'], durationMs),
      waveformSegments: _waveformSegments(map['waveformSegments'], durationMs),
      transitions: DjTransitionMarkers(
        bestIntroMs: _time(transition['bestIntroMs'], durationMs),
        bestOutroMs: _time(transition['bestOutroMs'], durationMs),
        safeMixIns: _points(transition['safeMixIns'], durationMs),
        safeMixOuts: _points(transition['safeMixOuts'], durationMs),
        riskyPoints: _points(transition['riskyPoints'], durationMs),
      ),
    );
  }

  DspAnalysisMetrics _dspAnalysis(Map<String, dynamic> map) {
    double level(String key, double fallback, double min, double max) {
      final value = map[key];
      if (value is! num || !value.isFinite || value < min || value > max) return fallback;
      return value.toDouble();
    }
    return DspAnalysisMetrics(
      samplePeakDb: level('samplePeakDb', -160, -160, 6),
      truePeakDb: level('truePeakDb', -160, -160, 6),
      rmsDb: level('rmsDb', -160, -160, 0.1),
      crestDb: level('crestDb', 0, 0, 30),
      bassEnergyDb: level('bassEnergyDb', -160, -160, 0.1),
      maxSafeBassDb: map['maxSafeBassDb'] is num &&
              (map['maxSafeBassDb'] as num).isFinite &&
              (map['maxSafeBassDb'] as num) >= 0 &&
              (map['maxSafeBassDb'] as num) <= 18
          ? (map['maxSafeBassDb'] as num).toDouble()
          : null,
    );
  }

  double _unit(dynamic value, {required double fallback}) {
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      return fallback;
    }
    return value.toDouble();
  }

  double? _bpm(dynamic value) {
    if (value is! num || !value.isFinite) return null;
    final bpm = value.toDouble();
    return bpm > 40 && bpm < 240 ? bpm : null;
  }

  int _boundedInt(dynamic value, int min, int max, int fallback) {
    if (value is! num || !value.isFinite || value != value.round() ||
        value < min || value > max) {
      return fallback;
    }
    return value.toInt();
  }

  int? _keyRoot(dynamic value) {
    if (value is! num || !value.isFinite || value != value.round() ||
        value < 0 || value > 11) {
      return null;
    }
    return value.toInt();
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

  List<DjWaveformSegment> _waveformSegments(
    dynamic value,
    int? durationMs,
  ) {
    if (value is! List || durationMs == null || durationMs <= 0) {
      return const [];
    }
    final segments = <DjWaveformSegment>[];
    for (final raw in value.take(32).whereType<Map>()) {
      final start = _time(raw['startMs'], durationMs);
      final end = _time(raw['endMs'], durationMs);
      final rawPeaks = raw['peaks'];
      if (start == null ||
          end == null ||
          end <= start ||
          rawPeaks is! List ||
          rawPeaks.isEmpty ||
          rawPeaks.length > 256) {
        continue;
      }
      final peaks = <double>[];
      var valid = true;
      for (final item in rawPeaks) {
        if (item is! num ||
            !item.isFinite ||
            item < 0 ||
            item > 1) {
          valid = false;
          break;
        }
        peaks.add(item.toDouble());
      }
      if (!valid) continue;
      segments.add(DjWaveformSegment(
        startMs: start,
        endMs: end,
        peaks: peaks,
      ));
    }
    segments.sort((a, b) => a.startMs.compareTo(b.startMs));
    return segments;
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
