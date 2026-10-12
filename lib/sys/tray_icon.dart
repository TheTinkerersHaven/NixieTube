// Dynamically rendered app icon: the M3 Expressive 6-sided cookie
// shape (same SVG path data as [Shapes.c6SidedCookie]) filled with
// the app's primary color and a play glyph in on-primary. Rendered
// for the tray icon and the window icon, and re-rendered whenever
// the theme changes, so both always match the app.

import 'dart:math' show max;
import 'dart:typed_data' show Uint8List;
import 'dart:ui'
    show
        Canvas,
        Color,
        ImageByteFormat,
        Offset,
        Paint,
        PaintingStyle,
        Path,
        PictureRecorder,
        StrokeCap,
        StrokeJoin;

import 'package:m3e_core/m3e_core.dart' show Shapes;

/// Parses the SVG path subset M3E shape data uses (absolute and
/// relative `M`, `L`, `C`, `Z` with decimal coordinates).
Path parseSvgPath(String data) {
  final tokens = RegExp(
    r'[A-Za-z]|[+-]?(?:\d+\.?\d*|\.\d+)',
  ).allMatches(data).map((m) => m.group(0)!).toList();
  final path = Path();
  var i = 0;
  String cmd = '';
  var cx = 0.0;
  var cy = 0.0;

  bool isNumber() =>
      i < tokens.length && double.tryParse(tokens[i]) != null;
  double nextNum() {
    if (i >= tokens.length) return 0.0;
    return double.parse(tokens[i++]);
  }
  Offset nextPoint(bool relative) {
    final x = nextNum();
    final y = nextNum();
    return relative ? Offset(cx + x, cy + y) : Offset(x, y);
  }

  while (i < tokens.length) {
    final t = tokens[i];
    if (double.tryParse(t) == null) {
      // Command token (M/L/H/V/C/Z, either case).
      cmd = t;
      i++;
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        cmd = '';
      }
      continue;
    }
    if (cmd.isEmpty) {
      // Leading number with no command: cannot place it.
      break;
    }
    final relative = cmd == cmd.toLowerCase();
    switch (cmd.toUpperCase()) {
      case 'M':
        final p = nextPoint(relative);
        path.moveTo(p.dx, p.dy);
        cx = p.dx;
        cy = p.dy;
        // Further pairs after moveto are implicit linetos.
        while (isNumber()) {
          final q = nextPoint(relative);
          path.lineTo(q.dx, q.dy);
          cx = q.dx;
          cy = q.dy;
        }
      case 'L':
        while (isNumber()) {
          final p = nextPoint(relative);
          path.lineTo(p.dx, p.dy);
          cx = p.dx;
          cy = p.dy;
        }
      case 'H':
        while (isNumber()) {
          final x = nextNum();
          cx = relative ? cx + x : x;
          path.lineTo(cx, cy);
        }
      case 'V':
        while (isNumber()) {
          final y = nextNum();
          cy = relative ? cy + y : y;
          path.lineTo(cx, cy);
        }
      case 'C':
        while (i + 6 <= tokens.length && isNumber()) {
          final p1 = nextPoint(relative);
          final p2 = nextPoint(relative);
          final p3 = nextPoint(relative);
          path.cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);
          cx = p3.dx;
          cy = p3.dy;
        }
      default:
        // Unknown command: drop one token so parsing terminates.
        i++;
        break;
    }
  }
  return path;
}

/// Renders the cookie app icon at [size] pixels.
Future<Uint8List> renderTrayIcon({
  required Color background,
  required Color foreground,
  int size = 64,
}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  // The M3E path spans roughly 35..355: fit it with a small margin.
  final src = parseSvgPath(Shapes.c6SidedCookie.svg);
  final bounds = src.getBounds();
  const pad = 3.0;
  final scale =
      (size - pad * 2) / max(bounds.width, bounds.height);
  canvas.save();
  canvas.translate(
    (size - bounds.width * scale) / 2 - bounds.left * scale,
    (size - bounds.height * scale) / 2 - bounds.top * scale,
  );
  canvas.scale(scale);
  canvas.drawPath(src, Paint()..color = background);
  canvas.restore();
  // Centered play glyph; a matching stroke rounds the corners.
  final tri = Path()
    ..moveTo(size * 0.63, size * 0.50)
    ..lineTo(size * 0.395, size * 0.345)
    ..lineTo(size * 0.395, size * 0.655)
    ..close();
  canvas.drawPath(
    tri,
    Paint()
      ..color = foreground
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.045
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round,
  );
  canvas.drawPath(tri, Paint()..color = foreground);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bytes = await image.toByteData(format: ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
