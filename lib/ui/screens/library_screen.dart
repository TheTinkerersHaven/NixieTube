// Library screen: tabbed playlists,
// artists and liked songs, plus the open-playlist view.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/screen_list.dart';
import '../widgets/album_panel.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cards.dart';
import '../widgets/rails.dart';

import '../widgets/palette_backdrop.dart';

enum _PlaylistMenuAction { rename, delete }

/// Collage sources an opened playlist's view paints for [playlist].
///
/// Every playlist shows a mosaic of its first songs except the liked
/// list, which has a cover of its own (the liked-music artwork): it
/// shows that single image instead of a collage.
List<String> playlistViewArts(AccountPlaylist playlist) =>
    playlist.id == '__liked' ? const [] : playlist.arts;

/// Account library (playlists, artists, liked songs).
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Narrow selects, not a full watch: the screen now rebuilds only for
    // playlist and sign-in changes, and the async backdrop palette
    // (ensurePalette → cached bands) arrives through state.paletteTick
    // instead of an app-wide notification. state.read() below covers
    // all imperative calls (callbacks), which never need reactivity.
    final state = context.read<AppState>();
    final opened = context.select<AppState, OpenPlaylist?>(
      (s) => s.openedPlaylist,
    );
    final account = context.select<AppState, String?>((s) => s.account);
    // Backdrop fills the whole screen, header row included: the
    // title and settings icon sit on the wash, like Now Playing.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (opened != null)
          RepaintBoundary(
            child: ListenableBuilder(
              listenable: state.paletteTick,
              builder: (context, _) =>
                  PaletteBackdrop(palette: _paletteFor(state, opened)),
            ),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                screenPadding,
                screenPadding,
                screenPadding,
                screenPadding,
              ),
              child: Row(
                children: [
                  if (opened != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Back',
                      onPressed: state.closePlaylist,
                    ),
                  Expanded(
                    child: Text(
                      opened?.playlist.title ?? 'Library',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  if (opened != null && opened.editable)
                    M3EPopupMenuButton<_PlaylistMenuAction>(
                      tooltip: 'More actions',
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (action) => _handlePlaylistEdit(
                        context,
                        state,
                        opened,
                        action == _PlaylistMenuAction.rename
                            ? 'rename'
                            : 'delete',
                      ),
                      itemBuilder: (context) => [
                        const M3EPopupMenuItem<_PlaylistMenuAction>(
                          value: _PlaylistMenuAction.rename,
                          child: Row(
                            children: [
                              Icon(Icons.drive_file_rename_outline_rounded),
                              SizedBox(width: 12),
                              Text('Rename playlist'),
                            ],
                          ),
                        ),
                        const M3EPopupMenuItem<_PlaylistMenuAction>(
                          value: _PlaylistMenuAction.delete,
                          child: Row(
                            children: [
                              Icon(Icons.delete_rounded),
                              SizedBox(width: 12),
                              Text('Delete playlist'),
                            ],
                          ),
                        ),
                      ],
                    )
                  else if (opened == null)
                    IconButton(
                      icon: const Icon(Icons.settings_rounded),
                      tooltip: 'Settings',
                      onPressed: () => state.go(Screen.settings),
                    ),
                ],
              ),
            ),
            if (opened != null)
              Expanded(child: _openPlaylist(context, state, opened))
            else if (account == null)
              _signInPrompt(context, state)
            else
              Expanded(child: _tabs(context, state)),
          ],
        ),
        if (account != null && opened == null)
          Positioned(
            // Clear the floating mini player bar.
            right: screenPadding,
            bottom: playerBarClearance,
            child: M3EFloatingActionButton(
              shape: M3EButtonShape.square,
              onPressed: () => _createPlaylist(context, state),
              tooltip: 'New playlist',
              child: const Icon(Icons.playlist_add_rounded),
            ),
          ),
      ],
    );
  }

  /// Prompts for a playlist name, creates it, and reports
  /// the outcome in a SnackBar.
  Future<void> _createPlaylist(BuildContext context, AppState state) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          M3ETextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          M3EFilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) {
      controller.dispose();
      return;
    }
    final id = await state.createPlaylist(name);
    controller.dispose();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          id != null
              ? 'Playlist “$name” created.'
              : 'Could not create the playlist.',
        ),
      ),
    );
  }

  /// Palette for the open-playlist wash. Resolves the same artwork
  /// URL as AlbumPlaylistView (which triggers the computation), so
  /// both read the same cached bands; empty until it lands.
  List<Color> _paletteFor(AppState state, OpenPlaylist opened) {
    final covers = opened.tracks
        .map((t) => t.displayArtwork)
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();
    return state.paletteFor(
          opened.playlist.art ?? (covers.isNotEmpty ? covers.first : null),
        ) ??
        const <Color>[];
  }

  Widget _signInPrompt(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.all(screenPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sign in to see your library, likes and playlists.'),
          const SizedBox(height: 12),
          M3EFilledButton(
            onPressed: () => state.go(Screen.settings),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Widget _openPlaylist(
    BuildContext context,
    AppState state,
    OpenPlaylist opened,
  ) {
    final pl = opened.playlist;
    // Narrow selects: playlist view rebuilds only when the liked
    // note or the account fields it paints actually change.
    final note = context.select<AppState, String?>((s) => s.likedLoadNote);
    final account = context.select<AppState, String?>((s) => s.account);
    final accountAvatar = context.select<AppState, String?>(
      (s) => s.accountAvatar,
    );
    return AlbumPlaylistView(
      title: pl.title,
      subtitle: pl.id == '__liked'
          ? (note == null ? 'Automatic playlist' : 'Automatic playlist · $note')
          : opened.subtitle,
      description: '',
      art: pl.art,
      arts: playlistViewArts(pl),
      owner: pl.id == '__liked'
          ? (account != null ? ArtistRef(account) : null)
          : (opened.author ??
                (pl.owner.isEmpty
                    ? null
                    : ArtistRef(
                        pl.owner,
                        browseId: pl.ownerId.isEmpty ? null : pl.ownerId,
                      ))),
      ownerAvatarUrl: pl.id == '__liked' ? accountAvatar : null,
      tracks: opened.tracks,
      numbered: false,
      topPadding: 16,
      // libraryLoading rides the palette of list-empty states: select
      // it so skeleton fills only appear while loading fresh.
      listLoading:
          context.select<AppState, bool>((s) => s.libraryLoading) &&
          opened.tracks.isEmpty,
      // Only playlists the account can edit show remove actions; public
      // and read-only lists opened from any surface look the same.
      removable: opened.editable,
      onRemoveTrack: opened.editable
          ? (t) => state.removeTrackFromPlaylist(pl.id, t)
          : null,
    );
  }

  /// Renames or deletes the open playlist from the header menu.
  Future<void> _handlePlaylistEdit(
    BuildContext context,
    AppState state,
    OpenPlaylist opened,
    String action,
  ) async {
    if (action == 'rename') {
      final controller = TextEditingController(text: opened.playlist.title);
      final newName = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
          actions: [
            M3ETextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            M3EFilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      if (newName == null ||
          newName.isEmpty ||
          newName == opened.playlist.title) {
        controller.dispose();
        return;
      }
      final ok = await state.renamePlaylist(opened.playlist.id, newName);
      controller.dispose();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Playlist renamed.' : 'Could not rename the playlist.',
          ),
        ),
      );
      return;
    }
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete playlist?'),
          content: Text(
            '“${opened.playlist.title}” will be deleted. '
            'This cannot be undone.',
          ),
          actions: [
            M3ETextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            M3EFilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final ok = await state.deletePlaylist(opened.playlist.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Playlist deleted.' : 'Could not delete the playlist.',
          ),
        ),
      );
    }
  }

  Widget _tabs(BuildContext context, AppState state) {
    // Narrow selects: tabs re-render only for loading-state change
    // and count changes, not for every app notification.
    final loading = context.select<AppState, bool>(
      (s) => s.libraryLoading && s.playlists.isEmpty,
    );
    final counts = context.select<AppState, (int, int)>(
      (s) => (s.playlists.length, s.artists.length),
    );
    if (loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final tabs = ['Playlists (${counts.$1})', 'Artists (${counts.$2})'];
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(tabs: [for (final t in tabs) Tab(text: t)]),
          Expanded(
            child: TabBarView(
              children: [
                _playlistsTab(context, state),
                _artistsTab(context, state),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _playlistsTab(BuildContext context, AppState state) {
    // Identity-stable select: identical playlists (unchanged order) do
    // not trigger a layout pass.
    final playlists = context.select<AppState, List<AccountPlaylist>>(
      (s) => s.playlists,
    );
    if (playlists.isEmpty) {
      return const Center(child: Text('No playlists yet.'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = (constraints.maxWidth / 150).floor().clamp(2, 8);
        return SilkyGridView.builder(
          scrollSpeed: 1.5,
          silkyScrollDuration: const Duration(milliseconds: 700),
          animationCurve: Curves.easeOutQuart,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            childAspectRatio: 1.0,
          ),
          padding: const EdgeInsets.fromLTRB(
            screenPadding,
            screenPadding,
            screenPadding,
            screenPadding + playerBarClearance,
          ),
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final pl = playlists[index];
            return QuickPickCard(
              title: pl.title,
              subtitle: '${pl.itemCount} songs',
              art: pl.art ?? (pl.arts.isNotEmpty ? pl.arts.first : null),
              onTap: () => state.openPlaylist(pl),
            );
          },
        );
      },
    );
  }

  Widget _artistsTab(BuildContext context, AppState state) {
    // Narrow selects: artist rails rebuild only when roster or
    // listening history changes.
    final artists = context.select<AppState, List<BrowseItem>>(
      (s) => s.artists,
    );
    final recent = context.select<AppState, List<BrowseItem>>(
      (s) => s.recentArtists,
    );
    return screenList(
      children: [
        BrowseRail(
          title: 'Followed',
          items: artists,
          circular: true,
          onOpen: (item) => state.go(Screen.detail, detail: item),
        ),
        Text(
          'Recently listened',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        for (final a in recent)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 2,
            ),
            onTap: () => state.go(Screen.detail, detail: a),
            leading: ArtworkImage(
              a.thumbnails.isEmpty
                  ? null
                  : a.thumbnails
                        .reduce((x, y) => x.width >= y.width ? x : y)
                        .url,
              size: 48,
              circular: true,
              iconSize: 24,
            ),
            title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              a.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
