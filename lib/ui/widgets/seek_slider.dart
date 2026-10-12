// Shared seek slider: the M3E slider (gapped track, bar
// thumb that shrinks on press) plus the two motions the
// transport needs — a smooth glide when tapping a point
// to seek, and an end-to-start sweep when a song ends.

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';

/// Formats a millisecond count as m:ss.
String formatClock(int ms) {
  if (ms <= 0) return '0:00';
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Seek slider with local drag state, a glide when a
/// point is tapped, and an end-to-start sweep when the
/// position resets (song finished / repeat). The seek
/// itself still fires on release so playback never
/// stutters mid-drag.
class SeekSlider extends StatefulWidget {
  const SeekSlider({
    super.key,
    required this.state,
    this.enabled = true,
    this.thumbHeight,
  });

  final AppState state;

  /// Whether seeking is allowed (a track must be loaded).
  final bool enabled;

  /// Optional bar-thumb height; null keeps the M3E
  /// default. The mini player bar passes a shorter one,
  /// the Now Playing transport a taller one.
  final double? thumbHeight;

  @override
  State<SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<SeekSlider>
    with TickerProviderStateMixin {
  // Drag value (ms) while the finger is down.
  double? _dragValue;

  // Last value of the current gesture. M3ESlider reports
  // the slider's current value (not the gesture target) in
  // onChangeEnd, and the glide delays that rebuild — so the
  // seek target is tracked here instead.
  double? _gestureValue;

  // Tap-to-seek glide: the first onChanged of a gesture
  // (a tap) animates toward the point; drag continuations
  // snap to the finger instantly (their next update
  // cancels the glide within a frame or two).
  late final AnimationController _slideCtrl;
  Tween<double>? _slide;

  // End-to-start sweep: a non-user backward jump in the
  // live position (song finished, repeat) sweeps the thumb
  // back instead of teleporting it.
  late final AnimationController _sweepCtrl;
  Tween<double>? _sweep;

  double _lastFraction = 0.0;
  int _changesThisGesture = 0;

  @override
  void initState() {
    super.initState();
    // Bounded (0..1): both animations terminate at 1.0,
    // unlike the spring motions which need unbounded
    // controllers to overshoot.
    _slideCtrl = AnimationController(vsync: this);
    _sweepCtrl = AnimationController(vsync: this);
    widget.state.progressTick.addListener(_onProgress);
  }

  @override
  void dispose() {
    widget.state.progressTick.removeListener(_onProgress);
    _slideCtrl.dispose();
    _sweepCtrl.dispose();
    super.dispose();
  }

  double _currentMax() {
    final s = widget.state.player.state;
    return s.durationMs > 0 ? s.durationMs.toDouble() : 1.0;
  }

  double _liveFraction() {
    final max = _currentMax();
    final s = widget.state.player.state;
    return s.positionMs.toDouble().clamp(0, max) / max;
  }

  /// Fraction of the track the thumb shows, honouring the
  /// drag value and whichever animation is running.
  double _displayedFraction(double liveFraction) {
    if (_dragValue != null) {
      final max = _currentMax();
      return (_dragValue! / max).clamp(0.0, 1.0);
    }
    if (_slide != null && _slideCtrl.isAnimating) {
      return _slide!.evaluate(_slideCtrl).clamp(0.0, 1.0);
    }
    if (_sweep != null && _sweepCtrl.isAnimating) {
      return _sweep!.evaluate(_sweepCtrl).clamp(0.0, 1.0);
    }
    return liveFraction;
  }

  void _onProgress() {
    final max = _currentMax();
    final s = widget.state.player.state;
    final fraction = s.positionMs.toDouble().clamp(0, max) / max;
    // A non-user backward jump = the song ended (or a
    // repeat): sweep from where it was back to the start
    // instead of teleporting the thumb.
    if (_dragValue == null &&
        !_slideCtrl.isAnimating &&
        fraction < _lastFraction - 0.001) {
      _sweep = Tween(begin: _lastFraction, end: fraction);
      _sweepCtrl
        ..stop()
        ..value = 0.0
        ..animateTo(1.0,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOut);
    }
    _lastFraction = fraction;
  }

  void _startSlide(double targetFraction) {
    final from = _displayedFraction(_liveFraction());
    _slide = Tween(begin: from, end: targetFraction);
    // Glide time scales with the distance: a small hop
    // is quick, a full-length seek still under half a
    // second.
    final dist = (targetFraction - from).abs();
    _slideCtrl
      ..stop()
      ..value = 0.0
      ..animateTo(1.0,
          duration: Duration(milliseconds: (90 + 300 * dist).round()),
          curve: Curves.fastOutSlowIn);
  }

  void _cancelSlide() {
    _slide = null;
    _slideCtrl.stop();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds on progress ticks and on either animation
    // controller, so the glide and the sweep repaint
    // smoothly without rebuilding the rest of the bar.
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.state.progressTick,
        _slideCtrl,
        _sweepCtrl,
      ]),
      builder: (context, _) {
        final max = _currentMax();
        final shown = _displayedFraction(_liveFraction()) * max;
        return RepaintBoundary(
          child: M3ESlider(
            value: shown,
            min: 0,
            max: max,
            // A non-null label shows the time pill above
            // the thumb while pressed; it follows the
            // glide and the sweep too.
            label: formatClock(shown.round()),
            decoration: widget.thumbHeight == null
                ? null
                : M3ESliderDecoration(thumbHeight: widget.thumbHeight),
            enabled: widget.enabled,
            onChangeStart: widget.enabled
                ? (_) {
                  _changesThisGesture = 0;
                  _gestureValue = null;
                  _cancelSlide();
                }
                : null,
            onChanged: widget.enabled
                ? (v) {
                  _gestureValue = v;
                  _changesThisGesture++;
                  if (_changesThisGesture == 1) {
                    // First change of the gesture: a tap
                    // (or the first drag frame) — glide to
                    // the point. A real drag cancels this
                    // on its next update.
                    _startSlide(v / max);
                  } else {
                    _cancelSlide();
                    setState(() => _dragValue = v);
                  }
                }
                : null,
            onChangeEnd: widget.enabled
                ? (v) {
                  // The gesture target, not the (possibly
                  // stale) reported value: the glide still
                  // owns the displayed value here.
                  final target = _gestureValue ?? v;
                  // Remember the target so the sweep never
                  // misreads the user's own backward seek.
                  _lastFraction = target / max;
                  _dragValue = null;
                  widget.state.player.seekTo(target.toInt());
                }
                : null,
          ),
        );
      },
    );
  }
}
