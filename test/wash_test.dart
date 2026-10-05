// Tests for the Now Playing wash stops: bright palettes collapse toward
// the background (readable text), dark palettes keep their tint.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/ui/widgets/palette_backdrop.dart'
    show PaletteBackdrop, washStop;

double lum(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

void main() {
  group('washStop', () {
    const bg = Color(0xFF131314);

    test('white palette collapses near background', () {
      final stop = washStop(const Color(0xFFFFFFFF), 0.22, bg);
      expect(lum(stop), lessThan(0.22));
    });

    test('bright yellow stays readable', () {
      final stop = washStop(const Color(0xFFFFFF00), 0.22, bg);
      expect(lum(stop), lessThan(0.30));
    });

    test('dark palette keeps its tint', () {
      const deep = Color(0xFF5C0E0E);
      final stop = washStop(deep, 0.22, bg);
      // Still redder than the neutral background mix.
      expect(stop.r, greaterThan(stop.b));
      expect(lum(stop), lessThan(0.25));
    });
  });

  group('PaletteBackdrop', () {
    testWidgets('renders a static gradient, never an animated one',
        (tester) async {
      // The wash must snap: animating a fullscreen backdrop
      // repaints the whole layer every frame, which is pure
      // raster load.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaletteBackdrop(
              palette: List.filled(25, const Color(0xFF5C0E0E)),
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(PaletteBackdrop),
          matching: find.byType(DecoratedBox),
        ),
        findsOneWidget,
      );
      expect(find.byType(AnimatedContainer), findsNothing);
    });

    testWidgets('a white cover collapses to the background', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PaletteBackdrop(
              palette: List.filled(25, const Color(0xFFFFFFFF)),
            ),
          ),
        ),
      );
      final stops = _embeddedGradient(tester).colors;
      expect(stops.length, 5);
      // Every stop washed out: no band stays bright
      // enough to wash out text.
      for (final stop in stops) {
        expect(lum(stop), lessThan(0.15));
      }
    });

    testWidgets('a dark cover keeps its tint', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PaletteBackdrop(
              palette: List.filled(25, const Color(0xFF5C0E0E)),
            ),
          ),
        ),
      );
      final top = _embeddedGradient(tester).colors.first;
      // Washed toward the background, but still redder
      // than it (the cover's tint survives the blur).
      expect(top.r, greaterThan(top.b));
      expect(lum(top), lessThan(0.25));
    });

    testWidgets('the wash ramps toward the bottom', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PaletteBackdrop(
              palette: List.filled(25, const Color(0xFF5C0E0E)),
            ),
          ),
        ),
      );
      final stops = _embeddedGradient(tester).colors;
      const backdrop = Color(0xFF121212);
      double dist(Color c) =>
          (c.r - backdrop.r).abs() + (c.b - backdrop.b).abs();
      // The bottom stop is washed hardest, so it sits
      // closest to the background.
      expect(dist(stops.last), lessThan(dist(stops.first)));
    });

    testWidgets('crossfades between palettes on a song change', (
      tester,
    ) async {
      const red = Color(0xFF5C0E0E);
      const green = Color(0xFF0E5C2A);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PaletteBackdrop(palette: List.filled(25, red)),
          ),
        ),
      );
      final start = _embeddedGradient(tester).colors.first;
      // The song changes: the palette becomes a green cover.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PaletteBackdrop(palette: List.filled(25, green)),
          ),
        ),
      );
      // Halfway through the 600ms wash the top stop is a
      // blend: red fading out, green fading in.
      await tester.pump(PaletteBackdrop.paletteWash ~/ 2);
      final mid = _embeddedGradient(tester).colors.first;
      expect(mid.r, lessThan(start.r)); // red fading out
      expect(mid.g, greaterThan(start.g)); // green fading in
      // And the wash settles on the new cover, not a blend.
      await tester.pumpAndSettle();
      final end = _embeddedGradient(tester).colors.first;
      expect(end.g, greaterThan(end.r)); // the green cover won
      expect(end.g, greaterThan(mid.g)); // settled past the halfway blend
    });

    testWidgets('short palettes fall back to a plain surface', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PaletteBackdrop(palette: [])),
        ),
      );
      // No gradient is painted…
      expect(
        find.descendant(
          of: find.byType(PaletteBackdrop),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      // …only the opaque surface fallback.
      expect(
        find.descendant(
          of: find.byType(PaletteBackdrop),
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color.a == 1.0,
          ),
        ),
        findsOneWidget,
      );
    });
  });
}

/// The gradient the embedded backdrop was built from.
LinearGradient _embeddedGradient(WidgetTester tester) {
  final box = find.descendant(
    of: find.byType(PaletteBackdrop),
    matching: find.byType(DecoratedBox),
  ).evaluate().single.widget as DecoratedBox;
  return (box.decoration as BoxDecoration).gradient as LinearGradient;
}
