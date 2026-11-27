import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/screens/dsp_live_meter_policy.dart';

void main() {
  group('DspLiveMeterSnapshot', () {
    test('keeps independent native readings for A and B and marks native focus', () {
      final snapshot = DspLiveMeterSnapshot.fromNativeStatus({
        'activeDeckId': 'B',
        'activeEngines': 2,
        'liveMetersByDeck': {
          'A': {'inputPeakDb': -8.5, 'autoPreampAppliedDb': -2.0},
          'B': {'inputPeakDb': -3.25, 'limiterGrDb': 1.5},
        },
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.activeDeckId, 'B');
      expect(snapshot.decks.keys, containsAll(['A', 'B']));
      expect(snapshot.decks['A']!.inputPeakDb, -8.5);
      expect(snapshot.decks['A']!.autoPreampAppliedDb, -2.0);
      expect(snapshot.decks['B']!.inputPeakDb, -3.25);
      expect(snapshot.decks['B']!.limiterGrDb, 1.5);
      expect(snapshot.decks['A']!.limiterGrDb, isNull);
    });

    test('does not manufacture readings from config or absent native meters', () {
      expect(
        DspLiveMeterSnapshot.fromNativeStatus({
          'activeEngines': 1,
          'autoBassTargetDb': 6.0,
          'autoPreampTargetDb': -3.0,
        }),
        isNull,
      );
      expect(
        DspLiveMeterSnapshot.fromNativeStatus({
          'liveMetersByDeck': {
            'A': {'inputPeakDb': double.nan, 'shortTermRmsDb': 'not-a-number'},
            'B': {},
          },
        }),
        isNull,
      );
      expect(DspLiveMeterSnapshot.fromNativeStatus(null), isNull);
    });

    test('preserves negative applied gain values and non-negative limiter reduction', () {
      final snapshot = DspLiveMeterSnapshot.fromNativeStatus({
        'liveMetersByDeck': {
          'A': {
            'autoBassAppliedDb': 3.25,
            'autoGainAppliedDb': -4.5,
            'autoPreampAppliedDb': -1.75,
            'limiterGrDb': 0.8,
          },
        },
      });

      final deck = snapshot!.decks['A']!;
      expect(deck.autoBassAppliedDb, 3.25);
      expect(deck.autoGainAppliedDb, -4.5);
      expect(deck.autoPreampAppliedDb, -1.75);
      expect(deck.limiterGrDb, 0.8);
    });

    test('normalizes dBFS and signed gains without changing source readings', () {
      expect(DspLiveMeterSnapshot.normalizeDbfs(-60), 0);
      expect(DspLiveMeterSnapshot.normalizeDbfs(-30), 0.5);
      expect(DspLiveMeterSnapshot.normalizeDbfs(0), 1);
      expect(DspLiveMeterSnapshot.normalizeDbfs(-90), 0);
      expect(DspLiveMeterSnapshot.normalizeSignedDb(-12), 0);
      expect(DspLiveMeterSnapshot.normalizeSignedDb(0), 0.5);
      expect(DspLiveMeterSnapshot.normalizeSignedDb(12), 1);
      expect(DspLiveMeterSnapshot.normalizeSignedDb(-3), 0.375);
    });
  });
}
