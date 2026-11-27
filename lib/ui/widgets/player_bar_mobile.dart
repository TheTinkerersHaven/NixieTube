// Mobile mini player bar: compact, floating card above bottom navigation.
// Shows artwork, title, artist, previous/play-pause/next buttons, plus a
// slim progress line.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';

/// Compact mini player bar for mobile / narrow layouts.
class PlayerBarMobile extends StatefulWidget {
  const PlayerBarMobile({super.key, this.tappable = true});

  final bool tappable;

  @override
  State<PlayerBarMobile> createState() => _PlayerBarMobileState();
}

class _PlayerBarMobileState extends State<PlayerBarMobile> {
  /// Live horizontal drag, in logical pixels, for the lean the card gives
  /// under the finger. A notifier, so a drag repaints the card's offset
  /// instead of rebuilding the bar and the labels inside it. It holds the
  /// raw travel: the lean is `clamp`ed from it when painting, so the
  /// decision at the end of the gesture still sees how far the finger went
  /// once the card has stopped leaning.
  final ValueNotifier<double> _drag = ValueNotifier(0);

  /// How far the card leans while a swipe is in progress, and how far the
  /// finger has to travel — or how fast it has to leave — for the gesture
  /// to count. The thresholds are deliberately generous: the bar is small
  /// and the thumb rests on it, so changing song has to be meant.
  static const double _lean = 18;
  static const double _minTravel = 56;
  static const double _minFlickTravel = 28;
  static const double _minFlickVelocity = 700;

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _drag.value += details.delta.dx;
  }

  void _onDragEnd(DragEndDetails details, AppState state, bool enabled) {
    final travel = _drag.value;
    _drag.value = 0;
    if (!enabled) return;
    final flick = details.velocity.pixelsPerSecond.dx;
    final far = travel.abs() >= _minTravel;
    final quick =
        travel.abs() >= _minFlickTravel && flick.abs() >= _minFlickVelocity;
    if (!far && !quick) return;
    // Left is forward, the way a horizontal pager reads.
    if (travel < 0 || flick < 0) {
      state.player.next();
    } else {
      state.player.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = context.select<AppState, Track?>(
      (s) => s.playerState.current,
    );
    final loading = context.select<AppState, bool>(
      (s) => s.playerState.loading,
    );
    final playing = context.select<AppState, bool>(
      (s) => s.playerState.playing,
    );
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final canSwipe = widget.tappable && track != null && !loading;

    final card = Material(
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ExpressiveCorners.medium),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(ExpressiveCorners.medium),
        onTap: !widget.tappable
            ? null
            : () {
                if (state.nowOpen) return;
                if (track != null) {
                  state.openNow();
                } else {
                  state.go(Screen.search);
                }
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                children: [
                  ArtworkImage(
                    track?.displayArtwork,
                    size: 44,
                    radius: ExpressiveCorners.small,
                    iconSize: 22,
                    squareCoverKey: track?.videoId,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track?.title ?? 'Search for music to start playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            children: [
                              if (track?.explicit == true)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      Icons.explicit,
                                      size: 13,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              TextSpan(
                                text:
                                    track?.artistNames() ??
                                    (track != null ? '' : 'NixieTube'),
                              ),
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
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded, size: 26),
                    tooltip: 'Previous',
                    onPressed: track == null || loading
                        ? null
                        : () => state.player.previous(),
                  ),
                  IconButton(
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 26,
                    ),
                    tooltip: 'Play/pause',
                    onPressed: track == null || loading
                        ? null
                        : () => state.player.togglePlayPause(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded, size: 26),
                    tooltip: 'Next',
                    onPressed: track == null || loading
                        ? null
                        : () => state.player.next(),
                  ),
                ],
              ),
            ),
            // Slim progress bar along the bottom of the mini player
            const _MiniProgressBar(),
          ],
        ),
      ),
    );

    return Padding(
      // Even all round: the card floats on the same 8dp gap above the
      // navigation bar as it does at the screen's sides. (Inside the
      // card, the content's 6dp top and 4dp bottom over the 2.5dp
      // progress line already sit evenly.)
      padding: const EdgeInsets.all(8),
      // A horizontal drag across the bar changes song: left is next,
      // right is previous. The card leans under the finger so the gesture
      // shows it has been taken, and the buttons above keep their taps.
      child: GestureDetector(
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (d) => _onDragEnd(d, state, canSwipe),
        onHorizontalDragCancel: () => _drag.value = 0,
        child: ValueListenableBuilder<double>(
          valueListenable: _drag,
          builder: (context, travel, child) => Transform.translate(
            offset: Offset(travel.clamp(-_lean, _lean), 0),
            child: child,
          ),
          child: card,
        ),
      ),
    );
  }
}

class _MiniProgressBar extends StatelessWidget {
  const _MiniProgressBar();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    // Playback progress arrives on its own notifier, not through
    // `notifyListeners`: a tick twice a second must not rebuild the app.
    // Reading the position with `select` instead would leave the bar
    // frozen until something else rebuilt the page.
    return ValueListenableBuilder<int>(
      valueListenable: state.progressTick,
      builder: (context, _, _) {
        final pos = state.playerState.positionMs;
        final dur = state.playerState.durationMs;
        final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
        return SizedBox(
          height: 2.5,
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
          ),
        );
      },
    );
  }
}
