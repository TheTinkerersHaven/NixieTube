import 'package:material_ui/material_ui.dart';

/// M3-style slider track: fully rounded outer ends, a small corner radius
/// next to the thumb, a gap around the thumb, and NO stop-indicator dots.
///
/// Usage:
/// ```dart
/// SliderTheme(
///   data: SliderTheme.of(context).copyWith(
///     trackHeight: 16,
///     trackShape: const GappedRoundedTrackShape(),
///   ),
///   child: Slider(value: v, onChanged: (x) => setState(() => v = x)),
/// )
/// ```
class GappedRoundedTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const GappedRoundedTrackShape({this.gap = 8.0, this.innerRadius = 2.0});

  /// Distance from the thumb center to the edge of each track segment.
  /// Roughly: half the thumb width + the visual gap you want.
  final double gap;

  /// Corner radius of the segment ends that face the thumb.
  final double innerRadius;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final double? height = sliderTheme.trackHeight;
    if (height == null || height <= 0) return;

    final Rect track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final Paint activePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledActiveTrackColor,
        end: sliderTheme.activeTrackColor,
      ).evaluate(enableAnimation)!;
    final Paint inactivePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledInactiveTrackColor,
        end: sliderTheme.inactiveTrackColor,
      ).evaluate(enableAnimation)!;

    final bool ltr = textDirection == TextDirection.ltr;
    final Paint leftPaint = ltr ? activePaint : inactivePaint;
    final Paint rightPaint = ltr ? inactivePaint : activePaint;

    final Radius outer = Radius.circular(track.height / 2);
    final Radius inner = Radius.circular(innerRadius);

    // Left segment: from track start to just before the thumb.
    final double leftEnd = thumbCenter.dx - gap;
    if (leftEnd - track.left > 1) {
      context.canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          track.left,
          track.top,
          leftEnd,
          track.bottom,
          topLeft: outer,
          bottomLeft: outer,
          topRight: inner,
          bottomRight: inner,
        ),
        leftPaint,
      );
    }

    // Right segment: from just after the thumb to track end.
    final double rightStart = thumbCenter.dx + gap;
    if (track.right - rightStart > 1) {
      context.canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          rightStart,
          track.top,
          track.right,
          track.bottom,
          topLeft: inner,
          bottomLeft: inner,
          topRight: outer,
          bottomRight: outer,
        ),
        rightPaint,
      );
    }
  }
}

/// M3 Expressive bar thumb that shrinks while pressed, matching the
/// press behavior of the stock expressive slider.
class ShrinkBarThumbShape extends SliderComponentShape {
  const ShrinkBarThumbShape({
    this.width = 4.0,
    this.height = 28.0,
    this.pressedScale = 0.55,
  });

  /// Resting bar size.
  final double width;
  final double height;

  /// Size multiplier while pressed (via [activationAnimation]).
  final double pressedScale;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final ColorTween colorTween = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    );
    final double scale = 1.0 - (1.0 - pressedScale) * activationAnimation.value;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: width * scale,
        height: height * scale,
      ),
      Radius.circular((width * scale) / 2),
    );
    context.canvas.drawRRect(
      rrect,
      Paint()..color = colorTween.evaluate(enableAnimation)!,
    );
  }
}
