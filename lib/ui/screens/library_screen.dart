// Library screen ported from Kotlin `LibraryPanel`: tabbed playlists,
// artists and liked songs, plus the open-playlist view.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/album_panel.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cards.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

import '../widgets/palette_backdrop.dart';

/// Account library (playlists, artists, liked songs).
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final opened = state.openedPlaylist;
    // Backdrop fills the whole screen, header row included: the
    // title and settings icon sit on the wash, like Now Playing.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (opened != null && state.account != null)
          RepaintBoundary(
            child: PaletteBackdrop(palette: _paletteFor(state, opened)),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                screenPadding,
                screenPadding,
                screenPadding,
                0,
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
                  if (opened == null)
                    IconButton(
                      icon: const Icon(Icons.settings_rounded),
                      tooltip: 'Settings',
                      onPressed: () => state.go(Screen.settings),
                    ),
                ],
              ),
            ),
            if (state.account == null)
              _signInPrompt(context, state)
            else if (opened != null)
              Expanded(child: _openPlaylist(context, state, opened))
            else
              Expanded(child: _tabs(context, state)),
          ],
        ),
      ],
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
          FilledButton(
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
    return AlbumPlaylistView(
      title: pl.title,
      subtitle: pl.id == '__liked' ? 'Automatic playlist' : '',
      description: '',
      art: pl.art,
      arts: pl.arts,
      owner: pl.id == '__liked'
          ? (state.account != null ? ArtistRef(state.account!) : null)
          : (pl.owner.isEmpty
                ? null
                : ArtistRef(
                    pl.owner,
                    browseId: pl.ownerId.isEmpty ? null : pl.ownerId,
                  )),
      ownerAvatarUrl: pl.id == '__liked' ? state.accountAvatar : null,
      tracks: opened.tracks,
      numbered: false,
      topPadding: 16,
      listLoading: state.libraryLoading && opened.tracks.isEmpty,
    );
  }

  Widget _tabs(BuildContext context, AppState state) {
    if (state.libraryLoading && state.playlists.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final tabs = [
      'Playlists (${state.playlists.length})',
      'Artists (${state.artists.length})',
      'Liked (${state.liked.length})',
    ];
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(tabs: [for (final t in tabs) Tab(text: t)]),
          Expanded(
            child: TabBarView(
              children: [
                _playlistsTab(context, state),
                _artistsTab(context, state),
                _likedTab(context, state),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _playlistsTab(BuildContext context, AppState state) {
    if (state.playlists.isEmpty) {
      return const Center(child: Text('No playlists yet.'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = (constraints.maxWidth / 150).floor().clamp(2, 8);
        return GridView.count(
          crossAxisCount: cols,
          padding: const EdgeInsets.fromLTRB(
            screenPadding,
            screenPadding,
            screenPadding,
            screenPadding + playerBarClearance,
          ),
          // Square cells for the square overlay tiles; anything else
          // leaves an empty band that reads as a non-square tile.
          childAspectRatio: 1.0,
          children: [
            for (final pl in state.playlists)
              QuickPickCard(
                title: pl.title,
                subtitle: '${pl.itemCount} songs',
                art: pl.art ?? (pl.arts.isNotEmpty ? pl.arts.first : null),
                onTap: () => state.openPlaylist(pl),
              ),
          ],
        );
      },
    );
  }

  Widget _artistsTab(BuildContext context, AppState state) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        screenPadding,
        screenPadding,
        screenPadding,
        screenPadding + playerBarClearance,
      ),
      children: [
        BrowseRail(
          title: 'Followed',
          items: state.artists,
          circular: true,
          onOpen: (item) => state.go(Screen.detail, detail: item),
        ),
        Text(
          'Recently listened',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        for (final a in state.recentArtists)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 2,
            ),
            onTap: () => state.go(Screen.detail, detail: a),
            leading: ArtworkImage(
              a.thumbnails.isEmpty ? null : a.thumbnails.first.url,
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

  Widget _likedTab(BuildContext context, AppState state) {
    final liked = state.liked;
    final playingId = state.playerState.current?.videoId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            screenPadding,
            8,
            screenPadding,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${liked.length} songs',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: liked.isEmpty
                    ? null
                    : () => state.playSongs(liked, 0),
                child: const Text('Play all'),
              ),
              IconButton(
                icon: const Icon(Icons.shuffle_rounded),
                tooltip: 'Shuffle',
                onPressed: liked.isEmpty
                    ? null
                    : () => state.playShuffled(liked),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              screenPadding,
              0,
              screenPadding,
              screenPadding + playerBarClearance,
            ),
            itemCount: liked.length,
            itemBuilder: (context, i) {
              final t = liked[i];
              return TrackRow(
                track: t,
                playing: t.videoId == playingId,
                onPlay: () => state.playSongs(liked, i),
                rateable: true,
                showPlaylists: true,
              );
            },
          ),
        ),
      ],
    );
  }
}
