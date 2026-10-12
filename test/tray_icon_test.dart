// Tests for the dynamic tray icon: the SVG path parser covers the
// command subset M3E shape data uses, and the renderer emits a valid
// PNG whose pixels actually differ with the theme colors.

import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:m3e_core/m3e_core.dart' show Shapes;
import 'package:nixietube/sys/tray_icon.dart';

void main() {
  test('cookie path parses to a centered, squarish outline', () {
    final path = parseSvgPath(Shapes.c6SidedCookie.svg);
    final bounds = path.getBounds();
    expect(bounds.width, greaterThan(200));
    expect(bounds.height, greaterThan(200));
    // Roughly square viewBox, roughly centered on itself.
    expect(
      (bounds.width - bounds.height).abs(),
      lessThan(bounds.width * 0.1),
    );
    expect(bounds.left, greaterThan(0));
    expect(bounds.top, greaterThan(0));
  });

  test('relative commands resolve against the cursor', () {
    final path = parseSvgPath('M10 10l20 0l0 20z');
    final bounds = path.getBounds();
    expect(bounds.left, 10);
    expect(bounds.top, 10);
    expect(bounds.width, 20);
    expect(bounds.height, 20);
  });

  testWidgets('rendered icon is a valid PNG in theme colors',
      (tester) async {
    final bytes = await tester.runAsync(
      () => renderTrayIcon(
        background: const Color(0xFFE7BDB7),
        foreground: const Color(0xFF4A2C28),
      ),
    );
    final image = img.decodePng(Uint8List.fromList(bytes!));
    expect(image, isNotNull);
    expect(image!.width, 64);
    expect(image.height, 64);
    // Pentagon fill present: sample well inside the shape.
    final fill = image.getPixel(32, 20);
    expect(fill.r.toInt(), greaterThan(200));
    // Play glyph present: center pixel is the dark foreground.
    final glyph = image.getPixel(32, 32);
    expect(glyph.r.toInt(), lessThan(120));
  });

  testWidgets('different themes render different icons', (tester) async {
    final a = await tester.runAsync(
      () => renderTrayIcon(
        background: const Color(0xFFFF0000),
        foreground: const Color(0xFFFFFFFF),
      ),
    );
    final b = await tester.runAsync(
      () => renderTrayIcon(
        background: const Color(0xFF0000FF),
        foreground: const Color(0xFF000000),
      ),
    );
    expect(a, isNot(equals(b)));
  });
}
