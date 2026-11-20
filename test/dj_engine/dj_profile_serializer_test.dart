import 'package:flutter_test/flutter_test.dart';

import 'package:resonate/dj_engine/analysis/dj_profile_serializer.dart';
import 'package:resonate/dj_engine/core/dj_types.dart';

void main() {
  test('V2 profile round-trips rich transition data', () {
    const original = DjTrackProfile(
      songId: 'round-trip',
      durationMs: 180000,
      fingerprint: 'fingerprint',
      beatGrid: DjBeatGrid(
        bpm: 124,
        confidence: 0.82,
        firstBeatMs: 320,
        beatMs: [320, 804, 1288],
        beatsPerBar: 4,
        beatsPerPhrase: 16,
      ),
      keyRoot: 7,
      keyMode: 'minor',
      keyConfidence: 0.74,
      harmonicChanges: [
        DjTimePoint(90000, confidence: 0.6),
      ],
      sections: [
        DjSection(
          type: DjSectionType.breakdown,
          startMs: 60000,
          endMs: 75000,
          confidence: 0.7,
          energy: 0.3,
        ),
      ],
      energyCurve: [
        DjEnergyPoint(
          timeMs: 60000,
          value: 0.4,
          loudness: 0.5,
          bass: 0.3,
          mids: 0.5,
          highs: 0.6,
        ),
      ],
      dspAnalysis: DspAnalysisMetrics(
        samplePeakDb: -1.2,
        truePeakDb: -0.8,
        rmsDb: -12.4,
        crestDb: 11.2,
        bassEnergyDb: -18.5,
      ),
      spectrum: DjSpectralProfile(
        bass: 0.7,
        mids: 0.6,
        highs: 0.5,
        centroid: 0.42,
        bassDensity: 0.65,
        spectralFlux: 0.22,
        confidence: 0.5,
      ),
      silenceRegions: [
        DjSilenceRegion(
          startMs: 168000,
          endMs: 172000,
          minimumDbfs: -84,
          confidence: 0.88,
        ),
      ],
      transitions: DjTransitionMarkers(
        bestIntroMs: 12000,
        bestOutroMs: 166000,
        safeMixIns: [DjTimePoint(12000, confidence: 0.8)],
        safeMixOuts: [DjTimePoint(166000, confidence: 0.8)],
        riskyPoints: [DjTimePoint(60000, confidence: 0.7)],
      ),
      analysisConfidence: 0.71,
      analysisVersion: 6,
    );

    final serializer = const DjProfileSerializer();
    final decoded = serializer.decode(serializer.encode(original));

    expect(decoded.songId, original.songId);
    expect(decoded.durationMs, original.durationMs);
    expect(decoded.beatGrid.bpm, original.beatGrid.bpm);
    expect(decoded.beatGrid.beatMs, original.beatGrid.beatMs);
    expect(decoded.keyRoot, original.keyRoot);
    expect(decoded.keyMode, original.keyMode);
    expect(decoded.sections.single.type, DjSectionType.breakdown);
    expect(decoded.energyCurve.single.bass, 0.3);
    expect(decoded.spectrum.bassDensity, 0.65);
    expect(decoded.dspAnalysis.samplePeakDb, -1.2);
    expect(decoded.dspAnalysis.truePeakDb, -0.8);
    expect(decoded.dspAnalysis.rmsDb, -12.4);
    expect(decoded.dspAnalysis.crestDb, 11.2);
    expect(decoded.dspAnalysis.bassEnergyDb, -18.5);
    expect(decoded.transitions.bestOutroMs, 166000);
    expect(decoded.transitions.safeMixIns.single.timeMs, 12000);
    expect(decoded.transitions.safeMixOuts.single.timeMs, 166000);
    expect(decoded.silenceRegions.single.startMs, 168000);
    expect(decoded.silenceRegions.single.durationMs, 4000);
    expect(decoded.silenceRegions.single.confidence, 0.88);
    expect(decoded.transitions.riskyPoints.single.timeMs, 60000);
  });

  test('older profiles decode without optional silence metadata', () {
    const serializer = DjProfileSerializer();
    final decoded = serializer.decode('{"songId":"legacy","durationMs":120000}');
    expect(decoded.songId, 'legacy');
    expect(decoded.silenceRegions, isEmpty);
    expect(decoded.dspAnalysis.isMeasured, isFalse);
    expect(decoded.dspAnalysis.samplePeakDb, -160);
  });

  test('drops malformed and out-of-range profile timeline data', () {
    const serializer = DjProfileSerializer();
    final decoded = serializer.decode('''
      {
        "songId": "guarded",
        "durationMs": 180000,
        "beatGrid": {
          "beatMs": [320, 804, 804, -10, 181000, 1288],
          "downbeatMs": [320, 1288, 1200],
          "firstBeatMs": 181000
        },
        "sections": [
          {"type": "intro", "startMs": 0, "endMs": 12000, "confidence": 0.8, "energy": 0.4},
          {"type": "outro", "startMs": 170000, "endMs": 190000, "confidence": 0.8, "energy": 0.4},
          {"type": "drop", "startMs": 50000, "endMs": 60000, "confidence": 1.4, "energy": 0.8}
        ],
        "energyCurve": [
          {"timeMs": 1000, "value": 0.5, "bass": 0.4},
          {"timeMs": 181000, "value": 0.5}
        ],
        "silenceRegions": [
          {"startMs": 170000, "endMs": 174000, "minimumDbfs": -80, "confidence": 0.9},
          {"startMs": 175000, "endMs": 185000, "minimumDbfs": -80, "confidence": 0.9},
          {"startMs": 176000, "endMs": 177000, "minimumDbfs": 12, "confidence": 0.9}
        ],
        "transitions": {
          "bestIntroMs": -1,
          "bestOutroMs": 181000,
          "safeMixIns": [
            {"timeMs": 2000, "confidence": 0.8},
            {"timeMs": 181000, "confidence": 0.8}
          ],
          "safeMixOuts": [],
          "riskyPoints": [{"timeMs": 5000, "confidence": 2.0}]
        }
      }
    ''');

    expect(decoded.beatGrid.firstBeatMs, isNull);
    expect(decoded.beatGrid.beatMs, [320, 804, 1288]);
    expect(decoded.beatGrid.downbeatMs, [320, 1288]);
    expect(decoded.sections, hasLength(1));
    expect(decoded.energyCurve, hasLength(1));
    expect(decoded.silenceRegions, hasLength(1));
    expect(decoded.transitions.bestIntroMs, isNull);
    expect(decoded.transitions.bestOutroMs, isNull);
    expect(decoded.transitions.safeMixIns.map((p) => p.timeMs), [2000]);
    expect(decoded.transitions.riskyPoints, isEmpty);
  });

  test('sorts valid timeline collections into chronological order', () {
    const serializer = DjProfileSerializer();
    final decoded = serializer.decode('''
      {
        "songId": "ordered",
        "durationMs": 60000,
        "harmonicChanges": [
          {"timeMs": 30000, "confidence": 0.8},
          {"timeMs": 10000, "confidence": 0.7}
        ],
        "energyCurve": [
          {"timeMs": 30000, "value": 0.7},
          {"timeMs": 10000, "value": 0.3}
        ]
      }
    ''');

    expect(decoded.harmonicChanges.map((p) => p.timeMs), [10000, 30000]);
    expect(decoded.energyCurve.map((p) => p.timeMs), [10000, 30000]);
  });


  test('sanitizes invalid scalar profile metadata without losing the profile', () {
    const serializer = DjProfileSerializer();
    final decoded = serializer.decode('''
      {
        "songId": "scalar-guard",
        "durationMs": -900,
        "analysisConfidence": 1.7,
        "beatGrid": {
          "bpm": 999,
          "confidence": -0.2,
          "beatsPerBar": 0,
          "beatsPerPhrase": 1000,
          "downbeatConfidence": 1.4,
          "barConfidence": "bad",
          "phraseConfidence": 0.6
        },
        "keyRoot": 14,
        "keyConfidence": "NaN",
        "spectrum": {
          "bass": 1.8,
          "mids": -0.4,
          "highs": 0.7,
          "centroid": "bad",
          "bassDensity": 0.4,
          "spectralFlux": 2.0,
          "confidence": -1
        }
      }
    ''');

    expect(decoded.durationMs, isNull);
    expect(decoded.analysisConfidence, 0);
    expect(decoded.beatGrid.bpm, isNull);
    expect(decoded.beatGrid.confidence, 0);
    expect(decoded.beatGrid.beatsPerBar, 4);
    expect(decoded.beatGrid.beatsPerPhrase, 16);
    expect(decoded.beatGrid.downbeatConfidence, 0);
    expect(decoded.beatGrid.barConfidence, 0);
    expect(decoded.beatGrid.phraseConfidence, 0.6);
    expect(decoded.keyRoot, isNull);
    expect(decoded.keyConfidence, 0);
    expect(decoded.spectrum.bass, 0.5);
    expect(decoded.spectrum.mids, 0.5);
    expect(decoded.spectrum.highs, 0.7);
    expect(decoded.spectrum.centroid, 0.5);
    expect(decoded.spectrum.bassDensity, 0.4);
    expect(decoded.spectrum.spectralFlux, 0.5);
    expect(decoded.spectrum.confidence, 0);
  });

}
