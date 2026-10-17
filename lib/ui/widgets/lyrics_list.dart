// Synced-lyrics list with active-line follow, shared by the Now Playing
// lyrics tab and the full-screen lyrics view: tap-to-seek rows,
// auto-scroll tracking the song position, optional large type.

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../a11y.dart';
import '../app_state.dart';

/// Synced lyric lines with a swelling active line that auto-scrolls
/// into view as [positionMs] advances.
class LyricsList extends StatefulWidget {
  const LyricsList({
    super.key,
    required this.ctrl,
    required this.lyrics,
    required this.positionMs,
    required this.state,
    this.large = false,
    this.visibleTabIndex,
  });

  final ScrollController ctrl;
  final List<LyricLine> lyrics;
  final int positionMs;
  final AppState state;

  /// Full-screen presentation: bigger type and airier rows.
  final bool large;

  /// Tab index this list lives on, when inside a tab strip. The
  /// auto-scroll only runs while that tab is selected: scrolling an
  /// offstage list would page the TabBarView back to it. Null (the
  /// fullscreen view) always follows.
  final int? visibleTabIndex;

  @override
  State<LyricsList> createState() => _LyricsListState();
}

class _LyricsListState extends State<LyricsList> {
  /// Last line index we auto-scrolled to. Progress ticks rebuild twice a
  /// second; without this guard every tick restarts a 300ms scroll
  /// animation, which janks and fights manual scrolling.
  int _autoIndex = -1;

  /// One stable key per row. Rows keep their Element (and their
  /// AnimatedDefaultTextStyle state) as the active line moves, so the
  /// highlight swells instead of snapping — keying only the active row
  /// would remount two rows on every line change and the animation
  /// would never play. Doubles as the auto-scroll measuring point.
  List<GlobalKey> _rowKeys = const [];

  void _ensureKeys(int count) {
    if (_rowKeys.length != count) {
      _rowKeys = List.generate(count, (_) => GlobalKey());
    }
  }

  @override
  void didUpdateWidget(LyricsList old) {
    super.didUpdateWidget(old);
    if (!identical(old.lyrics, widget.lyrics)) _autoIndex = -1;
  }

  @override
  Widget build(BuildContext context) {
    _ensureKeys(widget.lyrics.length);
    final lyrics = widget.lyrics;
    final ctrl = widget.ctrl;
    final timed = lyrics.any((l) => l.timeMs >= 0);
    var currentIndex = -1;
    if (timed) {
      for (var i = 0; i < lyrics.length; i++) {
        if (lyrics[i].timeMs <= widget.positionMs) currentIndex = i;
      }
      // Before the first timestamp nothing is sung yet: leave -1 so
      // no line highlights early.
    }
    if (currentIndex >= 0 && currentIndex != _autoIndex) {
      _autoIndex = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Off-tab lists highlight but never scroll: the lines keep
        // tracking (so the tab is current on return), but scrolling
        // an ancestor PageView would page the TabBarView back here.
        final tabIndex = widget.visibleTabIndex;
        if (tabIndex != null) {
          final tabs = DefaultTabController.maybeOf(context);
          if (tabs == null || tabs.index != tabIndex || tabs.indexIsChanging) {
            return;
          }
        }
        // The lyrics may have swapped since this frame was scheduled;
        // the fresh key list may no longer cover the stale index.
        if (currentIndex < 0 || currentIndex >= _rowKeys.length) return;
        final ctx = _rowKeys[currentIndex].currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.35,
            duration: readMotionDuration(
              context,
              const Duration(milliseconds: 300),
            ),
            curve: Curves.easeOut,
          );
        } else {
          // Row is off-screen and not yet built; estimate its
          // scroll offset so the list brings it into view, then
          // the next build cycle will have a valid context for
          // ensureVisible.
          final estimatedHeight = widget.large ? 64.0 : 44.0;
          final target =
              (currentIndex * estimatedHeight - (widget.large ? 32 : 24)).clamp(
                0.0,
                ctrl.position.maxScrollExtent,
              );
          ctrl.animateTo(
            target,
            duration: readMotionDuration(
              context,
              const Duration(milliseconds: 300),
            ),
            curve: Curves.easeOut,
          );
        }
      });
    }
    final scheme = Theme.of(context).colorScheme;
    final reducedMotion = context.select<AppState, bool>(
      (s) => s.config.reducedMotion,
    );
    // Resolve the swell duration once, above the list: `select`
    // may not run inside `itemBuilder` (it would rebuild the
    // whole sliver instead of the row that cares).
    final swell = motionDuration(context, const Duration(milliseconds: 150));
    // No scrollbar: the list follows playback on its own and a thumb
    // flashing twice a second is visual noise.
    return ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(scrollbars: false),
      child: ListView.builder(
        controller: ctrl,
        padding: EdgeInsets.symmetric(
          vertical: widget.large ? 32 : 24,
          horizontal: 8,
        ),
        itemCount: lyrics.length,
        itemBuilder: (context, i) {
          final line = lyrics[i];
          final active = i == currentIndex;
          return InkWell(
            key: _rowKeys[i],
            onTap: line.timeMs >= 0
                ? () => widget.state.player.seekTo(line.timeMs)
                : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: widget.large ? 12 : 8,
                horizontal: 16,
              ),
              child: SingleMotionBuilder(
                motion: M3EMotion.custom(
                  stiffness: 300,
                  damping: 0.5,
                ).toMotion(),
                value: active ? 1.0 : 0.0,
                active: !reducedMotion,
                builder: (context, scale, _) {
                  return Transform.scale(
                    scale: 1.0 + scale * 0.1,
                    child: AnimatedDefaultTextStyle(
                      duration: swell,
                      curve: Curves.easeOut,
                      textAlign: TextAlign.center,
                      style:
                          (active
                                  ? (widget.large
                                        ? Theme.of(context)
                                              .textTheme
                                              .headlineMedium
                                        : Theme.of(context)
                                              .textTheme
                                              .titleLarge)
                                  : (widget.large
                                        ? Theme.of(context).textTheme.titleLarge
                                        : Theme.of(context)
                                              .textTheme
                                              .bodyLarge))
                              ?.copyWith(
                                color: active
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant.withValues(
                                        alpha: 0.55,
                                      ),
                              ) ??
                          DefaultTextStyle.of(context).style,
                      child: Text(line.text),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
