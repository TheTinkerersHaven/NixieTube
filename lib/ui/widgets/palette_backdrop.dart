// Shared cover-tinted backdrop: the cover sampled as a
// 5x5 grid (see `coverBands`), rendered as a vertical
// gradient whose stops average each row of the grid —
// a heavily blurred version of the artwork at the cost
// of a single gradient draw. When the palette changes
// (song switch), the gradient crossfades over a short
// one-shot wash; the animation is not continuous, so
// the repaint cost is bounded to the transition.
//
// Used by the Now Playing view (track palette) and the
// album/playlist detail views (artwork palette), so the
// same luminance-aware wash that keeps text readable on
// light covers is available everywhere.

import 'package:material_ui/material_ui.dart';

import '../a11y.dart';

/// Relative luminance of an opaque color, 0 (black) to 1 (white).
double luminance(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

/// Blends [other] toward [base] by [amount], then pulls bright results
/// further toward the background so a light cover can never wash out the
/// text. The extra pull scales with the palette color's own luminance, so
/// dark artwork keeps its tint while near-white collapses to background.
Color washStop(Color other, double amount, Color base) {
  final lum = luminance(other);
  final extra = ((lum - 0.25) / 0.75).clamp(0.0, 1.0);
  final eff = amount + (1 - amount) * extra;
  int mix(double c, double b) =>
      (c + (b - c) * eff).round().clamp(0, 255).toInt();
  return Color.fromRGBO(
    mix(other.r * 255, base.r * 255),
    mix(other.g * 255, base.g * 255),
    mix(other.b * 255, base.b * 255),
    1,
  );
}

/// Backdrop built from a cover-art [palette] (5x5 grid
/// from `coverBands`, row-major TL→BR). Renders a plain
/// surface color when no palette is available yet.
class PaletteBackdrop extends StatelessWidget {
  const PaletteBackdrop({super.key, required this.palette});

  /// One-shot crossfade length when the palette changes
  /// (track switch, artwork load). Kept short so the
  /// wash reads as a smooth transition without dragging.
  static const paletteWash = Duration(milliseconds: 600);

  final List<Color> palette;

  @override
  Widget build(BuildContext context) {
    final backdrop = Theme.of(context).colorScheme.surface;
    // High contrast drops the cover-tinted wash for a solid
    // surface: text separation must never depend on artwork
    // luminance. The select rebuilds the backdrop when the
    // setting flips, swapping gradient and solid live.
    if (highContrastOf(context) || palette.length < 25) {
      return ColoredBox(color: backdrop);
    }
    final gradient = _gradient(palette, backdrop);
    // Begin == end on the first build (no visible animation),
    // so the gradient is shown immediately; on a palette
    // change TweenAnimationBuilder crossfades from the
    // currently displayed gradient to the new one.
    return TweenAnimationBuilder<Decoration?>(
      duration: motionDuration(context, paletteWash),
      tween: DecorationTween(
        begin: BoxDecoration(gradient: gradient),
        end: BoxDecoration(gradient: gradient),
      ),
      builder: (context, decoration, child) =>
          DecoratedBox(decoration: decoration ?? const BoxDecoration()),
    );
  }
}

/// One gradient stop per row of the grid, averaged across
/// the columns, so the gradient follows the cover's
/// vertical color flow. The wash ramps toward the bottom,
/// where captions and the transport sit.
LinearGradient _gradient(List<Color> palette, Color backdrop) {
  final stops = <Color>[];
  for (var row = 0; row < 5; row++) {
    var red = 0;
    var green = 0;
    var blue = 0;
    for (var col = 0; col < 5; col++) {
      final cell = palette[row * 5 + col];
      red += (cell.r * 255).round();
      green += (cell.g * 255).round();
      blue += (cell.b * 255).round();
    }
    final avg = Color.fromRGBO(red ~/ 5, green ~/ 5, blue ~/ 5, 1);
    stops.add(washStop(avg, 0.08 + 0.14 * row / 4, backdrop));
  }
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: stops,
  );
}
