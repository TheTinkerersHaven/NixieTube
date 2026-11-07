// Track list row: artwork, title, artist/album, duration, and an
// overflow menu. Rows stay lean on purpose: rating is one tap,
// everything else (queue, playlists, link, remove) lives in the ⋮
// spring menu and the right-click menu.

import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../format.dart';
import 'artwork_image.dart';
import 'song_info.dart';

/// Actions in a track row's overflow menu.
enum TrackRowAction {
  playNext,
  addToPlaylist,
  copyLink,
  removeFromPlaylist,
  songInfo,
}

/// One track row. Rating buttons appear when [rateable] and signed in;
/// [showPlaylists] adds the dialog entry to the overflow menu, and
/// [removable] (with [onRemove]) adds the remove entry there.
class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    this.index,
    this.playing = false,
    required this.onPlay,
    this.rateable = false,
    this.showPlaylists = false,
    this.removable = false,
    this.onRemove,
    this.showViews = false,
    this.contextMenu = true,
    this.hovering,
    this.onMenuOpenChanged,
  });

  @override
  State<TrackRow> createState() => _TrackRowState();

  final Track track;
  final int? index;
  final bool playing;
  final VoidCallback onPlay;
  final bool rateable;
  final bool showPlaylists;

  /// Shows a remove action (user-editable playlists).
  final bool removable;
  final VoidCallback? onRemove;

  /// Shows the row's play count under the duration (artist top
  /// songs, album tracks) when the backend provided one.
  final bool showViews;

  /// Whether right-click opens the overflow menu. Hosts with their
  /// own row menu (Up Next) disable this to avoid double menus.
  final bool contextMenu;

  /// When non-null, the row uses this hover state instead of tracking
  /// its own. Hosts that wrap the row together with a sibling control
  /// (the Up next drag handle) pass it so both reveal and hide as one.
  final bool? hovering;

  /// Notifies the host when this row's overflow menu opens or closes,
  /// so sibling controls (e.g. the Up next drag handle) can stay
  /// revealed alongside the ⋮ button.
  final ValueChanged<bool>? onMenuOpenChanged;
}

class _TrackRowState extends State<TrackRow> {
  bool _hovering = false;
  bool _menuOpen = false;
  final M3EMenuController _menuController = M3EMenuController();
  final GlobalKey _anchorKey = GlobalKey();
  final GlobalKey _moreKey = GlobalKey();

  @override
  void dispose() {
    _menuController.dispose();
    super.dispose();
  }

