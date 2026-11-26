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
import 'track_menu_scope.dart';

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
    this.albumRows = false,
    this.flush = false,
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

  /// Album detail rows: the hero card already shows the cover and the
  /// album name, so on phones the row drops the artwork thumbnail and
  /// the album name from the subtitle, and keeps a fixed 28dp index.
  final bool albumRows;

  /// On phones, drops the row's side padding so its content lines up
  /// with a header that sits flush on the same edge (the artist page's
  /// section header) instead of keeping the 12dp gutter.
  final bool flush;

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

class _TrackRowState extends State<TrackRow> with TrackMenuHost<TrackRow> {
  bool _hovering = false;
  bool _menuOpen = false;
  final GlobalKey _anchorKey = GlobalKey();
  final GlobalKey _moreKey = GlobalKey();

  void _openMoreMenu() {
    setState(() => _menuOpen = true);
    widget.onMenuOpenChanged?.call(true);
    final anchorBox =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final buttonBox = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchorBox != null && buttonBox != null) {
      final buttonOrigin = buttonBox.localToGlobal(Offset.zero);
      final anchorOrigin = anchorBox.localToGlobal(Offset.zero);
      final local = buttonOrigin - anchorOrigin;
      openTrackMenu(
        context,
        menuController,
        position: Offset(
          local.dx + buttonBox.size.width,
          local.dy + buttonBox.size.height,
        ),
      );
    } else {
      openTrackMenu(context, menuController);
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
    // Phones cannot fit the duration column and both thumb buttons
    // beside a readable title: drop the play-count column and the
    // separate duration, fold the duration into the subtitle, and use
    // slightly smaller art and index so long titles survive. Album rows
    // additionally drop the artwork (the hero card carries the cover)
    // and the album name, and keep a fixed 28dp index.
    final compact = isCompactLayout(context);
    final albumRows = widget.albumRows;
    final subtitle = [
      track.artistNames(),
      if (!albumRows) track.album?.name ?? '',
      if (compact && track.durationSec > 0) formatDuration(track.durationSec),
    ].where((s) => s.trim().isNotEmpty).join(' • ');
    final tile = ListTile(
      // On phones the trailing like/dislike/⋮ buttons each carry 12dp
      // of icon inset, so the row pads its left side by the same 12dp:
      // artwork and icons then sit evenly inside the list's margins.
      // Hosts whose header sits flush with the list edge (the artist
      // page's section header) set [flush] instead, so the rows line up
      // with the header without an extra gutter.
      contentPadding: compact
          ? (widget.flush ? EdgeInsets.zero : const EdgeInsets.only(left: 12))
          : const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      visualDensity: compact ? VisualDensity.compact : null,
      onTap: onPlay,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index != null)
            SizedBox(
              width: compact && !albumRows ? 20 : 28,
              child: Text(
                '$index',
                textAlign: TextAlign.left,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: playing ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (!(compact && albumRows))
            ArtworkImage(
              track.displayArtwork,
              size: compact ? 44 : 48,
              radius: rowArtRadius,
              iconSize: compact ? 22 : 24,
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
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Duration/plays sit left of the action buttons, in open
          // space instead of crammed into the row's far corner. On
          // phones the duration lives in the subtitle, so this column
          // would only steal width from the title.
          if (!compact && (track.durationSec > 0 || _viewsLabel != null))
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
                track: track,
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
                track: track,
              ),
            ),
          ] else ...[
            if (track.rating == RatingStatus.like ||
                track.rating == RatingStatus.dislike)
              // Same 48dp box as the buttons, so the static icon keeps
              // the same right inset they have.
              SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Icon(
                    track.rating == RatingStatus.dislike
                        ? Icons.thumb_down_rounded
                        : Icons.thumb_up_rounded,
                    color: scheme.primary,
                  ),
                ),
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
    // Hosts with their own row menu (Up Next) opt out so the row-local
    // right-click does not compete with the host's. When the host supplies
    // [hovering], it owns the hover region.
    final hovered = widget.hovering != null
        ? tile
        : MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: tile,
          );
    // Reparenting the tile through a global key keeps its state (notably
    // the artwork decode) alive when the anchor is dropped for a menu swap.
    final card = KeyedSubtree(key: menuChildKey, child: hovered);
    // Wrap every row in an M3E menu anchor so the ⋮ button (and, when
    // enabled, right-click) opens the M3E popup menu instead of the
    // old spring pill stack. While another menu is open, drop the anchor:
    // its dispose removes the overlay at once, with no jumpy close.
    final showAnchor = anchorWanted;
    updateAnchorVisibility(showAnchor);
    final anchored = showAnchor
        ? M3EMenuAnchor(
            key: _anchorKey,
            controller: menuController,
            menuChildren: trackMenuItems(
              context,
              track,
              showPlaylists: widget.showPlaylists,
              onRemove: widget.removable ? widget.onRemove : null,
            ),
            onClose: () {
              closeTrackMenu(context, menuController);
              if (mounted) {
                setState(() => _menuOpen = false);
                widget.onMenuOpenChanged?.call(false);
              }
            },
            builder: (ctx, controller, child) => child!,
            // Translucent: a right-click on another row must reach that row
            // (the coordinator then closes this menu). Primary taps still
            // land on the barrier, which dismisses the menu as before.
            consumeOutsideTaps: false,
            child: card,
          )
        : card;
    // Hosts with their own row menu (Up Next) opt out of the row-local
    // right-click. On phones there is no hover to reveal the ⋮ either,
    // so press-and-hold opens the same menu at the press point.
    if (!contextMenu && !compact) return anchored;
    return GestureDetector(
      onSecondaryTapDown: contextMenu
          ? (details) => openTrackMenu(
              context,
              menuController,
              position: details.localPosition,
            )
          : null,
      onLongPressStart: compact
          ? (details) => openTrackMenu(
              context,
              menuController,
              position: details.localPosition,
            )
          : null,
      child: anchored,
    );
  }
}

