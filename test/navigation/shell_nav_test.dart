import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/navigation/shell_nav.dart';

void main() {
  test('defaults Player navigation to the existing Player shell tab', () {
    final nav = ShellNav();
    final selected = <int>[];
    nav.bind(selected.add);

    nav.goToPlayer();

    expect(selected, <int>[2]);
  });

  test('supports a different Player destination in the DJ shell', () {
    final nav = ShellNav();
    final selected = <int>[];
    nav.bind(selected.add, playerTabIndex: 0);

    nav.goToTab(1);
    nav.goToPlayer();

    expect(selected, <int>[1, 0]);
  });

  test('uses the explicit experience handoff instead of a local tab', () async {
    final nav = ShellNav();
    var switched = false;
    nav.bind((_) {}, playerTabIndex: 0, onSwitchToPlayer: () async {
      switched = true;
    });

    await nav.switchToPlayer();

    expect(switched, isTrue);
  });

  test('unbind prevents stale shell navigation callbacks', () {
    final nav = ShellNav();
    final selected = <int>[];
    nav.bind(selected.add, playerTabIndex: 0);
    nav.unbind();

    nav.goToPlayer();
    nav.goToTab(1);

    expect(selected, isEmpty);
  });
}
