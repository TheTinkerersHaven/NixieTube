// Mini player bar ported from Kotlin `PlayerBar`: cover, title, transport,
// error, time row and seek slider. Tapping expands to Now Playing.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/player/player_state.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'gapped_rounded_track_shape.dart';
import 'volume_slider.dart';

/// Bottom mini player bar; tap to expand Now Playing.
///
/// Selects only the fields it renders (track, transport, error): palette
/// lands, lyrics, overlay toggles and other AppState traffic skip the bar
/// entirely instead of rebuilding its artwork, texts and slider.
///
/// The surface tap is deliberately animation-free (transparent
/// splash/highlight/hover) and can be disabled entirely via [tappable]
/// — the copy inside the fullscreen lyrics view is inert, its inner
/// transport controls stay live either way.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, this.tappable = true});

  /// Whether tapping the bar surface opens Now Playing (or Search when
  /// idle). False for embedded copies that are already there.
  final bool tappable;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  /// Whether the volume slider is expanded under the transport.
  bool _volumeOpen = false;

  @override
  Widget build(BuildContext context) {
    final tappable = widget.tappable;
    final track = context.select<AppState, Track?>(
      (s) => s.playerState.current,
    );
    final loading = context.select<AppState, bool>(
      (s) => s.playerState.loading,
    );
    final playing = context.select<AppState, bool>(
      (s) => s.playerState.playing,
    );
    final error = context.select<AppState, String?>((s) => s.playerState.error);
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    // Floating bottom bar: detached card with margins, rounding,
    // elevation and an outline so it hovers above the content. The
    // surrounding gap stays transparent so full-height screens show
    // through behind it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      child: Material(
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(playerRadius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(playerRadius),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: !tappable
              ? null
              : () {
                  // Already there (e.g. taps can't reach the occluded
                  // bar, but guard anyway): reopening would restart the
                  // transition and hide the tabs.
                  if (state.nowOpen) return;
                  if (track != null) {
                    state.openNow();
                  } else {
                    state.go(Screen.search);
                  }
                },
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      ArtworkImage(
                        track?.displayArtwork,
                        size: 56,
                        radius: cardRadius,
                        iconSize: 28,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track?.title ??
                                  'Search for music to start playing',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            Text(
                              track?.artistNames() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      if (loading)
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      else
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.skip_previous_rounded,
                                size: 28,
                              ),
                              tooltip: 'Previous',
                              onPressed: track == null
                                  ? null
                                  : () => state.player.previous(),
                            ),
                            IconButton(
                              icon: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 28,
                              ),
                              tooltip: 'Play/pause',
                              onPressed: track == null
                                  ? null
                                  : () => state.player.togglePlayPause(),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.skip_next_rounded,
                                size: 28,
                              ),
                              tooltip: 'Next',
                              onPressed: track == null
                                  ? null
                                  : () => state.player.next(),
                            ),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.volume_up_rounded,
                                      size: 28,
                                    ),
                                    tooltip: 'Volume',
                                    color: _volumeOpen
                                        ? scheme.primary
                                        : null,
                                    onPressed: () => setState(
                                      () => _volumeOpen = !_volumeOpen,
                                    ),
                                  ),
                                  // The slider pops out to the right of
                                  // the icon, inline with the transport.
                                  if (_volumeOpen) ...[
                                    const SizedBox(width: 4),
                                    SizedBox(
                                      width: 120,
                                      child: VolumeSlider(
                                        state: state,
                                        trackHeight: 12,
                                        thumbHeight: 18,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  // Volume pop-out removed; volume control lives inline
                  // in the transport row (see below).
                  if (error != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                  const SizedBox(height: 4),
                  // Own layer: the 2Hz label change must not re-record
                  // the card, its shadow and the texts above it.
                  RepaintBoundary(
                    child: Row(
                      children: [
                        _ProgressText(
                          buildText: (s) => Text(
                            _fmtMs(s.positionMs),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        const Spacer(),
                        _ProgressText(
                          buildText: (s) => Text(
                            '-${_fmtMs((s.durationMs - s.positionMs).clamp(0, 1 << 62))}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SliderTheme(
                    data: const SliderThemeData(
                      trackHeight: 16,
                      trackShape: GappedRoundedTrackShape(),
                      thumbSize: WidgetStatePropertyAll(Size(4, 24)),
                      padding: EdgeInsets
                          .zero, // remove the built-in horizontal inset
                      // Continuous sliders hide the indicator by default
                      // (onlyForDiscrete); force it on for seek drags.
                      showValueIndicator: ShowValueIndicator.onDrag,
                      // ignore: deprecated_member_use
                      year2023: false,
                    ),
                    child: SizedBox(
                      height: 20,
                      width: double.infinity,
                      child: _ProgressSlider(
                        state: state,
                        track: track != null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _fmtMs(int ms) {
  if (ms <= 0) return '0:00';
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Text rebuilt on progress ticks only, reading the live player snapshot
/// directly instead of rebuilding the whole bar twice a second.
class _ProgressText extends StatelessWidget {
  const _ProgressText({required this.buildText});

  final Widget Function(PlayerState s) buildText;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return ValueListenableBuilder<int>(
      valueListenable: state.progressTick,
      builder: (context, _, _) => buildText(state.player.state),
    );
  }
}

/// Seek slider rebuilt on progress ticks only (same reason as above),
/// plus local drag state so the thumb follows the finger while seeking.
/// The seek itself still fires on release so playback never stutters.
class _ProgressSlider extends StatefulWidget {
  const _ProgressSlider({required this.state, required this.track});

  final AppState state;
  final bool track;

  @override
  State<_ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<_ProgressSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.state.progressTick,
      builder: (context, _, _) {
        final s = widget.state.player.state;
        final max = s.durationMs > 0 ? s.durationMs.toDouble() : 1.0;
        final live = s.positionMs.toDouble().clamp(0, max);
        return RepaintBoundary(
          child: Slider(
            value: (_dragValue ?? live).clamp(0, max).toDouble(),
            min: 0,
            max: max,
            // A non-null label enables the value-indicator bubble; it is
            // recomputed each build, so it follows the drag value.
            label: _fmtMs((_dragValue ?? live).toInt()),
            onChangeEnd: !widget.track
                ? null
                : (v) {
                    final target = v.toInt();
                    setState(() => _dragValue = null);
                    widget.state.player.seekTo(target);
                  },
            onChanged: !widget.track
                ? null
                : (v) => setState(() => _dragValue = v),
          ),
        );
      },
    );
  }
}
