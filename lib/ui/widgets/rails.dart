// Rails ported from Kotlin `RailHeader`, `TrackRailGrid` and
// `ArtistBrowseRail`: titled horizontal carousels with scroll arrows.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/models/models.dart';
import '../a11y.dart';
import 'cards.dart';

/// Section header with title plus scroll-left/right buttons, mirroring
/// Kotlin `RailHeader`. Each press transitions exactly one viewport
/// page ([step] only covers the pre-layout window with no viewport).
class RailHeader extends StatelessWidget {
  const RailHeader({
    super.key,
    required this.title,
    required this.controller,
    this.step = 4 * 214.0,
    this.trailing,
  });

  final String title;
  final ScrollController controller;
  final double step;
  final Widget? trailing;

  void _scroll(BuildContext context, int direction) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final viewport = position.viewportDimension;
    final stride = viewport > 0 ? viewport : step;
    final target = (controller.offset + direction * stride).clamp(
      0.0,
      position.maxScrollExtent,
    );
    controller.animateTo(
      target,
      duration: readMotionDuration(
        context,
        const Duration(milliseconds: 300),
      ),
      curve: Curves.easeOut,
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
      child: ListView.builder(
        controller: controller,
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
  });

  final String title;
  final List<BrowseItem> items;
  final void Function(BrowseItem item) onOpen;
  final bool circular;
  final ScrollController? controller;
  final Widget? trailing;

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
          child: ListView.builder(
            controller: _ctrl,
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
          child: ListView.builder(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          ),
        ),
      ],
    );
  }
}

/// Centered error message with a retry button (Kotlin `ErrorBox`).
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
