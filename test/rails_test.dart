// Tests for rail paging: the header arrows transition exactly one
// viewport page per press (not a fixed stride), clamped at both ends.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nixietube/ui/widgets/rails.dart';

Future<void> _pumpRail(WidgetTester tester, ScrollController controller) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            RailHeader(title: 'Rail', controller: controller),
            SizedBox(
              height: 100,
              width: 400,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                controller: controller,
                itemCount: 20,
                itemBuilder: (context, i) =>
                    const SizedBox(width: 200, height: 100),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('arrows move exactly one viewport page', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pumpRail(tester, controller);

    await tester.tap(find.byTooltip('Scroll right'));
    await tester.pumpAndSettle();
    expect(controller.offset, 400);

    await tester.tap(find.byTooltip('Scroll right'));
    await tester.pumpAndSettle();
    expect(controller.offset, 800);

    await tester.tap(find.byTooltip('Scroll left'));
    await tester.pumpAndSettle();
    expect(controller.offset, 400);
  });

  testWidgets('paging clamps at the end instead of overshooting',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pumpRail(tester, controller);

    // 20 × 200px cards in a 400px viewport: max extent is 3600.
    for (var i = 0; i < 20; i++) {
      await tester.tap(find.byTooltip('Scroll right'));
      await tester.pumpAndSettle();
    }
    expect(controller.offset, 3600);

    await tester.tap(find.byTooltip('Scroll left'));
    await tester.pumpAndSettle();
    expect(controller.offset, 3200);
  });
}
