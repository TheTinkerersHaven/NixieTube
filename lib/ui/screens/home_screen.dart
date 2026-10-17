// Home screen ported from Kotlin `HomePanel`: greeting, mood chips,
// personal quick picks, discover rail, and content shelves.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cards.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Home screen with greeting, mood chips, the personal block (quick-picks
/// grid + liked songs), and then the pinned sections: Discover, Listen
/// Again, Forgotten favorites, New releases, Albums made for you and the
/// remaining personalized feed rows, with the trending rows (the user's
/// country, then worldwide) last.
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
    // Reassigned (not mutated) on history import, so these selects
    // fire and quick picks re-rank. Local bumps mutate in place but
    // always ride with an activity reassignment, which rebuilds anyway.
    final playCounts = context.select<AppState, Map<String, int>>(
      (s) => s.playCounts,
    );
    final historyTracks = context.select<AppState, List<Track>>(
      (s) => s.historyTracks,
    );
    final discover = context.select<AppState, List<Track>>((s) => s.discover);
    final liked = context.select<AppState, List<Track>>((s) => s.liked);
    final pins = context.select<AppState, List<ShelfItem>>(
      (s) => s.pinnedPicks,
    );
    final accountAvatar = context.select<AppState, String?>(
      (s) => s.accountAvatar,
    );
    final libraryLoading = context.select<AppState, bool>(
      (s) => s.libraryLoading,
    );
    final state = context.read<AppState>();
    final loading = home.loading && home.shelves.isEmpty;
    if (home.error != null && home.shelves.isEmpty) {
      return Center(
        child: ErrorBox(message: home.error!, onRetry: () => state.loadHome()),
      );
    }
    final songs = rankPickSongs(
      activity: activity,
      liked: liked,
      history: historyTracks,
      counts: playCounts,
      nonce: state.quickPicksNonce,
    );
    final showPersonalPicks =
        account != null && (songs.length + pins.length) >= 6;
    // Fixed home sections, sourced from the pinned feeds in section
    // order: the personalized feed carries the user's own rows (Listen
    // again, Forgotten favorites), Explore the stable editorial rails
    // (New releases, Trending) and the Charts feed the worldwide chart.
    // Placeholders while loading keep the layout from popping in.
    final listenAgain = loading
        ? _placeholderSongShelf()
        : firstShelfWithTitle(home.shelves, const ['listen again']);
    final forgotten = loading
        ? _placeholderBrowseShelf()
        : firstShelfWithTitle(home.shelves, const ['forgotten']);
    final newReleases = loading
        ? _placeholderBrowseShelf()
        : firstShelfWithTitle(home.explore, const ['new album', 'new release']);
    // The country row's feed shelf is region-derived, so its header names
    // the country the Charts feed reports; before that lands (or when it
    // is unknown) the shelf keeps its own name.
    final trending = loading
        ? _placeholderSongShelf()
        : firstShelfWithTitle(home.explore, const ['trend']);
    final trendingTitle = home.country == null
        ? 'Trending'
        : 'Trending in ${home.country}';
    final globalTrending = loading
        ? _placeholderSongShelf()
        : home.globalTrending.isEmpty
        ? null
        : Shelf('', [for (final t in home.globalTrending) ShelfItem.song(t)]);
    final recaps = loading
        ? const <Shelf>[]
        : [
            for (final s in home.shelves)
              if (s.title.toLowerCase().contains('recap')) s,
          ];
    // Everything not already pinned above renders after the fixed
    // sections, still ranked so user-overlapping rows come first.
    final leftovers = loading
        ? const <Shelf>[]
        : [
            for (final s in home.shelves)
              if (isLeftoverShelf(
                s.title,
                showingPersonalPicks: showPersonalPicks,
              ))
                s,
          ];
    final rankedShelves = loading
        ? const <Shelf>[]
        : state.rankedHomeShelves(leftovers);
    // The quick-picks grid keeps its skeleton until ITS data (account +
    // library activity) is loaded — not just until the home shelves
    // land — so it never shimmers, disappears, then pops in.
    // Only signed-in users get it.
    final gridLoading = loading || (account != null && libraryLoading);
    final gridSongs = gridLoading ? _skeletonPicks() : songs;
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
            // sparse accounts) always render above the fixed sections.
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
                  gridSongs,
                  pins: gridLoading ? const <ShelfItem>[] : pins,
                ),
              ),
              const SizedBox(height: 20),
            ] else if (!loading && account != null && activity.isNotEmpty) ...[
              _jumpBackIn(context, state),
              const SizedBox(height: 20),
            ],
            // Personal sections first, then the editorial and trending
            // rows. Browsable shelves render as horizontal cover rails;
            // song-only shelves render as columns of rows that scroll
            // sideways, save for the ones asked to read as covers (see
            // [_ShelfSection.songRail]).
            if (!loading && discover.isNotEmpty) ...[
              _discover(context, state),
              const SizedBox(height: 20),
            ],
            if (listenAgain != null) ...[
              _ShelfSection(shelf: listenAgain, title: 'Listen Again'),
              const SizedBox(height: 20),
            ],
            if (forgotten != null) ...[
              _ShelfSection(
                shelf: forgotten,
                title: 'Forgotten favorites',
                songRail: true,
              ),
              const SizedBox(height: 20),
            ],
            if (newReleases != null) ...[
              _ShelfSection(shelf: newReleases, title: 'New releases'),
              const SizedBox(height: 20),
            ],
            _albumsMadeForYou(context, state, loading, recaps),
            for (final shelf in rankedShelves) ...[
              _ShelfSection(shelf: shelf),
              const SizedBox(height: 20),
            ],
            // Trending closes the screen, country first: the region row
            // Explore serves, then the worldwide chart.
            if (trending != null) ...[
              _ShelfSection(shelf: trending, title: trendingTitle),
              const SizedBox(height: 20),
            ],
            if (globalTrending != null) ...[
              _ShelfSection(shelf: globalTrending, title: 'Trending globally'),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );
  }

  /// Placeholder quick-picks while the personal data loads, so the grid
  /// is skeletonized instead of popping in later.
  List<ShelfItem> _skeletonPicks() {
    return [
      for (var i = 0; i < 8; i++)
        ShelfItem.song(
          Track(
            videoId: 'skeleton-song-$i',
            title: 'Song title',
            artists: const [],
            thumbnails: const [],
          ),
        ),
    ];
  }

  /// Placeholder browse rail (6 cards) for a skeleton fixed section, so
  /// the layout shows a stable cover rail instead of popping in later.
  Shelf _placeholderBrowseShelf() => Shelf('', [
    for (var i = 0; i < 6; i++)
      ShelfItem.browse(
        title: 'Album title',
        subtitle: 'Artist name',
        browseId: 'skeleton-b$i',
        thumbnails: const [],
      ),
  ]);

  /// Placeholder song shelf (10 rows) for a skeleton fixed section; the
  /// row columns stack these as two columns of five rows.
  Shelf _placeholderSongShelf() => Shelf('', [
    for (var i = 0; i < 10; i++)
      ShelfItem.song(
        Track(
          videoId: 'skeleton-$i',
          title: 'Song title',
          artists: const [],
          thumbnails: const [],
        ),
      ),
  ]);

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

  /// "Albums made for you": the feed's recaps (browsable, opens its
  /// detail page) plus the user's mixes (tap to play), in one rail.
  /// Skeleton mix placeholders while loading so the section never pops
  /// the layout.
  Widget _albumsMadeForYou(
    BuildContext context,
    AppState state,
    bool loading,
    List<Shelf> recaps,
  ) {
    final mixes = loading ? placeholderMixes : state.mixes;
    final entries = <_MadeForYouEntry>[
      for (final shelf in recaps)
        for (final b in shelf.items.whereType<BrowseItem>())
          _MadeForYouEntry(item: b),
      for (final m in mixes)
        _MadeForYouEntry(
          item: BrowseItem(
            title: m.title,
            subtitle: m.subtitle,
            browseId: m.browseId ?? '',
            thumbnails: m.thumbnails,
          ),
          mix: m,
        ),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        CardRail(
          title: 'Albums made for you',
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final entry = entries[i];
            final mix = entry.mix;
            return BrowseCard(
              item: entry.item,
              onTap: () {
                if (mix != null) {
                  if (!loading) state.playMix(mix);
                  return;
                }
                state.go(Screen.detail, detail: entry.item);
              },
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
    List<ShelfItem> songs, {
    List<ShelfItem> pins = const [],
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final grid = _QuickPicksGrid(songs: songs, pins: pins);
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
                height: quickPicksHeight(gridW, songs.length + pins.length),
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

/// Quick-picks source pool in three tiers: replayed songs first
/// (local or history play count above 1, any source), then recent
/// songs played at most once, then older songs (liked or history
/// tracks out of rotation here). Track objects come activity-first
/// (freshest metadata), then liked, then history. Within each tier,
/// tracks sort by `(_stableHash(videoId) ^ nonce)` — a stable
/// pseudo-random order that varies per launch ([nonce] rotates)
/// without re-dealing when the pool grows: newcomers slot in by
/// hash rank while existing tiles keep their relative order, so
/// background refreshes stop scrambling the grid. Capped at [cap]
/// tracks. Pure for unit tests (also used by the grid tests).
List<ShelfItem> rankPickSongs({
  required List<Track> activity,
  required List<Track> liked,
  required List<Track> history,
  required Map<String, int> counts,
  int cap = 30,
  int nonce = 0,
}) {
  final inActivity = <String>{for (final t in activity) t.videoId};
  final seen = <String>{};
  final replayed = <Track>[];
  final recent = <Track>[];
  final old = <Track>[];
  void consider(Track t) {
    if (t.videoId.isEmpty || !seen.add(t.videoId)) return;
    if ((counts[t.videoId] ?? 0) > 1) {
      replayed.add(t);
    } else if (inActivity.contains(t.videoId)) {
      recent.add(t);
    } else {
      old.add(t);
    }
  }

  for (final t in activity) {
    consider(t);
  }
  for (final t in liked) {
    consider(t);
  }
  for (final t in history) {
    consider(t);
  }
  int hashOrder(Track a, Track b) {
    final c = (_stableHash(a.videoId) ^ nonce).compareTo(
      _stableHash(b.videoId) ^ nonce,
    );
    return c != 0 ? c : a.videoId.compareTo(b.videoId);
  }

  replayed.sort(hashOrder);
  recent.sort(hashOrder);
  old.sort(hashOrder);
  final ordered = [...replayed, ...recent, ...old].take(cap).toList();
  return [for (final t in ordered) ShelfItem.song(t)];
}

/// Deterministic string hash (FNV-1a): unlike [String.hashCode],
/// stable across runs and VMs, so tier orders (and their tests)
/// don't depend on the runtime.
int _stableHash(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// Artwork identity for quick-picks diversity: the same cover is served
/// at many sizes (`…=w60-h60-l90-rj` vs `…=w540-h540-…`), so the size
/// suffix is stripped before comparing. Tracks without art key on
/// their own id so they never collapse each other.
String pickArtKey(Track track) {
  final art = track.displayArtwork;
  if (art == null || art.isEmpty) return 'id:${track.videoId}';
  return art.replaceFirst(RegExp(r'=w\d+-h\d+.*$'), '');
}

/// Final quick-picks order: user pins first (pin order), then pool
/// songs most-recent-first with same-cover tracks held back, then the
/// held-back tracks to fill leftover slots. The grid therefore never
/// shows the same cover twice unless sources run dry — and every tile
/// is a song that plays on tap.
///
/// Per-launch variety comes from the ranked pool ([rankPickSongs]
/// shuffles each tier with the session nonce); this function itself
/// is deterministic.
/// Pure for unit tests; the grid subscribes to the inputs.
List<ShelfItem> orderQuickPicks({
  required List<ShelfItem> pins,
  required List<ShelfItem> songs,
  required int slots,
}) {
  final seenIds = <String>{};
  bool fresh(ShelfItem item) {
    final k = AppState.pickKeyOf(item);
    if (k == null) return true;
    return seenIds.add(k);
  }

  final out = <ShelfItem>[];
  for (final p in pins) {
    if (out.length >= slots) break;
    if (!fresh(p)) continue;
    out.add(p);
  }
  if (out.length >= slots) return out;

  final pool = [
    for (final s in songs)
      if (fresh(s)) s,
  ];

  // Pinned covers count: a pool song sharing a pin's cover waits for
  // the fill pass like any other duplicate.
  final seenArt = <String>{
    for (final p in out)
      if (p is SongItem) pickArtKey(p.track),
  };
  final heldBack = <ShelfItem>[];
  for (final item in pool) {
    if (out.length >= slots) break;
    if (item is SongItem && !seenArt.add(pickArtKey(item.track))) {
      heldBack.add(item);
      continue;
    }
    out.add(item);
  }
  for (final item in heldBack) {
    if (out.length >= slots) break;
    out.add(item);
  }
  return out;
}

/// Responsive quick-picks grid: up to 3 rows of song tiles (variable
/// columns), art-diverse so the same cover never shows twice, with
/// user pins first. Play/shuffle follow the displayed order.
class _QuickPicksGrid extends StatelessWidget {
  const _QuickPicksGrid({required this.songs, this.pins = const []});

  /// Recent songs, most recent first (duplicates already removed).
  final List<ShelfItem> songs;

  /// User pins, rendered ahead of the songs. Empty while the
  /// grid shows skeletons (pins never mix with placeholders).
  final List<ShelfItem> pins;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final m = quickPickMetrics(constraints.maxWidth, songs.length);
        // Pins first, then the ranked pool in order (per-launch
        // variety already shuffled into it by rankPickSongs).
        final picks = orderQuickPicks(pins: pins, songs: songs, slots: m.shown);
        // Playback follows the displayed order (pins included).
        final playList = [
          for (final item in picks)
            if (item is SongItem) item.track,
        ];
        void open(ShelfItem item) {
          if (item is SongItem) {
            var idx = playList.indexWhere(
              (t) => t.videoId == item.track.videoId,
            );
            if (idx < 0) idx = 0;
            state.playSongs(playList, idx);
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
              squareCoverKey: t.videoId,
              playing: t.videoId == playingId,
              onTap: () => open(item),
            );
          }
          // Pinned browsable entries (albums, artists, playlists).
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
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.9,
                      ),
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
                  onPressed: playList.isEmpty
                      ? null
                      : () => state.playSongs(playList, 0),
                ),
                IconButton(
                  icon: const Icon(Icons.shuffle_rounded),
                  tooltip: 'Shuffle quick picks',
                  onPressed: playList.isEmpty
                      ? null
                      : () => state.playShuffled(playList),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Fixed height from the column count so the grid stays lazy:
            // a shrink-wrapped grid would build every tile eagerly.
            SizedBox(
              height: m.rows * m.tile,
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: m.cols,
                  childAspectRatio: 1,
                ),
                physics: const NeverScrollableScrollPhysics(),
                itemCount: picks.length,
                itemBuilder: (context, i) => pickTile(picks[i]),
              ),
            ),
          ],
        );
      },
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

/// One entry in the "Albums made for you" rail: a recap album (opens
/// its detail page) or a mix (plays).
class _MadeForYouEntry {
  const _MadeForYouEntry({required this.item, this.mix});
  final BrowseItem item;
  final HomeMix? mix;
}

/// First shelf whose lowercased title contains one of [needles]
/// (lowercased), in shelf order; null when nothing matches.
Shelf? firstShelfWithTitle(List<Shelf> shelves, List<String> needles) {
  for (final s in shelves) {
    final t = s.title.toLowerCase();
    for (final n in needles) {
      if (t.contains(n)) return s;
    }
  }
  return null;
}

/// Whether [title] is a leftover shelf (kept below the pinned fixed
/// sections) rather than one already rendered above them. The feed's own
/// "Quick picks" shelf is consumed only when the personal grid stands in
/// for it ([showingPersonalPicks]).
bool isLeftoverShelf(String title, {required bool showingPersonalPicks}) {
  final t = title.toLowerCase();
  if (t == 'quick picks') return !showingPersonalPicks;
  return !(t.contains('listen again') ||
      t.contains('forgotten') ||
      t.contains('recap') ||
      t.contains('new album') ||
      t.contains('new release') ||
      t.contains('trend') ||
      t.contains('mix'));
}

/// One home shelf. Song-only shelves render as columns of rows (about
/// five per column) that scroll sideways, keeping the section one screen
/// tall — unless [songRail] asks for the cover treatment: shelves with
/// browsables always render as a horizontal cover rail.
class _ShelfSection extends StatelessWidget {
  const _ShelfSection({required this.shelf, this.title, this.songRail = false});

  final Shelf shelf;

  /// Header override (the pinned sections use their own names); null
  /// keeps the feed's own shelf title.
  final String? title;

  /// Render a song-only shelf as a horizontal rail of cover cards
  /// instead of the multi-column row list. Sections that are a
  /// collection of the user's own songs (Forgotten favorites) read
  /// better as covers; long informational lists stay as rows.
  final bool songRail;

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
    final header = title ?? shelf.title;
    if (songs.isNotEmpty && browses.isEmpty) {
      if (songRail) {
        return CardRail(
          title: header,
          itemCount: songs.length,
          itemBuilder: (context, i) => TrackRailCard(
            track: songs[i],
            playing: songs[i].videoId == playingId,
            onTap: () => _playShelfSong(state, songs, i),
          ),
        );
      }
      return TrackColumns(
        title: header,
        count: songs.length,
        itemBuilder: (context, i) => TrackRow(
          track: songs[i],
          playing: songs[i].videoId == playingId,
          onPlay: () => _playShelfSong(state, songs, i),
          rateable: true,
          showPlaylists: true,
        ),
      );
    }
    return CardRail(
      title: header,
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
