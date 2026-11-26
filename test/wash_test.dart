// Tests for the Now Playing wash stops: bright palettes collapse toward
// the background (readable text), dark palettes keep their tint, and vivid
// covers are muted so they don't fight the accent.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/ui/widgets/palette_backdrop.dart'
    show ArtworkBackdrop, PaletteBackdrop, tameWashTint, washStop;

double lum(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

void main() {
  group('tameWashTint', () {
    test('a vivid red becomes a muted dark maroon', () {
      final tamed = tameWashTint(const Color(0xFFFF0000));
      final hsl = HSLColor.fromColor(tamed);
      expect(hsl.saturation, lessThan(0.4));
      expect(hsl.lightness, lessThanOrEqualTo(0.2));
      expect(tamed.r, greaterThan(tamed.b));
    });

    test('a vivid yellow becomes a dark olive', () {
      final tamed = tameWashTint(const Color(0xFFFFFF00));
      final hsl = HSLColor.fromColor(tamed);
      expect(hsl.saturation, lessThan(0.4));
      expect(hsl.lightness, lessThanOrEqualTo(0.2));
      expect(tamed.r, greaterThan(tamed.b));
      expect(tamed.g, greaterThan(tamed.b));
    });

    test('neutral and dark covers keep their color', () {
      const gray = Color(0xFF808080);
      const deep = Color(0xFF2A2A2A);
      expect(tameWashTint(gray), gray);
      expect(tameWashTint(deep), deep);
    });
  });

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
    testWidgets('renders a static gradient, never an animated one', (
      tester,
    ) async {
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

    testWidgets('a white cover collapses to the background', (tester) async {
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

    testWidgets('a vivid cover tames the tinted stop', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PaletteBackdrop(
              palette: List.filled(25, const Color(0xFFFF0000)),
            ),
          ),
        ),
      );
      final top = _embeddedGradient(tester).colors.first;
      final hsl = HSLColor.fromColor(top);
      // Still red, but muted and dark enough to sit behind the accent.
      expect(top.r, greaterThan(top.b));
      expect(hsl.saturation, lessThan(0.4));
      expect(hsl.lightness, lessThanOrEqualTo(0.2));
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

    testWidgets('crossfades between palettes on a song change', (tester) async {
      const red = Color(0xFF5C0E0E);
      const green = Color(0xFF0E5C2A);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: PaletteBackdrop(palette: List.filled(25, red))),
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

    testWidgets('short palettes fall back to a plain surface', (tester) async {
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

  group('ArtworkBackdrop', () {
    testWidgets(
      'requests its palette on mount and follows the URL when it changes after load',
      (tester) async {
        final cache = <String, List<Color>>{};
        final requested = <String?>[];
        final tick = ValueNotifier(0);
        var url = 'https://a/cover.jpg';

        Widget backdrop() => MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ArtworkBackdrop(
              artUrl: url,
              paletteFor: (u) => cache[u],
              ensurePalette: (u) async {
                requested.add(u);
                if (u != null && !cache.containsKey(u)) {
                  cache[u] = List<Color>.filled(25, const Color(0xFF5C0E0E));
                  tick.value++;
                }
                return cache[u];
              },
              tick: tick,
            ),
          ),
        );

        await tester.pumpWidget(backdrop());
        await tester.pump();
        // Missing palette requested for the mount-time URL.
        expect(requested, ['https://a/cover.jpg']);
        // ...and once computed, the gradient is painted.
        expect(
          find.descendant(
            of: find.byType(PaletteBackdrop),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).gradient != null,
            ),
          ),
          findsOneWidget,
        );

        // Loading finishes and the art URL changes (track covers
        // arrive): the backdrop must request the NEW URL instead of
        // going solid black.
        url = 'https://b/cover.jpg';
        await tester.pumpWidget(backdrop());
        await tester.pump();
        expect(requested, ['https://a/cover.jpg', 'https://b/cover.jpg']);
        expect(
          find.descendant(
            of: find.byType(PaletteBackdrop),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).gradient != null,
            ),
          ),
          findsOneWidget,
        );

        // A cached palette is not re-requested on rebuild.
        await tester.pumpWidget(backdrop());
        await tester.pump();
        expect(requested, ['https://a/cover.jpg', 'https://b/cover.jpg']);
      },
    );
  });
}

/// The gradient the embedded backdrop was built from.
LinearGradient _embeddedGradient(WidgetTester tester) {
  final box =
      find
              .descendant(
                of: find.byType(PaletteBackdrop),
                matching: find.byType(DecoratedBox),
              )
              .evaluate()
              .single
              .widget
          as DecoratedBox;
  return (box.decoration as BoxDecoration).gradient as LinearGradient;
}
