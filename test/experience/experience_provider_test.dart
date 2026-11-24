import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonate/experience/experience_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('first run requires a choice and persists Player selection', () async {
    final experience = ExperienceProvider();
    await experience.ready;

    expect(experience.isReady, isTrue);
    expect(experience.needsInitialSelection, isTrue);
    expect(experience.selected, isNull);

    await experience.selectInitialExperience(ResonateExperience.player);
    expect(experience.selected, ResonateExperience.player);
    expect(experience.needsInitialSelection, isFalse);

    final restored = ExperienceProvider();
    await restored.ready;
    expect(restored.selected, ResonateExperience.player);
  });

  test('persists Resonatix DJ selection independently of DJ feature settings',
      () async {
    final experience = ExperienceProvider();
    await experience.ready;
    await experience.selectInitialExperience(ResonateExperience.resonatixDj);

    final restored = ExperienceProvider();
    await restored.ready;
    expect(restored.selected, ResonateExperience.resonatixDj);
  });

  test('safe switch updates the selected experience and persists it', () async {
    final experience = ExperienceProvider();
    await experience.ready;
    await experience.selectInitialExperience(ResonateExperience.resonatixDj);

    await experience.switchExperience(ResonateExperience.player);

    expect(experience.selected, ResonateExperience.player);
    final restored = ExperienceProvider();
    await restored.ready;
    expect(restored.selected, ResonateExperience.player);
  });

  test('unknown stored values fail back to first-run selection', () async {
    SharedPreferences.setMockInitialValues({
      'resonate_selected_experience': 'unknown_mode',
    });
    final experience = ExperienceProvider();
    await experience.ready;

    expect(experience.needsInitialSelection, isTrue);
    expect(experience.selected, isNull);
  });

  test('does not allow selection to overwrite an established experience',
      () async {
    final experience = ExperienceProvider();
    await experience.ready;
    await experience.selectInitialExperience(ResonateExperience.player);

    await expectLater(
      experience.selectInitialExperience(ResonateExperience.resonatixDj),
      throwsStateError,
    );
    expect(experience.selected, ResonateExperience.player);
  });
}