  void _openMoreMenu() {
    setState(() => _menuOpen = true);
    widget.onMenuOpenChanged?.call(true);
    final anchorBox = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final buttonBox = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchorBox != null && buttonBox != null) {
      final buttonOrigin = buttonBox.localToGlobal(Offset.zero);
      final anchorOrigin = anchorBox.localToGlobal(Offset.zero);
      final local = buttonOrigin - anchorOrigin;
      _menuController.open(
        position: Offset(
          local.dx + buttonBox.size.width,
          local.dy + buttonBox.size.height,
        ),
      );
    } else {
      _menuController.open();
    }
  }

  String? get _viewsLabel {
    if (!widget.showViews) return null;
    final v = widget.track.views.trim();
    return v.isEmpty ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = widget.track;
    final index = widget.index;
    final playing = widget.playing;
    final onPlay = widget.onPlay;
    final rateable = widget.rateable;
    final contextMenu = widget.contextMenu;
    final signedIn = context.select<AppState, bool>((s) => s.account != null);
    final liked = context.select<AppState, bool>(
      (s) => s.isLiked(track.videoId),
    );
    // A host that wraps the row and a sibling control shares one hover
    // state with it, so both reveal together.
    final hovering = (widget.hovering ?? _hovering) || _menuOpen;
    final subtitle = [
      track.artistNames(),
      track.album?.name ?? '',
    ].where((s) => s.trim().isNotEmpty).join(' • ');
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onTap: onPlay,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index != null)
            SizedBox(
              width: 28,
              child: Text(
                '$index',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: playing ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ArtworkImage(
            track.displayArtwork,
            size: 48,
            radius: rowArtRadius,
            iconSize: 24,
            squareCoverKey: track.videoId,
          ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(color: playing ? scheme.primary : scheme.onSurface),
      ),
      subtitle: subtitle.isEmpty && !track.explicit
          ? null
          : Text.rich(
              TextSpan(
                children: [
                  if (track.explicit)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.explicit,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  TextSpan(text: subtitle),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Duration/plays sit left of the action buttons, in open
          // space instead of crammed into the row's far corner.
          if (track.durationSec > 0 || _viewsLabel != null)
            Builder(
              builder: (context) {
                // Locals promote; the getter does not.
                final viewsLabel = _viewsLabel;
                return SizedBox(
                  width: 72,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (track.durationSec > 0)
                          Text(
                            formatDuration(track.durationSec),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (viewsLabel != null)
                          Text(
                            viewsLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (rateable && signedIn) ...[
            IconButton(
              icon: Icon(
                liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
              ),
              tooltip: liked ? 'Remove like' : 'Like',
              color: liked ? scheme.primary : scheme.onSurface,
              onPressed: () => context.read<AppState>().rateTrackFeedback(
                context,
                track.videoId,
                liked ? RatingStatus.indifferent : RatingStatus.like,
              ),
            ),
            IconButton(
              icon: Icon(
                track.rating == RatingStatus.dislike
                    ? Icons.thumb_down_rounded
                    : Icons.thumb_down_outlined,
              ),
              tooltip: track.rating == RatingStatus.dislike
                  ? 'Remove dislike'
                  : 'Dislike',
              color: track.rating == RatingStatus.dislike
                  ? scheme.primary
                  : scheme.onSurface,
              onPressed: () => context.read<AppState>().rateTrackFeedback(
                context,
                track.videoId,
                track.rating == RatingStatus.dislike
                    ? RatingStatus.indifferent
                    : RatingStatus.dislike,
              ),
            ),
          ] else ...[
            if (track.rating == RatingStatus.like ||
                track.rating == RatingStatus.dislike)
              Icon(
                track.rating == RatingStatus.dislike
                    ? Icons.thumb_down_rounded
                    : Icons.thumb_up_rounded,
                color: scheme.primary,
              ),
          ],
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: hovering
                ? IconButton(
                    icon: const Icon(Icons.more_vert_rounded),
                    tooltip: 'More actions',
                    key: _moreKey,
                    onPressed: _openMoreMenu,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
    // Hosts with their own row menu (Up Next) opt out so right-click
    // never stacks two menus (the single-menu guard would eat theirs).
    // When the host supplies [hovering], it owns the hover region.
    final hovered = widget.hovering != null
        ? tile
        : MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: tile,
          );
    // Wrap every row in an M3E menu anchor so the ⋮ button (and, when
    // enabled, right-click) opens the M3E popup menu instead of the
    // old spring pill stack.
    final anchored = M3EMenuAnchor(
      key: _anchorKey,
      controller: _menuController,
      menuChildren: _buildMenuItems(context, context.read<AppState>()),
      onClose: () {
        if (mounted) {
          setState(() => _menuOpen = false);
          widget.onMenuOpenChanged?.call(false);
        }
      },
      builder: (ctx, controller, child) => child!,
      child: hovered,
    );
    if (!contextMenu) return anchored;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _menuController.open(position: details.localPosition),
      child: anchored,
    );
  }

  List<Widget> _buildMenuItems(BuildContext context, AppState state) {
    return [
      M3EMenuItemButton(
        onPressed: () => _runMenuAction(TrackRowAction.playNext, state),
        leadingIcon: const Icon(Icons.playlist_play_rounded),
        child: const Text('Play next'),
      ),
      if (widget.showPlaylists)
        M3EMenuItemButton(
          onPressed: () => _runMenuAction(TrackRowAction.addToPlaylist, state),
          leadingIcon: const Icon(Icons.playlist_add_rounded),
          child: const Text('Add to playlist'),
        ),
      M3EMenuItemButton(
        onPressed: () => _runMenuAction(TrackRowAction.copyLink, state),
        leadingIcon: const Icon(Icons.link_rounded),
        child: const Text('Copy link'),
      ),
      M3EMenuItemButton(
        onPressed: () => _runMenuAction(TrackRowAction.songInfo, state),
        leadingIcon: const Icon(Icons.info_outline_rounded),
        child: const Text('Song info'),
      ),
      if (widget.removable && widget.onRemove != null)
        M3EMenuItemButton(
          onPressed: () =>
              _runMenuAction(TrackRowAction.removeFromPlaylist, state),
          leadingIcon: const Icon(Icons.remove_circle_outline_rounded),
          child: const Text('Remove from playlist'),
        ),
    ];
  }

  void _runMenuAction(TrackRowAction action, AppState state) {
    switch (action) {
      case TrackRowAction.playNext:
        if (state.player.state.current == null) {
          state.player.playTracks([widget.track]);
        } else {
          state.player.enqueueNext(widget.track);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Queued next')));
          }
        }
      case TrackRowAction.addToPlaylist:
        unawaited(state.openPlaylistDialog(widget.track));
      case TrackRowAction.copyLink:
        unawaited(
          Clipboard.setData(
            ClipboardData(text: 'https://youtu.be/${widget.track.videoId}'),
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Link copied to clipboard.')),
          );
        }
      case TrackRowAction.songInfo:
        if (!mounted) return;
        final theme = Theme.of(context);
        unawaited(
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(widget.track.title),
              content: SizedBox(
                width: 420,
                height: 520,
                child: SongInfoView(track: widget.track, theme: theme),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        );
      case TrackRowAction.removeFromPlaylist:
        widget.onRemove?.call();
    }
  }
}
