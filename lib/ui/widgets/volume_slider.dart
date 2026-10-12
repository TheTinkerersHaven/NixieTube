// Volume slider with local drag state and throttled engine updates.
// Volume-only player updates bump volumeTick instead of notifying, so
// dragging never rebuilds the app (see isVolumeOnlyUpdate). Uses the
// M3E slider: gapped track plus a bar thumb that shrinks while
// pressed — deliberately shorter than the seek thumb so the volume
// control reads as secondary.

import 'dart:async';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';

class VolumeSlider extends StatefulWidget {
  const VolumeSlider({
    super.key,
    required this.state,
    this.trackHeight = 16,
    this.thumbHeight = 20,
  });

  final AppState state;

  /// Track thickness. The mini player bar uses a slimmer track than
  /// the Now Playing transport.
  final double trackHeight;

  /// Resting bar-thumb height. The volume thumb is shorter than the
  /// seek thumb on purpose.
  final double thumbHeight;

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  double? _drag;
  Timer? _throttle;

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listens to volumeTick, not an AppState select: volume-only
    // player updates skip notifyListeners entirely (see
    // isVolumeOnlyUpdate), so a select here would go stale mid-drag.
    return ValueListenableBuilder<int>(
      valueListenable: widget.state.volumeTick,
      builder: (context, _, _) {
        final volume = widget.state.player.state.volume;
        return M3ESlider(
          value: (_drag ?? volume.toDouble()).clamp(0, 100).toDouble(),
          min: 0,
          max: 100,
          // A non-null label shows the pill above the thumb while
          // pressed; it is recomputed each build, so it follows the
          // drag value.
          label: (_drag ?? volume.toDouble()).round().toString(),
          decoration: M3ESliderDecoration(
            trackHeight: widget.trackHeight,
            thumbHeight: widget.thumbHeight,
          ),
          onChanged: (v) {
            setState(() => _drag = v);
            // At most one engine + rebuild round-trip per window while
            // dragging; the exact value lands on release below.
            _throttle ??= Timer(const Duration(milliseconds: 120), () {
              _throttle = null;
              final pending = _drag;
              if (pending != null) {
                widget.state.player.setVolume(pending.toInt());
              }
            });
          },
          onChangeEnd: (v) {
            _throttle?.cancel();
            _throttle = null;
            setState(() => _drag = null);
            widget.state.player.setVolume(v.toInt());
          },
        );
      },
    );
  }
}
