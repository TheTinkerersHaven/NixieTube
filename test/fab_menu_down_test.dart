// Tests for the downward-opening FAB menu port: the item
// stack must appear BELOW the trigger (the package's
// M3EFabMenu opens upward and would fly off the top of the
// screen from a header), and tapping an item fires it and
// closes the menu.

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nixietube/ui/widgets/fab_menu_down.dart';

Widget pumpMenu(
  WidgetTester tester, {
  required List<M3EFabMenuItem> items,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: M3EFabMenuDown(
          icon: const Icon(Icons.more_vert_rounded),
          closeIcon: const Icon(Icons.close_rounded),
          size: M3EFabSize.small,
          color: M3EFabColor.surface,
          position: M3EFabMenuPosition.right,
          items: items,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('items open downwards below the trigger', (tester) async {
    await tester.pumpWidget(
      pumpMenu(
        tester,
        items: const [
          M3EFabMenuItem(
            icon: Icon(Icons.link_rounded),
            label: 'Share link',
          ),
          M3EFabMenuItem(
            icon: Icon(Icons.open_in_new_rounded),
            label: 'Open in YouTube',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Items are hidden before the trigger is tapped.
    expect(find.text('Share link'), findsNothing);
    // The trigger BOX (40dp), not the 24dp glyph inside it.
    final trigger = tester.getRect(find.byType(M3EFab));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    // Staggered reveal (2 items, 35 ms apart) plus the spring
    // settle for the width-factor animation.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(find.text('Share link'), findsOneWidget);
    expect(find.text('Open in YouTube'), findsOneWidget);

    // The pill (closest Material ancestor of the label), not
    // the text glyph: the glyph is inset by the item padding.
    final pill = tester.getRect(
      find
          .ancestor(
            of: find.text('Share link'),
            matching: find.byType(Material),
          )
          .first,
    );
    // The whole stack hangs BELOW the trigger — the fix for
    // the upward-opening original.
    expect(pill.top, greaterThanOrEqualTo(trigger.bottom));
    // Right position: pills end-align with the trigger's
    // right edge (a header menu anchored top-right).
    expect(pill.right, lessThanOrEqualTo(trigger.right + 1));
    expect(pill.right, greaterThan(trigger.center.dx));
  });

  testWidgets('tapping an item fires it and closes the menu',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      pumpMenu(
        tester,
        items: [
          const M3EFabMenuItem(
            icon: Icon(Icons.link_rounded),
            label: 'Share link',
          ),
          M3EFabMenuItem(
            icon: const Icon(Icons.open_in_new_rounded),
            label: 'Open in YouTube',
            onPressed: () => tapped++,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open in YouTube'));
    await tester.pumpAndSettle();

    expect(tapped, 1);
    // Menu closed again after the tap.
    expect(find.text('Open in YouTube'), findsNothing);
    // Trigger switched back to the expand icon.
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
  });

  testWidgets('tapping outside closes the menu', (tester) async {
    await tester.pumpWidget(
      pumpMenu(
        tester,
        items: const [
          M3EFabMenuItem(
            icon: Icon(Icons.link_rounded),
            label: 'Share link',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Share link'), findsOneWidget);

    // Tap a point away from the trigger and the item (the
    // translucent overlay tap-catcher closes the menu).
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.text('Share link'), findsNothing);
  });

  testWidgets('clicking away collapses instead of vanishing',
      (tester) async {
    await tester.pumpWidget(
      pumpMenu(
        tester,
        items: const [
          M3EFabMenuItem(
            icon: Icon(Icons.link_rounded),
            label: 'Share link',
          ),
          M3EFabMenuItem(
            icon: Icon(Icons.open_in_new_rounded),
            label: 'Open in YouTube',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Share link'), findsOneWidget);

    // Click away: mid-collapse the pills are still mounted
    // (shrinking), only settling away afterwards.
    await tester.tapAt(const Offset(10, 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Share link'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Share link'), findsNothing);
    // Trigger switched back to the expand icon.
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
  });
}
