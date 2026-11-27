// The skeleton shimmer is a wide, symmetric bell that starts and ends
// outside each bone: this paints the real effect the app configures and
// measures the band it lays down, so a return to the package's narrow
// skewed highlight (a bright line crossing the bones) or to bounds that
// light up a third of every tile on the first frame fails here instead of
// only being caught by eye.

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:skeletonizer/skeletonizer.dart';

const _width = 240;
const _height = 8;

/// Luminance of the effect across x at animation value [t], one sample
/// per column (the green channel: all three tones are near-grey).
Future<List<int>> _row(
  WidgetTester tester,
  PaintingEffect effect,
  double t,
) async {
  final samples = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = ui.Rect.fromLTWH(0, 0, _width.toDouble(), _height.toDouble());
    canvas.drawRect(rect, effect.createPaint(t, rect, ui.TextDirection.ltr));
    final image = await recorder.endRecording().toImage(_width, _height);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    return [for (var x = 0; x < _width; x++) bytes[x * 4 + 1]];
  });
  return samples!;
}

void main() {
  testWidgets('the shimmer covers the bone as a wide wave', (tester) async {
    final effect = skeletonEffect();
    final row = await _row(tester, effect, 0);
    final bone = row.first;
    final crest = row.reduce((a, b) => a > b ? a : b);
    expect(row.last, bone, reason: 'both edges stay flat bone');
    expect(crest - bone, greaterThan(12), reason: 'the wave still shows');

    // Columns carrying light: the whole band, not a thin line. The
    // package's own shimmer lights under a third of the width.
    final lit = row.where((v) => v > bone + 3).length;
    expect(
      lit / _width,
      greaterThan(0.5),
      reason: 'the highlight spans most of the bone',
    );

    // Symmetric: the crest sits at the middle at t = 0, so the light
    // rolls both ways instead of leaning to one side.
    final peak = row.indexOf(crest);
    expect((peak - _width / 2).abs(), lessThan(12));
    expect(row[peak - 40] - row[peak + 40], inInclusiveRange(-1, 1));
  });

  testWidgets('the wave starts and wraps outside the bone', (tester) async {
    final effect = skeletonEffect();
    final bone = (await _row(tester, effect, 0)).first;
    // Both ends of the sweep are where the animation starts and wraps:
    // no column may be lit there, or the light pops up inside the tile
    // instead of entering from its edge.
    for (final t in [effect.lowerBound, effect.upperBound]) {
      final row = await _row(tester, effect, t);
      expect(
        row.every((v) => v == bone),
        isTrue,
        reason: 'nothing is lit at t = $t',
      );
    }
    // A quarter of a period after the start, the band is on its way in
    // from the left — not already at the middle.
    final entering = await _row(
      tester,
      effect,
      effect.lowerBound + (effect.upperBound - effect.lowerBound) * 0.25,
    );
    final crest = entering.reduce((a, b) => a > b ? a : b);
    expect(crest, greaterThan(bone));
    expect(entering.indexOf(crest), lessThan(_width ~/ 2));
  });

  testWidgets('reduced motion paints a solid bone', (tester) async {
    final row = await _row(tester, skeletonEffect(reduced: true), 0);
    expect(row.toSet().length, 1, reason: 'no gradient at all');
  });
}
