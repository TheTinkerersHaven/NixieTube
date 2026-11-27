// Synced-lyrics list with active-line follow, shared by the Now Playing
// lyrics tab and the full-screen lyrics view: tap-to-seek rows,
// auto-scroll tracking the song position, optional large type.

import 'dart:math' show min;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../a11y.dart';
import '../app_state.dart';
import '../theme.dart';

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
    this.tabController,
    this.restoreOffset,
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

  /// The tab strip's controller, when this list lives inside the tab
  /// strip. Used to gate auto-scroll to the active tab. Null in the
  /// fullscreen view (always follows playback).
  final TabController? tabController;

  /// The scroll offset to restore on the first build, or null to keep
  /// the normal behaviour (follow the active line).
  ///
  /// A callback, not a value: switching tabs in the Now Playing view
  /// disposes the list's page, so the list is built again from
  /// scratch and the offset has to be read at that moment — otherwise
  /// the reader would lose their place and land back on the active
  /// line.
  final double? Function()? restoreOffset;

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

  /// Set while the first build restores a scroll offset: the
  /// follow-scroll must not fight the restore.
  bool _restoring = false;

  /// The offset to restore, read when the list is built.
  double? _restoreTo;

  @override
  void initState() {
    super.initState();
    final restore = widget.restoreOffset?.call();
    _restoreTo = restore;
    _restoring = restore != null && restore > 0;
  }

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
    if (_restoring) {
      // The list was rebuilt (the tab page was disposed): put the
      // reader back where they were, and keep the follow-scroll quiet
      // until the next line change.
      _restoring = false;
      if (currentIndex >= 0) _autoIndex = currentIndex;
      final offset = _restoreTo ?? 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!ctrl.hasClients) return;
        if (ctrl.offset > 0) return;
        ctrl.jumpTo(offset.clamp(0.0, ctrl.position.maxScrollExtent));
      });
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
          final tabs =
              widget.tabController ?? DefaultTabController.maybeOf(context);
          if (tabs == null || tabs.index != tabIndex || tabs.indexIsChanging) {
            return;
          }
        }
        // The lyrics may have swapped since this frame was scheduled;
        // the fresh key list may no longer cover the stale index.
        if (currentIndex < 0 || currentIndex >= _rowKeys.length) return;
        final ctx = _rowKeys[currentIndex].currentContext;
        if (ctx != null) {
          // A zero duration makes ensureVisible jump instead of
          // animate, which is what the reduced-motion setting asks for.
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
          // Every row is laid out in the sung style and merely scaled
          // down while idle, so the fallback estimate is that style's
          // line box rather than a guess along the idle one.
          final activeType = widget.large
              ? Theme.of(context).textTheme.headlineMedium
              : Theme.of(context).textTheme.titleLarge;
          final estimatedHeight =
              (activeType?.fontSize ?? 22) * (activeType?.height ?? 1.4) +
              2 * (widget.large ? 12 : 8);
          final target =
              (currentIndex * estimatedHeight - (widget.large ? 32 : 24)).clamp(
                0.0,
                ctrl.position.maxScrollExtent,
              );
          scrollToOffset(
            context,
            ctrl,
            target,
            duration: const Duration(milliseconds: 300),
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
    // A phone keeps the swell smaller: the active line is scaled up
    // around its centre, so a full-width line only stays on screen when
    // the growth is absorbed by the padding (see the constraint below).
    final compact = isCompactLayout(context);
    final swellScale = compact ? 0.12 : 0.2;
    // No scrollbar: the list follows playback on its own and a thumb
    // flashing twice a second is visual noise.
    return ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(scrollbars: false),
      child: ListView.builder(
        controller: ctrl,
        padding: EdgeInsets.symmetric(
          vertical: widget.large ? 32 : 24,
          horizontal: compact ? 4 : 8,
        ),
        itemCount: lyrics.length,
        itemBuilder: (context, i) {
          final line = lyrics[i];
          final active = i == currentIndex;
          // One set of metrics for the whole list, taken from the sung
          // style. The line is laid out in it whether it is sung or not,
          // so its words break in one place and never move: the idle
          // line is that same layout drawn smaller, and a transform is
          // the one kind of emphasis that cannot re-wrap anything. The
          // weight is fixed for the same reason — wght changes glyph
          // advances, so a lighter idle weight would re-break its words
          // the moment they were sung.
          final type = Theme.of(context).textTheme;
          final idleSize = (widget.large ? type.titleLarge : type.bodyLarge)
              ?.fontSize;
          final sung =
              (widget.large ? type.headlineMedium : type.titleLarge) ??
              DefaultTextStyle.of(context).style;
          final layout = sung.copyWith(
            fontWeight: FontWeight.w400,
            // Rebuild the axis list rather than replacing it: the other
            // axes (optical size, roundness) are the font's look, and
            // only the weight is pinned, so that every row shares one
            // set of advances.
            fontVariations: [
              for (final axis in sung.fontVariations ?? const <FontVariation>[])
                if (axis.axis != 'wght') axis,
              const FontVariation('wght', 400),
            ],
          );
          // How much smaller the idle line is drawn: bodyLarge next to
          // titleLarge on a phone, titleLarge next to headlineMedium in
          // the full-screen view.
          final idleScale = ((idleSize ?? 16) / (layout.fontSize ?? 22)).clamp(
            0.5,
            1.0,
          );
          final color = active
              ? scheme.primary
              : (timed
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.55)
                    : scheme.onSurface);
          return InkWell(
            key: _rowKeys[i],
            onTap: line.timeMs >= 0
                ? () => widget.state.player.seekTo(line.timeMs)
                : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: widget.large ? 12 : 8,
                horizontal: compact ? 12 : 16,
              ),
              // Lines are measured against the width they have, not the
              // window: a lyrics column that runs edge to edge is hard to
              // read on a phone and unreadable on a wide monitor, so the
              // text takes a capped measure, centred, and the swell is
              // absorbed by that cap instead of pushing the line off
              // screen.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final measure = min(
                    widget.large ? 720.0 : 560.0,
                    constraints.maxWidth / (1 + swellScale),
                  );
                  // The line has one layout for its whole life: being
                  // sung changes the colour and the scale, never the
                  // metrics. The row is therefore already the height it
                  // will be when active, and no line below it moves when
                  // the highlight arrives.
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: measure),
                      // A 0.5 damping ratio overshoots by ~16% at the
                      // first peak and then rings back twice: pop in,
                      // spring back, spring forward, slight spring
                      // back. 0.75 cuts the ring to ~3%, which lands
                      // as a single small overshoot: the swell settles
                      // instead of rocking.
                      child: SingleMotionBuilder(
                        motion: M3EMotion.custom(
                          stiffness: 300,
                          damping: 0.75,
                        ).toMotion(),
                        value: active ? 1.0 : 0.0,
                        active: !reducedMotion,
                        builder: (context, scale, _) {
                          // Idle size → sung size, with the spring's
                          // overshoot on top so the line swells past its
                          // resting size and settles back. Both ends are
                          // the sizes the type scale asks for; only the
                          // transform moves.
                          final grow = idleScale + (1 - idleScale) * scale;
                          return Transform.scale(
                            scale: grow * (1 + scale * swellScale),
                            child: AnimatedDefaultTextStyle(
                              duration: swell,
                              curve: Curves.easeOut,
                              textAlign: TextAlign.center,
                              // Colour is the only thing that animates:
                              // every metric is the same in both states,
                              // so the paragraph is laid out once and
                              // its words stay where they are.
                              style: layout.copyWith(color: color),
                              child: Text(line.text),
                            ),
                          );
                        },
                      ),
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
