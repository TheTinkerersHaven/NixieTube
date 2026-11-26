// Context menu for browsable cards: albums, playlists and artists.
//
// Shares the track-menu plumbing (one menu at a time, cursor anchoring,
// artwork-safe anchor swaps) with rows and rail cards; only the actions
// differ.

import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import 'album_info.dart';
import 'track_menu_scope.dart';

/// Menu entries for a browsable card.
List<Widget> browseMenuItems(BuildContext context, BrowseItem item) {
  final state = context.read<AppState>();
  final playable = item.browseId.startsWith('MPRE') || item.isPlaylist;
  final albumInfoAvailable = _isAlbumId(item.browseId);
  return [
    if (playable)
      M3EMenuItemButton(
        onPressed: () => unawaited(_playAlbumOrPlaylist(state, context, item)),
        leadingIcon: const Icon(Icons.play_arrow_rounded),
        child: const Text('Play'),
      ),
    if (playable)
      M3EMenuItemButton(
        onPressed: () =>
            unawaited(_shuffleAlbumOrPlaylist(state, context, item)),
        leadingIcon: const Icon(Icons.shuffle_rounded),
        child: const Text('Shuffle'),
      ),
    M3EMenuItemButton(
      onPressed: () => state.openBrowsable(item),
      leadingIcon: const Icon(Icons.open_in_new_rounded),
      child: const Text('Open'),
    ),
    M3EMenuItemButton(
      onPressed: () {
        unawaited(
          Clipboard.setData(ClipboardData(text: state.browsableLink(item))),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied to clipboard.')),
        );
      },
      leadingIcon: const Icon(Icons.link_rounded),
      child: const Text('Copy link'),
    ),
    if (albumInfoAvailable)
      M3EMenuItemButton(
        onPressed: () => unawaited(_showAlbumInfo(context, item)),
        leadingIcon: const Icon(Icons.info_outline_rounded),
        child: const Text('Album info'),
      ),
  ];
}

/// An album id the info dialog can look up: albums and EPs/Singles carry
/// the MPRE prefix; other browsables (playlists, artists) don't.
bool _isAlbumId(String id) => id.startsWith('MPRE');

Future<void> _showAlbumInfo(BuildContext context, BrowseItem item) async {
  final state = context.read<AppState>();
  // The album page has to be fetched before the dialog can show it.
  // Say so instead of looking unresponsive: right-clicking and seeing
  // nothing for a second reads as a frozen app.
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Loading album info…'),
      duration: Duration(seconds: 2),
    ),
  );
  final detail = await state.albumDetailFor(item);
  if (!context.mounted) return;
  if (detail == null) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text("Couldn't load this album — check your connection."),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Album info'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: AlbumInfoView(album: detail, artist: detail.artist),
      ),
      actions: [
        M3ETextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Future<void> _playAlbumOrPlaylist(
  AppState state,
  BuildContext context,
  BrowseItem item,
) async {
  final ok = await state.playBrowsable(item);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't load this list — check your connection."),
      ),
    );
  }
}

Future<void> _shuffleAlbumOrPlaylist(
  AppState state,
  BuildContext context,
  BrowseItem item,
) async {
  final ok = await state.playBrowsableShuffled(item);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't load this list — check your connection."),
      ),
    );
  }
}

/// Right-click and ⋮ menu for a browsable card.
class BrowseMenuTarget extends StatefulWidget {
  const BrowseMenuTarget({super.key, required this.item, required this.child});

  final BrowseItem item;
  final Widget child;

  @override
  State<BrowseMenuTarget> createState() => _BrowseMenuTargetState();
}

class _BrowseMenuTargetState extends State<BrowseMenuTarget>
    with TrackMenuHost {
  @override
  Widget build(BuildContext context) {
    final showAnchor = anchorWanted;
    updateAnchorVisibility(showAnchor);
    final keyed = KeyedSubtree(key: menuChildKey, child: widget.child);
    // On phones there is no right-click: press and hold the card opens
    // the same menu at the press point.
    final void Function(LongPressStartDetails)? longPress =
        isCompactLayout(context)
        ? (details) => openTrackMenu(
            context,
            menuController,
            position: details.localPosition,
          )
        : null;
    Widget wrap(Widget child) => GestureDetector(
      onSecondaryTapDown: (details) => openTrackMenu(
        context,
        menuController,
        position: details.localPosition,
      ),
      onLongPressStart: longPress,
      child: child,
    );
    if (!showAnchor) return wrap(keyed);
    return wrap(
      M3EMenuAnchor(
        controller: menuController,
        menuChildren: browseMenuItems(context, widget.item),
        builder: (ctx, controller, child) => child!,
        onClose: () => closeTrackMenu(context, menuController),
        consumeOutsideTaps: false,
        child: keyed,
      ),
    );
  }
}
