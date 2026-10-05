// Home screen ported from Kotlin `HomePanel`: greeting, mood chips,
// personal quick picks, discover rail, and content shelves.

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cards.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Home screen with greeting, mood chips, personal quick picks, discover
/// rail, and content shelves.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final home = state.home;
    if (home.loading && home.shelves.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (home.error != null && home.shelves.isEmpty) {
      return Center(
        child: ErrorBox(message: home.error!, onRetry: () => state.loadHome()),
      );
    }
    final quickPicks = _quickPicks(state);
    final showPersonalPicks = state.account != null && quickPicks.length >= 6;
    final shelves = showPersonalPicks
        ? home.shelves
              .where((s) => s.title.toLowerCase() != 'quick picks')
              .toList()
        : home.shelves;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Theme.of(context).colorScheme.primaryContainer
                .withValues(alpha: 0.35),
            Theme.of(context).colorScheme.surface,
          ],
          stops: const [0.0, 0.45],
        ),
      ),
      child: ListView(
        // Bottom clearance for the floating player bar overlay.
        padding: const EdgeInsets.fromLTRB(
          screenPadding,
          screenPadding,
          screenPadding,
          screenPadding + playerBarClearance,
        ),
        children: [
          _greeting(context, state),
          const SizedBox(height: 12),
          _moods(context, state),
          const SizedBox(height: 16),
          if (showPersonalPicks) ...[
            _personal(context, state, quickPicks),
            const SizedBox(height: 20),
          ] else if (state.account != null && state.activity.isNotEmpty) ...[
            _jumpBackIn(context, state),
            const SizedBox(height: 20),
          ],
          if (state.discover.isNotEmpty) ...[
            _discover(context, state),
            const SizedBox(height: 20),
          ],
          for (final shelf in shelves) ...[
            _ShelfSection(shelf: shelf),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  /// Personal quick picks: 8 recent songs, 6 artists, then 4 playlists,
  /// mirroring Kotlin `HomePanel` (capped at 18 total).
  List<ShelfItem> _quickPicks(AppState state) {
    final out = <ShelfItem>[];
    final seenTracks = <String>{};
    for (final t in state.activity) {
      if (t.videoId.isEmpty || !seenTracks.add(t.videoId)) continue;
      out.add(ShelfItem.song(t));
      if (out.length >= 8) break;
    }
    final seenBrowse = <String>{};
    for (final b in [...state.recentArtists, ...state.artists]) {
      if (b.browseId.isEmpty || !seenBrowse.add(b.browseId)) continue;
      out.add(b);
      // 8 songs + 6 artists; playlists always keep their 4 slots below.
      if (out.length >= 14) break;
    }
    for (final pl in state.playlists.where((p) => p.id != '__liked').take(4)) {
      final thumbs =
          (pl.arts.isNotEmpty ? pl.arts : [if (pl.art != null) pl.art!])
              .map((u) => Thumbnail(u))
              .toList();
      final owner = [
        pl.owner,
        '${pl.itemCount} songs',
      ].where((s) => s.trim().isNotEmpty).join(' • ');
      out.add(
        ShelfItem.browse(
          title: pl.title,
          subtitle: owner,
          browseId: pl.id,
          thumbnails: thumbs,
        ),
      );
    }
    return out.take(18).toList();
  }

  Widget _greeting(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final hour = DateTime.now().hour;
    final greeting = hour >= 5 && hour <= 11
        ? 'Good morning'
        : hour >= 12 && hour <= 17
        ? 'Good afternoon'
        : 'Good evening';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (state.account != null) ...[
              if (state.accountAvatar != null &&
                  state.accountAvatar!.isNotEmpty)
                ArtworkImage(
                  state.accountAvatar,
                  size: 44,
                  circular: true,
                  iconSize: 24,
                )
              else
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surfaceContainerHigh,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    state.account!.substring(0, 1).toUpperCase(),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    greeting,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (state.account != null)
                    Text(
                      state.account!,
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _moods(BuildContext context, AppState state) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: AppState.moods.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final mood = AppState.moods[i];
          return ActionChip(
            label: Text(mood),
            onPressed: () => state.searchAndGo(mood),
          );
        },
      ),
    );
  }

  Widget _personal(
    BuildContext context,
    AppState state,
    List<ShelfItem> picks,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final grid = _QuickPicksGrid(picks: picks);
        if (!wide) {
          // Narrow: liked list capped at 400px like Kotlin, scrolling inside.
          return Column(
            children: [
              grid,
              const SizedBox(height: 16),
              SizedBox(height: 400, child: _LikedSideList(liked: state.liked)),
            ],
          );
        }
        // Wide: cut the liked list to the grid's exact height so its rows
        // scroll/clip where the quick-pick tiles end (Kotlin measurement).
        final gridW = (constraints.maxWidth - 16) * 155 / 255;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 155, child: grid),
            const SizedBox(width: 16),
            Expanded(
              flex: 100,
              child: SizedBox(
                height: quickPicksHeight(gridW, picks.length),
                child: _LikedSideList(liked: state.liked),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _jumpBackIn(BuildContext context, AppState state) {
    final playingId = state.playerState.current?.videoId;
    final tracks = state.activity.take(14).toList();
    return CardRail(
      title: 'Jump back in',
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        return TrackRailCard(
          track: t,
          playing: t.videoId == playingId,
          onTap: () => state.playSongs(state.activity, i),
        );
      },
    );
  }

  Widget _discover(BuildContext context, AppState state) {
    final playingId = state.playerState.current?.videoId;
    return CardRail(
      title: 'Discover',
      trailing: TextButton(
        onPressed: () => state.playSongs(state.discover, 0),
        child: const Text('Play all'),
      ),
      itemCount: state.discover.length,
      itemBuilder: (context, i) {
        final t = state.discover[i];
        return TrackRailCard(
          track: t,
          playing: t.videoId == playingId,
          onTap: () => state.playSongs(state.discover, i),
        );
      },
    );
  }
}

/// Grid geometry shared by [_QuickPicksGrid] and the liked-list height
/// computation, so both agree on the rendered grid height.
({int cols, int shown, int rows, double tile}) quickPickMetrics(
  double gridWidth,
  int pickCount,
) {
  final cols = (gridWidth / 170).floor().clamp(3, 6);
  final shown = pickCount.clamp(0, cols * 3);
  final rows = (shown / cols).ceil().clamp(1, 3);
  final tile = gridWidth / cols;
  return (cols: cols, shown: shown, rows: rows, tile: tile);
}

/// Full rendered height of [_QuickPicksGrid] for [gridWidth]: 48px header
/// row (IconButtons) + 8px spacing + the tile grid.
double quickPicksHeight(double gridWidth, int pickCount) {
  final m = quickPickMetrics(gridWidth, pickCount);
  return 48 + 8 + m.rows * m.tile;
}

/// Responsive quick-picks grid of overlay tiles with play/shuffle actions.
class _QuickPicksGrid extends StatelessWidget {
  const _QuickPicksGrid({required this.picks});

  final List<ShelfItem> picks;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final gridSongs = picks.whereType<SongItem>().map((e) => e.track).toList();
    void open(ShelfItem item) {
      if (item is SongItem) {
        var idx = gridSongs.indexWhere((t) => t.videoId == item.track.videoId);
        if (idx < 0) idx = 0;
        state.playSongs(gridSongs, idx);
      } else if (item is BrowseItem) {
        if (item.browseId.startsWith('UC')) {
          state.go(Screen.detail, detail: item);
        } else {
          state.openPlaylistById(item.browseId);
        }
      }
    }

    Widget tile(ShelfItem item) {
      if (item is SongItem) {
        final t = item.track;
        return QuickPickCard(
          title: t.title,
          subtitle: t.artistNames(),
          art: t.displayArtwork,
          playing: t.videoId == playingId,
          onTap: () => open(item),
        );
      }
      final b = item as BrowseItem;
      final art = b.thumbnails.isEmpty
          ? null
          : b.thumbnails.reduce((a, c) => a.width >= c.width ? a : c).url;
      return QuickPickCard(
        title: b.title,
        subtitle: b.subtitle,
        art: art,
        playing: false,
        onTap: () => open(item),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Quick picks',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded),
              tooltip: 'Play quick picks',
              onPressed: gridSongs.isEmpty
                  ? null
                  : () => state.playSongs(gridSongs, 0),
            ),
            IconButton(
              icon: const Icon(Icons.shuffle_rounded),
              tooltip: 'Shuffle quick picks',
              onPressed: gridSongs.isEmpty
                  ? null
                  : () => state.playShuffled(gridSongs),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final m = quickPickMetrics(constraints.maxWidth, picks.length);
            final shown = picks.take(m.shown).toList();
            // Fixed height from the column count so the grid stays lazy:
            // a shrink-wrapped grid would build all 18 tiles eagerly.
            return SizedBox(
              height: m.rows * m.tile,
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: m.cols,
                  childAspectRatio: 1,
                ),
                physics: const NeverScrollableScrollPhysics(),
                itemCount: shown.length,
                itemBuilder: (context, i) => tile(shown[i]),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Liked songs list: rows under a header with Play all. Fills the height
/// given by the parent (grid height on wide windows, 400px when stacked)
/// with the rows scrolling inside, like Kotlin's measured column.
class _LikedSideList extends StatelessWidget {
  const _LikedSideList({required this.liked});

  final List<Track> liked;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Liked songs',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            TextButton(
              onPressed: liked.isEmpty ? null : () => state.playSongs(liked, 0),
              child: const Text('Play all'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
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

/// One home shelf: song-only shelves as a track column, mixed shelves as
/// a browse rail.
class _ShelfSection extends StatelessWidget {
  const _ShelfSection({required this.shelf});

  final Shelf shelf;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final songs = shelf.items
        .whereType<SongItem>()
        .map((e) => e.track)
        .toList();
    final browses = shelf.items.whereType<BrowseItem>().toList();
    if (songs.isNotEmpty && browses.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              shelf.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (var i = 0; i < songs.length; i++)
            TrackRow(
              track: songs[i],
              playing: songs[i].videoId == playingId,
              onPlay: () => state.playSongs(songs, i),
              rateable: true,
              showPlaylists: true,
            ),
        ],
      );
    }
    return CardRail(
      title: shelf.title,
      trailing: TextButton(onPressed: () {}, child: const Text('Altro')),
      itemCount: shelf.items.length,
      itemBuilder: (context, i) {
        final item = shelf.items[i];
        if (item is SongItem) {
          final t = item.track;
          return BrowseCard(
            item: BrowseItem(
              title: t.title,
              subtitle: t.artistNames(),
              browseId: '',
              thumbnails: t.thumbnails,
            ),
            onTap: () {
              var idx = songs.indexWhere((s) => s.videoId == t.videoId);
              if (idx < 0) idx = 0;
              state.playSongs(songs, idx);
            },
          );
        }
        final b = item as BrowseItem;
        return BrowseCard(
          item: b,
          onTap: () => state.go(Screen.detail, detail: b),
        );
      },
    );
  }
}
