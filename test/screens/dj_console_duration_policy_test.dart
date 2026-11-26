import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/screens/dj_console_duration_policy.dart';

void main() {
  const policy = DjConsoleDurationPolicy();

  test('uses exact library duration shared with waveform storage', () {
    final resolved = policy.resolve(
      libraryDuration: const Duration(milliseconds: 238417),
      mediaDuration: const Duration(milliseconds: 238000),
    );
    expect(resolved.inMilliseconds, 238417);
  });

  test('uses native duration when library duration is unavailable', () {
    expect(
      policy.resolve(mediaDuration: const Duration(milliseconds: 181237)).inMilliseconds,
      181237,
    );
  });

  test('ignores zero duration sources', () {
    expect(
      policy.resolve(
        libraryDuration: Duration.zero,
        mediaDuration: Duration.zero,
      ),
      Duration.zero,
    );
  });
}
