// Tests for rail paging: the header arrows transition exactly one
// viewport page per press (not a fixed stride), clamped at both ends.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nixietube/ui/theme.dart'
    show railHeadingHeight, sectionHeaderGap;
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

/// A header beside a tall control, the way "Discover" carries a Play all
/// button: the control is built for the height it is given.
Future<void> _pumpHeader(
  WidgetTester tester, {
  required Size size,
  Widget Function(double height)? trailing,
  bool showArrows = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            RailHeader(
              title: 'Rail',
              controller: controller,
              trailing: trailing,
              showArrows: showArrows,
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

  testWidgets('paging clamps at the end instead of overshooting', (
    tester,
  ) async {
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

  testWidgets('a trailing button cannot make the heading taller', (
    tester,
  ) async {
    // Phone: no arrows, so the heading is exactly one line of title.
    await _pumpHeader(tester, size: const Size(400, 800));
    final plain = tester.getSize(find.byType(RailHeader)).height;

    await _pumpHeader(
      tester,
      size: const Size(400, 800),
      trailing: (height) => SizedBox(height: height, width: 80),
    );
    expect(tester.getSize(find.byType(RailHeader)).height, plain);
    // Which is a line of title plus the gap under it, not a 48dp row.
    expect(plain, lessThan(railHeadingHeight));
    expect(plain, greaterThan(sectionHeaderGap));
  });

  testWidgets('a desk heading is the arrows\' row, with or without a button', (
    tester,
  ) async {
    await _pumpHeader(tester, size: const Size(1200, 800));
    final arrows = tester.getSize(find.byType(RailHeader)).height;

    await _pumpHeader(
      tester,
      size: const Size(1200, 800),
      trailing: (height) => SizedBox(height: height, width: 80),
    );
    expect(tester.getSize(find.byType(RailHeader)).height, arrows);
    expect(arrows, closeTo(railHeadingHeight + sectionHeaderGap, 0.5));

    // A rail with nothing to scroll draws no arrows but keeps the same
    // row, so its heading is not shorter than the ones beside it.
    await _pumpHeader(tester, size: const Size(1200, 800), showArrows: false);
    expect(tester.getSize(find.byType(RailHeader)).height, arrows);
    expect(find.byTooltip('Scroll right'), findsNothing);
  });
}
