// Rails: the header, the track grid and `ArtistBrowseRail` — titled
// horizontal carousels with scroll arrows.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/models/models.dart';
import '../a11y.dart';
import 'cards.dart';

/// Section header with title plus scroll-left/right buttons, mirroring
/// the rail header. Each press transitions exactly one viewport
/// page ([step] only covers the pre-layout window with no viewport).
class RailHeader extends StatelessWidget {
  const RailHeader({
    super.key,
    required this.title,
    required this.controller,
    this.step = 4 * 214.0,
    this.trailing,
    this.showArrows = true,
  });

  final String title;
  final ScrollController controller;
  final double step;
  final Widget? trailing;
  final bool showArrows;

  void _scroll(BuildContext context, int direction) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final viewport = position.viewportDimension;
    final stride = viewport > 0 ? viewport : step;
    final target = (controller.offset + direction * stride).clamp(
      0.0,
      position.maxScrollExtent,
    );
    scrollToOffset(
      context,
      controller,
      target,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        if (showArrows) ...[
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Scroll left',
            onPressed: () => _scroll(context, -1),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Scroll right',
            onPressed: () => _scroll(context, 1),
          ),
        ],
        if (trailing case final Widget t) t,
      ],
    );
  }
}

/// Horizontal rail of track cards; renders nothing when empty.
class TrackRailGrid extends StatelessWidget {
  const TrackRailGrid({
    super.key,
    required this.tracks,
    required this.playingId,
    required this.onPlay,
    this.controller,
  });

  final List<Track> tracks;
  final String? playingId;
  final void Function(Track track) onPlay;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 300,
      child: SilkyListView.builder(
        controller: controller,
        scrollSpeed: 1.5,
        silkyScrollDuration: const Duration(milliseconds: 700),
        animationCurve: Curves.easeOutQuart,
        mouseWheelVerticalDeltaBehavior:
            MouseWheelVerticalDeltaBehavior.forwardToVerticalAncestorOrSelf,
        scrollDirection: Axis.horizontal,
        itemCount: tracks.length,
        itemBuilder: (context, i) {
          final t = tracks[i];
          return TrackRailCard(
            track: t,
            playing: t.videoId == playingId,
            onTap: () => onPlay(t),
          );
        },
      ),
    );
  }
}

/// Horizontal rail of browsable items navigating to detail on tap.
/// Artists render as circular cards when [circular] is set.
class BrowseRail extends StatefulWidget {
  const BrowseRail({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
    this.circular = false,
    this.controller,
    this.trailing,
    this.fillWidth = false,
  });

  final String title;
  final List<BrowseItem> items;
  final void Function(BrowseItem item) onOpen;
  final bool circular;
  final ScrollController? controller;
  final Widget? trailing;

  /// When true, card widths scale so a whole number of cards fits
  /// edge to edge, and the scroll arrows hide when everything fits.
  final bool fillWidth;

  @override
  State<BrowseRail> createState() => _BrowseRailState();
}

class _BrowseRailState extends State<BrowseRail> {
  ScrollController? _owned;

