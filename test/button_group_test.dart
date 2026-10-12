// M3E connected toggle-button group tests: options render, taps
// report the tapped index, and the group keeps a constant width
// across selections.

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

Future<void> pumpGroup(
  WidgetTester tester, {
  required int? selectedIndex,
  required ValueChanged<int?> onChanged,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: M3EToggleButtonGroup(
            type: M3EButtonGroupType.connected,
            size: M3EButtonSize.sm,
            selectedIndex: selectedIndex,
            onSelectedIndexChanged: onChanged,
            actions: const [
              M3EToggleButtonGroupAction(label: Text('Alpha')),
              M3EToggleButtonGroupAction(label: Text('Beta')),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders every option and reports taps', (tester) async {
    int? selected = 0;
    await pumpGroup(
      tester,
      selectedIndex: selected,
      onChanged: (v) => selected = v,
    );
    // Each label is mounted twice (label + checkedLabel cross-fade).
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsWidgets);
    await tester.tap(find.byType(M3EToggleButton).at(1));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('tapping the selected option emits null (deselect)',
      (tester) async {
    int? selected = 0;
    var calls = 0;
    await pumpGroup(
      tester,
      selectedIndex: selected,
      onChanged: (v) {
        calls++;
        selected = v;
      },
    );
    await tester.tap(find.byType(M3EToggleButton).at(0));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(selected, isNull);
  });

  testWidgets('overall width is identical for either selection',
      (tester) async {
    await pumpGroup(tester, selectedIndex: 0, onChanged: (_) {});
    await tester.pumpAndSettle();
    final widthA =
        tester.getSize(find.byType(M3EToggleButtonGroup)).width;
    await pumpGroup(tester, selectedIndex: 1, onChanged: (_) {});
    await tester.pumpAndSettle();
    final widthB =
        tester.getSize(find.byType(M3EToggleButtonGroup)).width;
    expect(widthA, greaterThan(0));
    expect(widthB, widthA);
  });
}
