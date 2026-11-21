import 'package:flutter_test/flutter_test.dart';
import '../../lib/services/dj_analysis_service.dart';

void main() {
  group('DJ analysis window plan', () {
    test('samples intro, two body positions, and outro on long tracks', () {
      expect(
        DjAnalysisService.analysisWindowStartPositions(180000),
        <int>[0, 59400, 118800, 172000],
      );
    });

    test('uses two separated windows for short tracks', () {
      expect(
        DjAnalysisService.analysisWindowStartPositions(10000),
        <int>[0, 2000],
      );
    });

    test('does not schedule windows for unknown duration', () {
      expect(DjAnalysisService.analysisWindowStartPositions(0), isEmpty);
    });
  });
}
