// Mini player bar ported from Kotlin `PlayerBar`: cover, title, transport,
// error, time row and seek slider. Tapping expands to Now Playing.

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/player/player_state.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'seek_slider.dart';
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

class _PlayerBarState extends State<PlayerBar> with TickerProviderStateMixin {
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
              // Vertical only: the rows above keep the 16dp side
              // inset, while the seek slot below goes full-bleed
              // to the card edges.
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        ArtworkImage(
                          track?.displayArtwork,
                          size: 56,
                          radius: cardRadius,
                          iconSize: 28,
                          // Same square art the lists show (already
                          // cached), so the bar never re-downloads.
                          squareCoverKey: track?.videoId,
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
                              Text.rich(
                                TextSpan(
                                  children: [
                                    if (track?.explicit == true)
                                      WidgetSpan(
                                        alignment: PlaceholderAlignment.middle,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            right: 4,
                                          ),
                                          child: Icon(
                                            Icons.explicit,
                                            size: 14,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    TextSpan(text: track?.artistNames() ?? ''),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        // Controls stay mounted while a track
                        // loads, only disabled: the row never
                        // collapses, so the bar keeps its height.
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.skip_previous_rounded,
                                size: 28,
                              ),
                              tooltip: 'Previous',
                              onPressed: track == null || loading
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
                              onPressed: track == null || loading
                                  ? null
                                  : () => state.player.togglePlayPause(),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.skip_next_rounded,
                                size: 28,
                              ),
                              tooltip: 'Next',
                              onPressed: track == null || loading
                                  ? null
                                  : () => state.player.next(),
                            ),
                            SingleMotionBuilder(
                              motion: M3EMotion.expressiveEffectsDefault
                                  .toMotion(),
                              value: _volumeOpen ? 1.0 : 0.0,
                              builder: (context, value, _) {
                                return Row(
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
                                    const SizedBox(width: 4),
                                    SizedBox(
                                      width: 120.0 * value,
                                      child: VolumeSlider(
                                        state: state,
                                        trackHeight: 12,
                                        thumbHeight: 18,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Volume pop-out removed; volume control lives inline
                  // in the transport row (see below).
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.error),
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  // Own layer: the 2Hz label change must not re-record
                  // the card, its shadow and the texts above it.
                  RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          _ProgressText(
                            buildText: (s) => Text(
                              formatClock(s.positionMs),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          const Spacer(),
                          _ProgressText(
                            buildText: (s) => Text(
                              '-${formatClock((s.durationMs - s.positionMs).clamp(0, 1 << 62))}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Snug 24dp slot: the slider compresses to it
                  // (painting its 16dp track centered) while a
                  // track loads the slot shows the squiggly linear
                  // indicator instead — only 10dp tall, so the
                  // symmetric padding ((24 - 10) / 2) centers it
                  // exactly where the track sits, and swapping
                  // between the two never moves the bar.
                  SizedBox(
                    height: 24,
                    child: loading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: 7,
                              horizontal: 16,
                            ),
                            child: M3ELinearWavyProgressIndicator(),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: SeekSlider(
                              state: state,
                              enabled: track != null,
                              thumbHeight: 16,
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
