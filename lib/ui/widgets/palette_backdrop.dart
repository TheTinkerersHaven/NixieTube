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

import 'dart:async' show unawaited;

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

/// Pulls a vivid cover tint down to a muted, dark wash so it can sit behind
/// the UI accent without competing with it. Near-neutral covers and tints
/// that are already dark keep their color; [washStop] still collapses any
/// bright cover toward the surface.
Color tameWashTint(Color color) {
  final hsl = HSLColor.fromColor(color);
  if (hsl.saturation <= 0.45) return color;
  return hsl
      .withSaturation(0.35)
      .withLightness(hsl.lightness.clamp(0.0, 0.2))
      .toColor();
}

/// How far the accent is rotated away from the wash hue, in degrees.
/// A page whose pills sit in exactly the same hue as its own backdrop
/// reads as one flat color; a few degrees of separation keeps the accent
/// on top of the wash instead of inside it.
const double _accentHueShift = 12;

/// Accent derived from a cover-art [palette]: the hue of its most vivid
/// cell, rebuilt at a fixed saturation and lightness so a washed-out photo
/// and a flat graphic both give a usable accent instead of a grey one.
///
/// Null when the artwork carries no color worth taking — a monochrome
/// cover, or a palette that has not been computed yet — in which case the
/// page keeps the scheme's own accent.
Color? coverAccent(List<Color>? palette) {
  if (palette == null || palette.length < 25) return null;
  HSLColor? best;
  var bestScore = 0.0;
  for (final cell in palette) {
    final hsl = HSLColor.fromColor(cell);
    if (hsl.saturation < 0.22 ||
        hsl.lightness < 0.06 ||
        hsl.lightness > 0.94) {
      continue;
    }
    // Vivid, mid-toned cells win: a dark or pastel cell is a weak seed
    // for an accent even when it is the most saturated one.
    final score = hsl.saturation * (1 - (hsl.lightness - 0.55).abs() * 1.4);
    if (score > bestScore) {
      bestScore = score;
      best = hsl;
    }
  }
  if (best == null) return null;
  return best
      .withHue((best.hue + _accentHueShift) % 360)
      .withSaturation(0.62)
      .withLightness(0.74)
      .toColor();
}

/// Turns [base] into a scheme whose accent roles are the cover accent,
/// keeping every surface and text tier the app resolved from the user's
/// theme: a page tints its controls with the artwork, it does not change
/// mood on every song change.
ColorScheme coverAccentScheme(ColorScheme base, Color accent) {
  final hsl = HSLColor.fromColor(accent);
  Color tone(double saturation, double lightness) => hsl
      .withSaturation(saturation)
      .withLightness(lightness)
      .toColor();
  return base.copyWith(
    primary: accent,
    onPrimary: tone(0.45, 0.12),
    primaryContainer: tone(0.45, 0.24),
    onPrimaryContainer: tone(0.45, 0.92),
    // The tonal pill (Play/Shuffle, the Sort chip) is the accent's
    // container step, so it has to move with the accent too.
    secondaryContainer: tone(0.28, 0.28),
    onSecondaryContainer: tone(0.45, 0.90),
  );
}

/// Scopes the cover accent to the content of one page.
///
/// Album and playlist pages and Now Playing sit under this: their pills,
/// chips, like state and sliders take the artwork's hue, while the mini
/// player, the navigation and every other page keep the scheme's accent —
/// two accents on one screen would read as a bug. High contrast skips it
/// for the same reason the wash does: separation must not depend on
/// artwork luminance. The accent crossfades when the artwork changes,
/// over the wash's own [PaletteBackdrop.paletteWash].
class CoverAccent extends StatelessWidget {
  const CoverAccent({super.key, required this.palette, required this.child});

  /// 5x5 cover palette, as [coverBands] computes it.
  final List<Color>? palette;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (highContrastOf(context)) return child;
    final accent = coverAccent(palette);
    if (accent == null) return child;
    final theme = Theme.of(context);
    return TweenAnimationBuilder<Color?>(
      duration: motionDuration(context, PaletteBackdrop.paletteWash),
      tween: ColorTween(begin: accent, end: accent),
      // The page subtree is passed through untouched: only its
      // descendants that read the scheme rebuild with the accent.
      builder: (context, color, child) => Theme(
        data: theme.copyWith(
          colorScheme: coverAccentScheme(theme.colorScheme, color ?? accent),
        ),
        child: child!,
      ),
      child: child,
    );
  }
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

/// A [PaletteBackdrop] that also requests its own palette: [paletteFor]
/// reads the computed cache, [ensurePalette] computes it on a miss, and
/// [tick] notifies when a palette lands so the wash repaints. Keeping the
/// request next to the render site — instead of relying on a panel's
/// mount-time trigger — makes the wash follow the artwork URL even when
/// it changes after the panel mounted (track paging, late-arriving track
/// covers), so the gradient doesn't collapse to a solid background once
/// loading finishes.
class ArtworkBackdrop extends StatefulWidget {
  const ArtworkBackdrop({
    super.key,
    required this.artUrl,
    required this.paletteFor,
    required this.ensurePalette,
    this.tick,
  });

  /// Cover whose palette should wash the background.
  final String? artUrl;

  /// Cache read: the computed palette for [artUrl], or null.
  final List<Color>? Function(String? url) paletteFor;

  /// Computes and caches the palette for [artUrl] when missing.
  final Future<List<Color>?> Function(String? url) ensurePalette;

  /// Bumped when any palette is computed; drives the repaint.
  final Listenable? tick;

  @override
  State<ArtworkBackdrop> createState() => _ArtworkBackdropState();
}

class _ArtworkBackdropState extends State<ArtworkBackdrop> {
  String? _requestedUrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _requestPalette();
  }

  @override
  void didUpdateWidget(ArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _requestPalette();
  }

  void _requestPalette() {
    final url = widget.artUrl;
    if (url == null || url.isEmpty || url == _requestedUrl) return;
    _requestedUrl = url;
    if (widget.paletteFor(url) == null) {
      unawaited(widget.ensurePalette(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tick = widget.tick;
    if (tick == null) {
      return PaletteBackdrop(
        palette: widget.paletteFor(widget.artUrl) ?? const <Color>[],
      );
    }
    return ListenableBuilder(
      listenable: tick,
      builder: (context, _) => PaletteBackdrop(
        palette: widget.paletteFor(widget.artUrl) ?? const <Color>[],
      ),
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
    final avg = tameWashTint(
      Color.fromRGBO(red ~/ 5, green ~/ 5, blue ~/ 5, 1),
    );
    stops.add(washStop(avg, 0.08 + 0.14 * row / 4, backdrop));
  }
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: stops,
  );
}