  ScrollController get _ctrl =>
      widget.controller ?? (_owned ??= ScrollController());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    if (!widget.fillWidth) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RailHeader(
            title: widget.title,
            controller: _ctrl,
            trailing: widget.trailing,
          ),
          SizedBox(
            height: widget.circular ? 210 : 300,
            child: SilkyListView.builder(
              controller: _ctrl,
              scrollSpeed: 1.5,
              silkyScrollDuration: const Duration(milliseconds: 700),
              animationCurve: Curves.easeOutQuart,
              mouseWheelVerticalDeltaBehavior: MouseWheelVerticalDeltaBehavior
                  .forwardToVerticalAncestorOrSelf,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: widget.items.length,
              itemBuilder: (context, i) {
                final item = widget.items[i];
                return widget.circular
                    ? SimilarArtistCard(
                        item: item,
                        onTap: () => widget.onOpen(item),
                      )
                    : BrowseCard(item: item, onTap: () => widget.onOpen(item));
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      );
    }
    // Fill-width mode: scale cards so a whole number fits edge to edge,
    // and drop the scroll arrows when everything already fits.
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 16.0;
        final count = (c.maxWidth / 220).round().clamp(3, 10);
        final cardW = (c.maxWidth - gap * (count - 1)) / count;
        final needsScroll = widget.items.length > count;
        final height = widget.circular ? 210.0 : 300.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RailHeader(
              title: widget.title,
              controller: _ctrl,
              trailing: widget.trailing,
              showArrows: needsScroll,
            ),
            SizedBox(
              height: height,
              child: SilkyListView.separated(
                controller: _ctrl,
                scrollDirection: Axis.horizontal,
                scrollSpeed: 1.5,
                silkyScrollDuration: const Duration(milliseconds: 700),
                animationCurve: Curves.easeOutQuart,
                mouseWheelVerticalDeltaBehavior: MouseWheelVerticalDeltaBehavior
                    .forwardToVerticalAncestorOrSelf,
                padding: EdgeInsets.zero,
                itemCount: widget.items.length,
                separatorBuilder: (_, _) => const SizedBox(width: gap),
                itemBuilder: (context, i) {
                  final item = widget.items[i];
                  final card = widget.circular
                      ? SimilarArtistCard(
                          item: item,
                          onTap: () => widget.onOpen(item),
                        )
                      : BrowseCard(
                          item: item,
                          onTap: () => widget.onOpen(item),
                          width: cardW,
                        );
                  return SizedBox(width: cardW, child: card);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

/// Stateful horizontal card rail owning its scroll controller (safe
/// under frequent rebuilds): titled header with arrows plus cards.
class CardRail extends StatefulWidget {
  const CardRail({
    super.key,
    required this.title,
    this.trailing,
    this.height = 300,
    required this.itemCount,
    required this.itemBuilder,
  });

  final String title;
  final Widget? trailing;
  final double height;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  State<CardRail> createState() => _CardRailState();
}

class _CardRailState extends State<CardRail> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RailHeader(
          title: widget.title,
          controller: _ctrl,
          trailing: widget.trailing,
        ),
        SizedBox(
          height: widget.height,
          child: SilkyListView.builder(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            scrollSpeed: 1.5,
            silkyScrollDuration: const Duration(milliseconds: 700),
            animationCurve: Curves.easeOutQuart,
            mouseWheelVerticalDeltaBehavior:
                MouseWheelVerticalDeltaBehavior.forwardToVerticalAncestorOrSelf,
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          ),
        ),
      ],
    );
  }
}

/// Titled section laying its rows out in columns of roughly
/// [rowsPerColumn] rows each that scroll sideways, so the section stays
/// one screen tall however many items it holds. Column width follows the
/// viewport (wider rows, fewer columns per screen) and the header's
/// arrows page one viewport at a time. Renders nothing when [count] is
/// zero, and falls back to a plain vertical list when the incoming
/// width is unbounded.
class TrackColumns extends StatefulWidget {
  const TrackColumns({
    super.key,
    required this.title,
    required this.count,
    required this.itemBuilder,
    this.rowsPerColumn = 5,
    this.minColumnWidth = 460,
  });

  final String title;
  final int count;
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// Rows stacked in each column before the next column starts.
  final int rowsPerColumn;

  /// Width below which the visible column count drops by one; also sets
  /// how many columns fill one screen (wider rows, fewer columns).
  final double minColumnWidth;

  @override
  State<TrackColumns> createState() => _TrackColumnsState();
}

class _TrackColumnsState extends State<TrackColumns> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RailHeader(title: widget.title, controller: _ctrl),
        LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < widget.count; i++)
                    widget.itemBuilder(context, i),
                ],
              );
            }
            final perScreen = (constraints.maxWidth / widget.minColumnWidth)
                .floor()
                .clamp(1, 6);
            const gap = 12.0;
            // Columns fill the viewport, so one arrow press steps a
            // whole screenful however many columns the section holds.
            final colWidth =
                (constraints.maxWidth - gap * (perScreen - 1)) / perScreen;
            final columns = (widget.count / widget.rowsPerColumn).ceil();
            return SilkySingleChildScrollView(
              controller: _ctrl,
              scrollSpeed: 1.5,
              silkyScrollDuration: const Duration(milliseconds: 700),
              animationCurve: Curves.easeOutQuart,
              mouseWheelVerticalDeltaBehavior: MouseWheelVerticalDeltaBehavior
                  .forwardToVerticalAncestorOrSelf,
              scrollDirection: Axis.horizontal,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var c = 0; c < columns; c++) ...[
                      if (c > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: colWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (
                              var i = c * widget.rowsPerColumn;
                              i < (c + 1) * widget.rowsPerColumn &&
                                  i < widget.count;
                              i++
                            )
                              widget.itemBuilder(context, i),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Centered error message with a retry button.
class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          M3EFilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
