// Top-right overflow menu for the album detail view.
//
// Album pages get a ⋮ with Copy link and Album info; the track list
// already carries Play/Shuffle in its header, so the menu stays lean.

import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import 'album_info.dart';

enum _DetailMenuAction { copyLink, albumInfo }

/// The ⋮ button shown at the top-right of an album page.
class DetailMenuButton extends StatelessWidget {
  const DetailMenuButton({super.key, required this.item, required this.album});

  final BrowseItem item;
  final AlbumDetail album;

  void _onSelected(BuildContext context, _DetailMenuAction action) {
    final state = context.read<AppState>();
    switch (action) {
      case _DetailMenuAction.copyLink:
        unawaited(
          Clipboard.setData(ClipboardData(text: state.browsableLink(item))),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Link copied to clipboard.')),
          );
        }
      case _DetailMenuAction.albumInfo:
        if (!context.mounted) return;
        final theme = Theme.of(context);
        unawaited(
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(album.title.isNotEmpty ? album.title : item.title),
              content: SizedBox(
                width: 420,
                height: 420,
                child: AlbumInfoView(
                  album: album,
                  artist: album.artist,
                  theme: theme,
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return M3EPopupMenuButton<_DetailMenuAction>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert_rounded),
      // A 40dp circular tonal trigger (the popup's default style is
      // tonal; pinning the size to 40x40 makes the round shape a circle).
      triggerDecoration: const M3EButtonDecoration(
        fixedSize: Size(40, 40),
        padding: EdgeInsets.zero,
      ),
      onSelected: (action) => _onSelected(context, action),
      itemBuilder: (context) => const [
        M3EPopupMenuItem<_DetailMenuAction>(
          value: _DetailMenuAction.albumInfo,
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded),
              SizedBox(width: 12),
              Text('Album info'),
            ],
          ),
        ),
        M3EPopupMenuItem<_DetailMenuAction>(
          value: _DetailMenuAction.copyLink,
          child: Row(
            children: [
              Icon(Icons.link_rounded),
              SizedBox(width: 12),
              Text('Copy link'),
            ],
          ),
        ),
      ],
    );
  }
}
