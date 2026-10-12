// Home screen ported from Kotlin `HomePanel`: greeting, mood chips,
// personal quick picks, discover rail, and content shelves.

import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/innertube/gdata_api.dart';
import '../../core/innertube/parse.dart';
import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cards.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Home screen with greeting, mood chips, personal quick picks, discover
/// rail, and content shelves.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // HomeUiState is immutable (copyWith reassigns), so select detects
    // changes by identity; the other fields it reads are all reassigned
    // values too. The screen therefore rebuilds only when the home feed
    // or one of its personalization inputs actually changes.
    final home = context.select<AppState, HomeUiState>((s) => s.home);
    final account = context.select<AppState, String?>((s) => s.account);
    final activity = context.select<AppState, List<Track>>((s) => s.activity);
    final recentArtists =
        context.select<AppState, List<BrowseItem>>((s) => s.recentArtists);
    final artists =
        context.select<AppState, List<BrowseItem>>((s) => s.artists);
    final playlists =
        context.select<AppState, List<GPlaylist>>((s) => s.playlists);
    final discover = context.select<AppState, List<Track>>((s) => s.discover);
    final liked = context.select<AppState, List<Track>>((s) => s.liked);
    final pins = context.select<AppState, List<ShelfItem>>(
      (s) => s.pinnedPicks,
    );
    final accountAvatar =
        context.select<AppState, String?>((s) => s.accountAvatar);
    final libraryLoading =
        context.select<AppState, bool>((s) => s.libraryLoading);
    final state = context.read<AppState>();
    final loading = home.loading && home.shelves.isEmpty;
    if (home.error != null && home.shelves.isEmpty) {
      return Center(
        child: ErrorBox(message: home.error!, onRetry: () => state.loadHome()),
      );
    }
    final pools = _buildPools(
      activity: activity,
      recentArtists: recentArtists,
      artists: artists,
      playlists: playlists,
    );
    final showPersonalPicks =
        account != null && (pools.songs.length + pools.nonSongs.length) >= 6;
    final shelves = showPersonalPicks
        ? home.shelves
              .where((s) => s.title.toLowerCase() != 'quick picks')
              .toList()
        : home.shelves;
    // Rows about the user first: shelves overlapping their history,
    // liked songs, artists, or personalized mix seeds outrank generic
    // editorial rows. Empty profile (signed out) preserves feed order.
    final rankedShelves = loading
        ? _placeholderShelves()
        : rankShelvesByProfile(
            shelves,
            trackIds: {
              for (final t in activity) t.videoId,
              for (final t in liked) t.videoId,
            },
            artistKeys: shelfArtistKeys(
              artists: [...recentArtists, ...artists],
              tracks: [...activity, ...liked],
            ),
          );
    // The quick-picks grid keeps its skeleton until ITS data (account +
    // library: activity/artists/playlists) is loaded — not just until the
    // home shelves land — so it never shimmers, disappears, then pops in.
    // Only signed-in users get it.
    final gridLoading = loading || (account != null && libraryLoading);
    final gridPools = gridLoading ? _skeletonPools() : pools;
    final showGrid = gridLoading ? account != null : showPersonalPicks;
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
      child: Skeletonizer(
        // While the feed loads, the whole layout renders as skeletons and
        // reveals in place (the shimmer comes from the theme config).
        enabled: loading,
        enableSwitchAnimation: true,
        child: ListView(
          // Bottom clearance for the floating player bar overlay.
          padding: const EdgeInsets.fromLTRB(
            screenPadding,
            screenPadding,
            screenPadding,
            screenPadding + playerBarClearance,
          ),
          children: [
            _greeting(context, account: account, accountAvatar: accountAvatar),
            const SizedBox(height: 12),
            _moods(context, state),
            // Personal block next, no matter what: the quick-picks
            // grid + liked list (or the jump-back-in fallback on
            // sparse accounts) always render above mixes, discover
            // and shelves.
            if (showGrid) ...[
              // Own skeleton scope: the grid keeps shimmering until its
              // own data (library) is ready, independent of the shelves.
              // Pins stay out of skeleton pools (never mix real pins
              // with placeholders).
              Skeletonizer(
                enabled: gridLoading,
                enableSwitchAnimation: true,
                child: _personal(
                  context,
                  state,
                  gridPools,
                  pins: gridLoading ? const <ShelfItem>[] : pins,
                ),
              ),
              const SizedBox(height: 20),
            ] else if (!loading && account != null && activity.isNotEmpty) ...[
              _jumpBackIn(context, state),
              const SizedBox(height: 20),
            ],
            _mixes(context, state, loading),
            if (!loading && discover.isNotEmpty) ...[
              _discover(context, state),
              const SizedBox(height: 20),
            ],
            for (final shelf in rankedShelves) ...[
              _ShelfSection(shelf: shelf),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the quick-picks source pools: recent songs and browsable
  /// entries (recently played albums, followed artists, and playlists).
  /// The grid interleaves them pseudo-randomly, filling every cell.
  ({List<ShelfItem> songs, List<ShelfItem> nonSongs}) _buildPools({
    required List<Track> activity,
    required List<BrowseItem> recentArtists,
    required List<BrowseItem> artists,
    required List<GPlaylist> playlists,
  }) {
    final songs = <ShelfItem>[];
    final seenTracks = <String>{};
    for (final t in activity) {
      if (t.videoId.isEmpty || !seenTracks.add(t.videoId)) continue;
      songs.add(ShelfItem.song(t));
    }

    final nonSongs = <ShelfItem>[];
    final seenBrowse = <String>{};
    void addBrowse(String? id, ShelfItem Function() build) {
      if (id == null || id.isEmpty || !seenBrowse.add(id)) return;
      nonSongs.add(build());
    }

    // Recently played albums, derived from activity track credits.
    // Singles are skipped: the song tile already covers them
    // (see isSingleRelease). EPs and albums always stay.
    for (final t in activity) {
      final a = t.album;
      if (a == null || a.browseId == null || a.browseId!.isEmpty) continue;
      if (isSingleRelease(t)) continue;
      addBrowse(a.browseId, () => ShelfItem.browse(
            title: a.name,
            subtitle: 'Album',
            browseId: a.browseId!,
            thumbnails: t.thumbnails.isNotEmpty
                ? t.thumbnails
                : const <Thumbnail>[],
          ));
    }

    for (final b in [...recentArtists, ...artists]) {
      addBrowse(b.browseId, () => b);
    }

    for (final pl in playlists.where((p) => p.id != '__liked')) {
      addBrowse(pl.id, () {
        final thumbs =
            (pl.arts.isNotEmpty ? pl.arts : [if (pl.art != null) pl.art!])
                .map((u) => Thumbnail(u))
                .toList();
        final owner = [
          pl.owner,
          '${pl.itemCount} songs',
        ].where((s) => s.trim().isNotEmpty).join(' • ');
        return ShelfItem.browse(
          title: pl.title,
          subtitle: owner,
          browseId: pl.id,
          thumbnails: thumbs,
        );
      });
    }

    return (songs: songs, nonSongs: nonSongs);
  }

  /// Placeholder source pools for the quick-picks grid while the personal
  /// data loads, so the grid is skeletonized instead of popping in later.
  ({List<ShelfItem> songs, List<ShelfItem> nonSongs}) _skeletonPools() {
    return (
      songs: [
        for (var i = 0; i < 8; i++)
          ShelfItem.song(
            Track(
              videoId: 'skeleton-song-$i',
              title: 'Song title',
              artists: const [],
              thumbnails: const [],
            ),
          ),
      ],
      nonSongs: [
        for (var i = 0; i < 6; i++)
          ShelfItem.browse(
            title: 'Album title',
            subtitle: 'Artist name',
            browseId: 'skeleton-browse-$i',
            thumbnails: const [],
          ),
      ],
    );
  }

  /// Placeholder shelves rendered (skeletonized) while the home feed
  /// loads, so the page shows a stable layout instead of a spinner followed
  /// by content popping in. Replaced by the real shelves once loaded.
  List<Shelf> _placeholderShelves() {
    SongItem song(int i) => SongItem(
          Track(
            videoId: 'skeleton-$i',
            title: 'Song title',
            artists: const [],
            thumbnails: const [],
          ),
        );
    ShelfItem browse(int i) => ShelfItem.browse(
          title: 'Album title',
          subtitle: 'Artist name',
          browseId: 'skeleton-b$i',
          thumbnails: const [],
        );
    return [
      // A vertical track-list shelf and two horizontal tile rails give a
      // realistic skeleton of a typical feed.
      Shelf('', [for (var i = 0; i < 5; i++) song(i)]),
      Shelf('', [for (var i = 0; i < 6; i++) browse(i)]),
      Shelf('', [for (var i = 0; i < 6; i++) song(10 + i)]),
    ];
  }

  Widget _greeting(
    BuildContext context, {
    required String? account,
    required String? accountAvatar,
  }) {
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
            if (account != null) ...[
              if (accountAvatar != null && accountAvatar.isNotEmpty)
                ArtworkImage(
                  accountAvatar,
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
                    account.substring(0, 1).toUpperCase(),
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
                  if (account != null)
                    Text(
                      account,
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

  /// Mood filter chips straight from the home feed's chip cloud
  /// (feed order, locale-aware). Hidden while the feed loads or when
  /// it carries no chips — never hardcoded.
  Widget _moods(BuildContext context, AppState state) {
    final moods = context.select<AppState, List<String>>((s) => s.home.moods);
    if (moods.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: moods.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final mood = moods[i];
              return ActionChip(
                label: Text(mood),
                onPressed: () => state.searchAndGo(mood),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// InnerTube's custom mixes (mood playlists plus personalized
  /// seeds) lifted into one tap-to-play rail. Skeleton placeholders
  /// while loading so the section never pops the layout.
  Widget _mixes(BuildContext context, AppState state, bool loading) {
    final items =
        loading ? placeholderMixes : AppState.mixesOfShelves(state.home.shelves);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        CardRail(
          title: 'Mixed for you',
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            return BrowseCard(
              item: BrowseItem(
                title: item.title,
                subtitle: item.subtitle,
                browseId: item.browseId ?? '',
                thumbnails: item.thumbnails,
              ),
              onTap: loading ? () {} : () => state.playMix(item),
            );
          },
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _personal(
    BuildContext context,
    AppState state,
    ({
      List<ShelfItem> songs,
      List<ShelfItem> nonSongs,
    })
    pools, {
    List<ShelfItem> pins = const [],
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final grid = _QuickPicksGrid(pools: pools, pins: pins);
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
                height: quickPicksHeight(
                  gridW,
                  pools.songs.length + pools.nonSongs.length,
                ),
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
      trailing: M3ETextButton(
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
///
/// The grid never repeats an item, so it can only show as many cells as
/// there are distinct sources: rows shrink below 3 when sources are few.
({int cols, int shown, int rows, double tile}) quickPickMetrics(
  double gridWidth,
  int pickCount,
) {
  final cols = (gridWidth / 170).floor().clamp(3, 6);
  final shown = pickCount.clamp(0, cols * 3);
  final rows = shown == 0 ? 0 : (shown / cols).ceil();
  final tile = gridWidth / cols;
  return (cols: cols, shown: shown, rows: rows, tile: tile);
}

/// Full rendered height of [_QuickPicksGrid] for [gridWidth]: 48px header
/// row (IconButtons) + 8px spacing + the (3-row) tile grid.
double quickPicksHeight(double gridWidth, int pickCount) {
  final m = quickPickMetrics(gridWidth, pickCount);
  return 48 + 8 + m.rows * m.tile;
}

/// True when [track]'s album tile would duplicate its song tile:
/// only explicit Single releases. Same-named EPs and albums stay —
/// they are genuinely different releases that happen to share the
/// track's title.
bool isSingleRelease(Track track) {
  final album = track.album;
  if (album == null) return false;
  return album.kind == ReleaseKind.single;
}

/// Final quick-picks order: user pins first (pin order), then the
/// rotating pools with pinned ids excluded so nothing repeats.
/// Pure for unit tests; the grid subscribes to the inputs.
List<ShelfItem> buildQuickPickItems({
  required List<ShelfItem> pins,
  required List<ShelfItem> songs,
  required List<ShelfItem> nonSongs,
  required int slots,
  required Random rng,
}) {
  final seen = <String>{};
  bool fresh(ShelfItem item) {
    final k = AppState.pickKeyOf(item);
    if (k == null) return true;
    return seen.add(k);
  }

  final out = <ShelfItem>[];
  for (final p in pins) {
    if (out.length >= slots) break;
    if (!fresh(p)) continue;
    out.add(p);
  }
  if (out.length >= slots) return out;
  out.addAll(
    fillQuickPicks(
      [for (final s in songs) if (fresh(s)) s],
      [for (final n in nonSongs) if (fresh(n)) n],
      slots - out.length,
      rng: rng,
    ),
  );
  return out;
}

/// Deterministic pseudo-random seed derived from the source identities, so
/// the grid order is stable across rebuilds and only reshuffles when the
/// underlying data changes. Callers mix in a per-launch nonce
/// ([AppState.quickPicksNonce]) so separate app starts rotate.
int _picksSeed(List<ShelfItem> songs, List<ShelfItem> nonSongs) {
  var h = 17;
  for (final item in songs) {
    h = (h * 31 + (item as SongItem).track.videoId.hashCode) & 0x7fffffff;
  }
  for (final item in nonSongs) {
    h = (h * 31 + (item as BrowseItem).browseId.hashCode) & 0x7fffffff;
  }
  return h;
}

/// Fills up to [slots] cells from [songs] and [nonSongs] in pseudo-random
/// order, never placing two non-song entries (albums/artists/playlists)
/// adjacent and never repeating an item. Both pools are consumed from the
/// front (most recent first), so recent songs/albums/artists/playlists are
/// preferred over older ones; if the pools run dry the grid simply shows
/// what it has.
List<ShelfItem> fillQuickPicks(
  List<ShelfItem> songs,
  List<ShelfItem> nonSongs,
  int slots, {
  required Random rng,
}) {
  final out = <ShelfItem>[];
  var si = 0;
  var ni = 0;
  while (out.length < slots && (si < songs.length || ni < nonSongs.length)) {
    final lastIsNon = out.isNotEmpty && out.last is BrowseItem;
    final canNon = !lastIsNon && ni < nonSongs.length;
    final canSong = si < songs.length;
    // Prefer a non-song when allowed, but ~30% of the time keep the song
    // run going for pseudo-randomness. A non-song is never placed directly
    // after a non-song.
    final takeNon = canNon && !(canSong && rng.nextDouble() < 0.3);
    if (takeNon) {
      out.add(nonSongs[ni++]);
    } else if (canSong) {
      out.add(songs[si++]);
    } else if (canNon) {
      out.add(nonSongs[ni++]);
    } else {
      break;
    }
  }
  return out;
}

/// Responsive quick-picks grid: fills every cell of a 3-row grid (variable
/// columns) with a pseudo-random mix of songs, albums, artists and
/// playlists, keeping non-song entries apart.
class _QuickPicksGrid extends StatelessWidget {
  const _QuickPicksGrid({required this.pools, this.pins = const []});

  final ({List<ShelfItem> songs, List<ShelfItem> nonSongs}) pools;

  /// User pins, rendered ahead of the rotating pools. Empty while the
  /// grid shows skeletons (pins never mix with placeholders).
  final List<ShelfItem> pins;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final gridSongs =
        pools.songs.whereType<SongItem>().map((e) => e.track).toList();
    void open(ShelfItem item) {
      if (item is SongItem) {
        var idx = gridSongs.indexWhere((t) => t.videoId == item.track.videoId);
        if (idx < 0) idx = 0;
        state.playSongs(gridSongs, idx);
      } else if (item is BrowseItem) {
        final id = item.browseId;
        if (id.startsWith('UC') || id.startsWith('MPRE')) {
          // Artist (UC) or album (MPRE): both open the detail page.
          state.go(Screen.detail, detail: item);
        } else {
          state.openPlaylistById(id);
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

    Widget pickTile(ShelfItem item) {
      Widget t = tile(item);
      if (state.isPinned(item)) {
        final scheme = Theme.of(context).colorScheme;
        t = Stack(
          children: [
            t,
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
                ),
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 14,
                  color: scheme.primary,
                ),
              ),
            ),
          ],
        );
      }
      return GestureDetector(
        onLongPress: () => state.togglePin(item),
        child: t,
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
            final sourceCount =
                pools.songs.length + pools.nonSongs.length;
            final m = quickPickMetrics(constraints.maxWidth, sourceCount);
            // Fill every available cell: pins first, then the pools.
            // The per-launch nonce rotates the grid every app start;
            // the data-derived seed keeps it steady within a session.
            final picks = buildQuickPickItems(
              pins: pins,
              songs: pools.songs,
              nonSongs: pools.nonSongs,
              slots: m.shown,
              rng: Random(
                _picksSeed(pools.songs, pools.nonSongs) ^
                    state.quickPicksNonce,
              ),
            );
            // Fixed height from the column count so the grid stays lazy:
            // a shrink-wrapped grid would build every tile eagerly.
            return SizedBox(
              height: m.rows * m.tile,
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: m.cols,
                  childAspectRatio: 1,
                ),
                physics: const NeverScrollableScrollPhysics(),
                itemCount: picks.length,
                itemBuilder: (context, i) =>
                    pickTile(picks[i]),
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
            M3ETextButton(
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

/// Plays one shelf song: personalized mix seeds open their full mix,
/// plain songs play the shelf list from the tapped position.
void _playShelfSong(AppState state, List<Track> songs, int index) {
  if (index < 0 || index >= songs.length) return;
  final tapped = songs[index];
  if (AppState.isMixSeed(tapped)) {
    state.playMixSeed(tapped);
    return;
  }
  state.playSongs(songs, index);
}

/// One home shelf: song-only shelves as a track column, mixed shelves as
/// a browse rail.
class _ShelfSection extends StatelessWidget {  const _ShelfSection({required this.shelf});

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
              onPlay: () => _playShelfSong(state, songs, i),
              rateable: true,
              showPlaylists: true,
            ),
        ],
      );
    }
    return CardRail(
      title: shelf.title,
      trailing: M3ETextButton(onPressed: () {}, child: const Text('Altro')),
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
              if (AppState.isMixSeed(t)) {
                state.playMixSeed(t);
                return;
              }
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
