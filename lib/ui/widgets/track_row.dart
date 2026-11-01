// Track list row ported from Kotlin `TrackRow`: artwork, title,
// artist/album, duration, and an overflow menu. Rows stay lean on
// purpose: rating is one tap, everything else (queue, playlists,
// link, remove) lives in the ⋮ spring menu and the right-click menu.

import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'song_info.dart';
import 'spring_context_menu.dart';

/// Actions in a track row's overflow menu.
enum TrackRowAction { playNext, addToPlaylist, copyLink, removeFromPlaylist, songInfo }

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
}

class _TrackRowState extends State<TrackRow> {
  bool _hovering = false;

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
    final liked = context.select<AppState, bool>((s) => s.isLiked(track.videoId));
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
                            _fmtDur(track.durationSec),
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
            child: _hovering
                ? IconButton(
                    icon: const Icon(Icons.more_vert_rounded),
                    tooltip: 'More actions',
                    onPressed: () => _showMenuAtRowEnd(context),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
    // Hosts with their own row menu (Up Next) opt out so right-click
    // never stacks two menus (the single-menu guard would eat theirs).
    final hovered = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: tile,
    );
    if (!contextMenu) return hovered;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showMenu(context, context.read<AppState>(), details.globalPosition),
      child: hovered,
    );
  }

  /// Overflow menu shared by the ⋮ button and right-click.
  Future<void> _showMenu(
    BuildContext context,
    AppState state,
    Offset position,
  ) async {
    final selected = await showSpringMenu<TrackRowAction>(
      context: context,
      position: position,
      items: [
        const SpringMenuItem(
          icon: Icon(Icons.playlist_play_rounded),
          label: 'Play next',
          value: TrackRowAction.playNext,
        ),
        if (widget.showPlaylists)
          const SpringMenuItem(
            icon: Icon(Icons.playlist_add_rounded),
            label: 'Add to playlist',
            value: TrackRowAction.addToPlaylist,
          ),
        const SpringMenuItem(
          icon: Icon(Icons.link_rounded),
          label: 'Copy link',
          value: TrackRowAction.copyLink,
        ),
        const SpringMenuItem(
          icon: Icon(Icons.info_outline_rounded),
          label: 'Song info',
          value: TrackRowAction.songInfo,
        ),
        if (widget.removable && widget.onRemove != null)
          const SpringMenuItem(
            icon: Icon(Icons.remove_circle_outline_rounded),
            label: 'Remove from playlist',
            value: TrackRowAction.removeFromPlaylist,
          ),
      ],
    );
    if (!context.mounted) return;
    switch (selected) {
      case TrackRowAction.playNext:
        // Nothing loaded: just play it instead of queueing into
        // the void (enqueueNext alone would stay silent).
        if (state.player.state.current == null) {
          state.player.playTracks([widget.track]);
        } else {
          state.player.enqueueNext(widget.track);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Queued next')));
        }
      case TrackRowAction.addToPlaylist:
        unawaited(state.openPlaylistDialog(widget.track));
      case TrackRowAction.copyLink:
        await Clipboard.setData(
          ClipboardData(text: 'https://youtu.be/${widget.track.videoId}'),
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard.')),
        );
      case TrackRowAction.songInfo:
        if (!context.mounted) return;
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
      case null:
        break;
    }
  }

  /// Menu anchor at the row's right edge (the ⋮ button has no tap
  /// details to position with).
  void _showMenuAtRowEnd(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final position = box == null
        ? Offset.zero
        : box.localToGlobal(Offset(box.size.width, 0));
    unawaited(_showMenu(context, context.read<AppState>(), position));
  }
}

String _fmtDur(int sec) {
  if (sec <= 0) return '0:00';
  return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
}