/// Menu entries for a track's overflow menu: the row's ⋮ button and the
/// rail cards' right-click both use these, so the two never drift apart.
List<Widget> trackMenuItems(
  BuildContext context,
  Track track, {
  bool showPlaylists = true,
  VoidCallback? onRemove,
}) {
  final state = context.read<AppState>();
  return [
    M3EMenuItemButton(
      onPressed: () =>
          runTrackAction(context, state, TrackRowAction.playNext, track),
      leadingIcon: const Icon(Icons.playlist_play_rounded),
      child: const Text('Play next'),
    ),
    if (showPlaylists)
      M3EMenuItemButton(
        onPressed: () =>
            runTrackAction(context, state, TrackRowAction.addToPlaylist, track),
        leadingIcon: const Icon(Icons.playlist_add_rounded),
        child: const Text('Add to playlist'),
      ),
    M3EMenuItemButton(
      onPressed: () =>
          runTrackAction(context, state, TrackRowAction.copyLink, track),
      leadingIcon: const Icon(Icons.link_rounded),
      child: const Text('Copy link'),
    ),
    M3EMenuItemButton(
      onPressed: () =>
          runTrackAction(context, state, TrackRowAction.songInfo, track),
      leadingIcon: const Icon(Icons.info_outline_rounded),
      child: const Text('Song info'),
    ),
    if (onRemove != null)
      M3EMenuItemButton(
        onPressed: () => runTrackAction(
          context,
          state,
          TrackRowAction.removeFromPlaylist,
          track,
          onRemove: onRemove,
        ),
        leadingIcon: const Icon(Icons.remove_circle_outline_rounded),
        child: const Text('Remove from playlist'),
      ),
  ];
}

/// Runs one [TrackRowAction] for [track]. Shared by the row and the rail
/// cards so both menus behave identically.
void runTrackAction(
  BuildContext context,
  AppState state,
  TrackRowAction action,
  Track track, {
  VoidCallback? onRemove,
}) {
  switch (action) {
    case TrackRowAction.playNext:
      if (state.player.state.current == null) {
        state.player.playTracks([track]);
      } else {
        state.player.enqueueNext(track);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Queued next')));
        }
      }
    case TrackRowAction.addToPlaylist:
      unawaited(state.openPlaylistDialog(track));
    case TrackRowAction.copyLink:
      unawaited(
        Clipboard.setData(
          ClipboardData(text: 'https://youtu.be/${track.videoId}'),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard.')),
        );
      }
    case TrackRowAction.songInfo:
      if (!context.mounted) return;
      final theme = Theme.of(context);
      unawaited(
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(track.title),
            content: SizedBox(
              width: 420,
              height: 520,
              child: SongInfoView(
                track: track,
                theme: theme,
                // Opening an artist or album from the info dialog must
                // not leave the dialog covering the page it opens.
                onNavigate: () => Navigator.of(ctx).pop(),
              ),
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
      onRemove?.call();
  }
}
