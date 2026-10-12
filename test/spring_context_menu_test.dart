// Tests for the spring context menu: items unfold near the cursor,
// tapping one returns its value and closes, disabled rows stay put.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nixietube/ui/widgets/spring_context_menu.dart';

Future<String?> _openMenu(
  WidgetTester tester, {
  bool disableFirst = false,
}) {
  return showSpringMenu<String>(
    context: tester.element(find.text('open')),
    position: const Offset(10, 10),
    items: [
      SpringMenuItem(
        icon: const Icon(Icons.playlist_play_rounded),
        label: 'Play next',
        value: 'next',
        enabled: !disableFirst,
      ),
      const SpringMenuItem(
        icon: Icon(Icons.delete_outline_rounded),
        label: 'Remove from queue',
        value: 'remove',
      ),
    ],
  );
}

void main() {
  Future<void> pumpOpener(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final selected = await _openMenu(tester);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('picked $selected')),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tapping an item returns its value and closes',
      (tester) async {
    await pumpOpener(tester);
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Remove from queue'), findsOneWidget);

    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();

    expect(find.text('Remove from queue'), findsNothing);
    expect(find.text('picked remove'), findsOneWidget);
  });

  testWidgets('a disabled item cannot be picked', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => _openMenu(tester, disableFirst: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();

    // Still open, nothing picked.
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Remove from queue'), findsOneWidget);
  });

  testWidgets('clicking away collapses like the title menu',
      (tester) async {    await pumpOpener(tester);
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);

    // Click away from the pills: mid-collapse the rows are still
    // mounted and shrinking, only settling away afterwards.
    await tester.tapAt(const Offset(400, 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Play next'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsNothing);
  });

  testWidgets('a second menu supersedes the open one', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                // Two rapid right-clicks: the first menu must not
                // linger underneath the second.
                showSpringMenu<String>(
                  context: context,
                  position: const Offset(10, 10),
                  items: const [
                    SpringMenuItem(
                      icon: Icon(Icons.playlist_play_rounded),
                      label: 'First menu item',
                      value: 'first',
                    ),
                  ],
                );
                showSpringMenu<String>(
                  context: context,
                  position: const Offset(10, 10),
                  items: const [
                    SpringMenuItem(
                      icon: Icon(Icons.delete_outline_rounded),
                      label: 'Second menu item',
                      value: 'second',
                    ),
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Second menu item'), findsOneWidget);
    expect(find.text('First menu item'), findsNothing);
  });
}
