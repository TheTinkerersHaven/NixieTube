// Dynamically rendered app icon: the M3 Expressive 4-sided cookie
// shape (same SVG path data as [Shapes.c4SidedCookie]) filled with
// the app's primary color and a center transport glyph in on-primary:
// pause bars while playing, the rounded play triangle while paused.
// Rendered for the tray icon and the window icon, and re-rendered
// whenever the theme or transport state changes, so both always match
// the app.

import 'dart:math' show max, min;
import 'dart:typed_data' show Uint8List;
import 'dart:ui'
    show
        Canvas,
        Color,
        ImageByteFormat,
        Offset,
        Paint,
        Path,
        PictureRecorder,
        RRect,
        Radius;

import 'package:m3e_core/m3e_core.dart' show Shapes;

/// Parses the SVG path subset M3E shape data uses (absolute and
/// relative `M`, `L`, `C`, `Z` with decimal coordinates).
Path parseSvgPath(String data) {
  final tokens = RegExp(r'[A-Za-z]|[+-]?(?:\d+\.?\d*|\.\d+)')
      .allMatches(data)
      .map((m) => m.group(0)!)
      .toList();
  final path = Path();
  var i = 0;
  String cmd = '';
  var cx = 0.0;
  var cy = 0.0;

  bool isNumber() => i < tokens.length && double.tryParse(tokens[i]) != null;
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

/// Right-pointing triangle with rounded corners (quadratic corners
/// like the Material rounded play glyph), in unit coordinates scaled
/// by [size] around the tile center.
Path _roundedPlay(double size, double radius) {
  Offset lerp(Offset p, Offset q, double t) =>
      Offset(p.dx + (q.dx - p.dx) * t, p.dy + (q.dy - p.dy) * t);
  final pts = [
    Offset(size * 0.63, size * 0.50), // tip
    Offset(size * 0.395, size * 0.345), // top-left
    Offset(size * 0.395, size * 0.655), // bottom-left
  ];
  final path = Path();
  for (var k = 0; k < 3; k++) {
    final p0 = pts[k];
    final pPrev = pts[(k + 2) % 3];
    final pNext = pts[(k + 1) % 3];
    final d1 = (p0 - pPrev).distance;
    final d2 = (pNext - p0).distance;
    final q1 = lerp(p0, pPrev, min(radius, d1 / 2) / d1);
    final q2 = lerp(p0, pNext, min(radius, d2 / 2) / d2);
    if (k == 0) {
      path.moveTo(q1.dx, q1.dy);
    } else {
      path.lineTo(q1.dx, q1.dy);
    }
    path.quadraticBezierTo(p0.dx, p0.dy, q2.dx, q2.dy);
  }
  path.close();
  return path;
}

/// Pause bars with fully rounded ends (same corner radius as the
/// play glyph), in unit coordinates scaled by [size] around the tile
/// center. Drawn when the player is playing; the play triangle shows
/// when paused so the tray icon mirrors the transport state.
Path _roundedPause(double size, double radius) {
  final path = Path();
  const barW = 0.11;
  const gap = 0.09;
  const halfH = 0.17;
  for (final cx in [0.5 - gap / 2 - barW / 2, 0.5 + gap / 2 + barW / 2]) {
    path.addRRect(
      RRect.fromLTRBR(
        size * (cx - barW / 2),
        size * (0.5 - halfH),
        size * (cx + barW / 2),
        size * (0.5 + halfH),
        Radius.circular(radius),
      ),
    );
  }
  return path;
}

/// Renders the cookie app icon at [size] pixels. The center glyph
/// mirrors the transport state: pause bars while playing, the play
/// triangle while paused.
Future<Uint8List> renderTrayIcon({
  required Color background,
  required Color foreground,
  required bool playing,
  int size = 64,
}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  // Fit the M3E path with a small margin (bounds adapt per shape).
  final src = parseSvgPath(Shapes.c4SidedCookie.svg);
  final bounds = src.getBounds();
  const pad = 3.0;
  final scale = (size - pad * 2) / max(bounds.width, bounds.height);
  canvas.save();
  canvas.translate(
    (size - bounds.width * scale) / 2 - bounds.left * scale,
    (size - bounds.height * scale) / 2 - bounds.top * scale,
  );
  canvas.scale(scale);
  canvas.drawPath(src, Paint()..color = background);
  canvas.restore();
  // Center glyph, filled (corners are geometry, not strokes, so
  // it stays crisp at tray sizes).
  canvas.drawPath(
    playing
        ? _roundedPause(size.toDouble(), size * 0.055)
        : _roundedPlay(size.toDouble(), size * 0.055),
    Paint()..color = foreground,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bytes = await image.toByteData(format: ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
