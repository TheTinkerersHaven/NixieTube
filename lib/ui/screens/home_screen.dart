// Home screen: greeting, mood chips, personal quick picks, discover rail,
// and content shelves.

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/models/models.dart';
import '../app_state.dart';
import '../state/pinned_picks_state.dart';
import '../theme.dart';
import '../widgets/screen_list.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cards.dart';
import '../widgets/loading_placeholders.dart';
import '../widgets/rails.dart';
import '../widgets/track_row.dart';

/// Home screen with greeting, mood chips, the personal block (quick-picks
/// grid, plus the liked-songs column on wide windows), and then the pinned
/// sections: Discover, Listen Again, Forgotten favorites, New releases,
/// Albums made for you and the remaining personalized feed rows, with the
/// trending rows (the user's country, then worldwide) last.
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
    final discoverLoading = context.select<AppState, bool>(
      (s) => s.discoverLoading,
    );
    final liked = context.select<AppState, List<Track>>((s) => s.liked);
    final pins = context.select<AppState, List<ShelfItem>>(
      (s) => s.pinnedPicks,
    );
    final accountAvatar = context.select<AppState, String?>(
      (s) => s.accountAvatar,
    );
    // The grid's own readiness: liked songs and recent activity, not the
    // whole library (playlists and artists take longer).
    final quickPicksLoading = context.select<AppState, bool>(
      (s) => s.quickPicksLoading,
    );
    final state = context.read<AppState>();
    // Phones stack the sections a little tighter than the desktop does.
    final sectionGap = homeSectionSpacingOf(context);
    // Each feed owns its own sections and its own skeleton: the
    // personalized rows paint as soon as their feed answers, Explore's
    // rails and the Charts preview follow as theirs do.
    final shelvesPending = home.shelvesLoading;
    final explorePending = home.exploreLoading;
    final chartsPending = home.chartsLoading;
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
    final listenAgain = shelvesPending
        ? _placeholderSongShelf()
        : firstShelfWithTitle(home.shelves, const ['listen again']);
    final forgotten = shelvesPending
        ? _placeholderBrowseShelf()
        : firstShelfWithTitle(home.shelves, const ['forgotten']);
    final newReleases = explorePending
        ? _placeholderBrowseShelf()
        : firstShelfWithTitle(home.explore, const ['new album', 'new release']);
    // The country row's feed shelf is region-derived, so its header names
    // the country the Charts feed reports; before that lands (or when it
    // is unknown) the shelf keeps its own name.
    final trending = explorePending
        ? _placeholderSongShelf()
        : firstShelfWithTitle(home.explore, const ['trend']);
    final trendingTitle = home.country == null
        ? 'Trending'
        : 'Trending in ${home.country}';
    final globalTrending = chartsPending
        ? _placeholderSongShelf()
        : home.globalTrending.isEmpty
        ? null
        : Shelf('', [for (final t in home.globalTrending) ShelfItem.song(t)]);
    final recaps = shelvesPending
        ? const <Shelf>[]
        : [
            for (final s in home.shelves)
              if (s.title.toLowerCase().contains('recap')) s,
          ];
    // Everything not already pinned above renders after the fixed
    // sections, still ranked so user-overlapping rows come first.
    // Mix items are not repeated here: they already surface under
    // "Albums made for you" (via [AppState.mixes]), so a leftover shelf
    // that contains mixes (e.g. a mood playlist shelf) would otherwise
    // show the same cards twice.
    final leftovers = shelvesPending
        ? const <Shelf>[]
        : [
                for (final s in home.shelves)
                  if (isLeftoverShelf(
                    s.title,
                    showingPersonalPicks: showPersonalPicks,
                  ))
                    s,
              ]
              .map(
                (s) => Shelf(
                  s.title,
                  s.items.where((item) => !AppState.isMixItem(item)).toList(),
                  continuation: s.continuation,
                ),
              )
              .where((s) => s.items.isNotEmpty)
              .toList();
    final rankedShelves = shelvesPending
        ? const <Shelf>[]
        : state.rankedHomeShelves(leftovers);
    // The quick-picks grid keeps its skeleton until ITS data (account +
    // library activity) is loaded — not until the home shelves land — so
    // it paints as soon as the liked songs and activity arrive.
    // Only signed-in users get it.
    final gridLoading =
        account != null && (quickPicksLoading || home.shelvesLoading);
    final showGrid = gridLoading || showPersonalPicks;
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
        enabled: shelvesPending,
        enableSwitchAnimation: true,
        child: SilkyListView(
          scrollSpeed: 1.5,
          silkyScrollDuration: const Duration(milliseconds: 700),
          animationCurve: Curves.easeOutQuart,
          // Bottom clearance for the floating player bar overlay.
          // The top inset keeps the greeting below the transparent
          // status bar while the gradient above runs behind it.
          padding: EdgeInsets.fromLTRB(
            screenGutterOf(context),
            screenPadding + MediaQuery.viewPaddingOf(context).top,
            screenGutterOf(context),
            screenPadding + playerBarClearance,
          ),
          children: [
            _greeting(context, account: account, accountAvatar: accountAvatar),
            SizedBox(height: sectionGap),
            _moods(context, state),
            // Personal block next, no matter what: the quick-picks
            // grid (and the liked list on wide windows) or the
            // jump-back-in fallback on sparse accounts always render
            // above the fixed sections.
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
                  songs,
                  loading: gridLoading,
                  pins: gridLoading ? const <ShelfItem>[] : pins,
                ),
              ),
            ] else if (account != null && activity.isNotEmpty) ...[
              _jumpBackIn(context, state),
              SizedBox(height: sectionGap),
            ],
            // Personal sections first, then the editorial and trending
            // rows. Browsable shelves render as horizontal cover rails;
            // song-only shelves render as columns of rows that scroll
            // sideways, save for the ones asked to read as covers (see
            // [_ShelfSection.songRail]).
            if (discover.isNotEmpty) ...[
              _discover(context, state),
              SizedBox(height: sectionGap),
            ] else if (account != null && discoverLoading) ...[
              // The rail is built from the library that just landed, so
              // its slot is held open rather than inserting a row above
              // the sections once the radios come back.
              Skeletonizer(
                enabled: true,
                enableSwitchAnimation: true,
                child: _discover(context, state, items: _placeholderDiscover()),
              ),
              SizedBox(height: sectionGap),
            ],
            if (listenAgain != null) ...[
              _pending(
                shelvesPending,
                _ShelfSection(shelf: listenAgain, title: 'Listen Again'),
              ),
              SizedBox(height: sectionGap),
            ],
            if (forgotten != null) ...[
              _pending(
                shelvesPending,
                _ShelfSection(
                  shelf: forgotten,
                  title: 'Forgotten favorites',
                  songRail: true,
                ),
              ),
              SizedBox(height: sectionGap),
            ],
            if (newReleases != null) ...[
              _pending(
                explorePending,
                _ShelfSection(shelf: newReleases, title: 'New releases'),
              ),
              SizedBox(height: sectionGap),
            ],
            _albumsMadeForYou(context, state, shelvesPending, recaps),
            for (final shelf in rankedShelves) ...[
              _ShelfSection(shelf: shelf),
              SizedBox(height: sectionGap),
            ],
            // Trending closes the screen, country first: the region row
            // Explore serves, then the worldwide chart.
            if (trending != null) ...[
              _pending(
                explorePending,
                _ShelfSection(shelf: trending, title: trendingTitle),
              ),
              SizedBox(height: sectionGap),
            ],
            if (globalTrending != null) ...[
              _pending(
                chartsPending,
                _ShelfSection(
                  shelf: globalTrending,
                  title: 'Trending globally',
                ),
              ),
              SizedBox(height: sectionGap),
            ],
          ],
        ),
      ),
    );
  }

  /// Keeps a section shimmering on its own once the personalized feed has
  /// painted: the outer scope is only enabled while those shelves are on
  /// their way, so a feed that is still in flight brings its own.
  Widget _pending(bool pending, Widget child) => pending
      ? Skeletonizer(enabled: true, enableSwitchAnimation: true, child: child)
      : child;

  /// Placeholder quick-picks while the personal data loads, so the grid
  /// is skeletonized instead of popping in later. The count is the grid's
  /// own cell count — three rows of [cols] tiles — so every tile it lays
  /// out is a bone: nine on a phone, up to eighteen on a wide window.
  List<ShelfItem> _skeletonPicks(int cols) {
    return [
      for (var i = 0; i < cols * 3; i++)
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
    // A phone gets a compact header: a smaller avatar, a title in
    // titleLarge instead of headlineMedium, and the name on one tight
    // line, so the first row of content is visible without scrolling.
    final compact = isCompactLayout(context);
    final avatarSize = compact ? 32.0 : 44.0;
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
                  size: avatarSize,
                  circular: true,
                  iconSize: compact ? 18 : 24,
                )
              else
                Container(
                  width: avatarSize,
                  height: avatarSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surfaceContainerHigh,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    account.substring(0, 1).toUpperCase(),
                    style:
                        (compact
                                ? Theme.of(context).textTheme.bodyMedium
                                : Theme.of(context).textTheme.titleMedium)
                            ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              SizedBox(width: compact ? 10 : 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    greeting,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: compact
                        ? Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w600)
                        : Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (account != null)
                    Text(
                      account,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (compact
                                  ? Theme.of(context).textTheme.bodySmall
                                  : Theme.of(context).textTheme.bodyLarge)
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
          itemBuilder: (context, i, width) {
            final entry = entries[i];
            final mix = entry.mix;
            return BrowseCard(
              item: entry.item,
              width: width,
              onTap: () {
                if (mix != null) {
                  if (!loading) unawaited(state.playMix(mix));
                  return;
                }
                if (entry.item.isPlaylist) {
                  state.openPlaylistById(entry.item.browseId, item: entry.item);
                  return;
                }
                state.go(Screen.detail, detail: entry.item);
              },
            );
          },
        ),
        SizedBox(height: homeSectionSpacingOf(context)),
      ],
    );
  }

  Widget _personal(
    BuildContext context,
    AppState state,
    List<ShelfItem> songs, {
    bool loading = false,
    List<ShelfItem> pins = const [],
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        // The grid's own width, known before it lays out: the skeleton
        // fills exactly the cells it will use, and the liked list is cut
        // to the same height.
        final gridWidth = wide
            ? (constraints.maxWidth - 16) * 155 / 255
            : constraints.maxWidth;
        final picks = loading
            ? _skeletonPicks(quickPickCols(gridWidth))
            : songs;
        final grid = _QuickPicksGrid(songs: picks, pins: pins);
        if (!wide) {
          // Phones keep just the grid: liked songs live in the
          // library's "Liked songs" playlist there.
          if (isCompactLayout(context)) return grid;
          // Narrow desktop windows: liked list capped at 400px, scrolling
          // inside.
          return Column(
            children: [
              grid,
              const SizedBox(height: 16),
              SizedBox(height: 400, child: _LikedSideList(liked: state.liked)),
            ],
          );
        }
        // Wide: cut the liked list to the grid's exact height so its rows
        // scroll/clip where the quick-pick tiles end.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 155, child: grid),
            const SizedBox(width: 16),
            Expanded(
              flex: 100,
              child: SizedBox(
                height: quickPicksHeight(
                  Theme.of(context),
                  gridWidth,
                  picks.length + pins.length,
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
      itemBuilder: (context, i, width) {
        final t = tracks[i];
        return TrackRailCard(
          track: t,
          width: width,
          playing: t.videoId == playingId,
          onTap: () =>
              state.playSongs(state.activity, i, sourceName: 'Jump back in'),
        );
      },
    );
  }

  /// Discover placeholders: a rail's worth of cards while the rail is
  /// still being built from the library that just landed.
  List<Track> _placeholderDiscover() => [
    for (var i = 0; i < 12; i++)
      Track(
        videoId: 'skeleton-d$i',
        title: 'Song title',
        artists: const [],
        thumbnails: const [],
      ),
  ];

  /// The Discover rail; [items] renders its placeholders while loading.
  Widget _discover(BuildContext context, AppState state, {List<Track>? items}) {
    final tracks = items ?? state.discover;
    final loading = items != null;
    final playingId = state.playerState.current?.videoId;
    return CardRail(
      title: 'Discover',
      trailing: (height) => M3ETextButton(
        // As tall as the heading text, so this rail's header is the same
        // height as the ones without a button.
        decoration: M3EButtonDecoration(
          minimumSize: Size(0, height),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: loading
            ? () {}
            : () => state.playSongs(tracks, 0, sourceName: 'Discover'),
        child: const Text('Play all'),
      ),
      itemCount: tracks.length,
      itemBuilder: (context, i, width) {
        final t = tracks[i];
        return TrackRailCard(
          track: t,
          width: width,
          playing: !loading && t.videoId == playingId,
          onTap: loading
              ? () {}
              : () => state.playSongs(tracks, i, sourceName: 'Discover'),
        );
      },
    );
  }
}

/// Columns the quick-picks grid lays out at [gridWidth]. Shared by the
/// grid metrics and the loading skeleton, which fills every cell.
int quickPickCols(double gridWidth) => (gridWidth / 170).floor().clamp(3, 6);

/// Grid geometry shared by [_QuickPicksGrid] and the liked-list height
/// computation, so both agree on the rendered grid height.
///
/// The grid never repeats an item, so it can only show as many cells as
/// there are distinct sources: rows shrink below 3 when sources are few.
({int cols, int shown, int rows, double tile}) quickPickMetrics(
  double gridWidth,
  int pickCount,
) {
  final cols = quickPickCols(gridWidth);
  final shown = pickCount.clamp(0, cols * 3);
  final rows = shown == 0 ? 0 : (shown / cols).ceil();
  final tile = gridWidth / cols;
  return (cols: cols, shown: shown, rows: rows, tile: tile);
}

/// Full rendered height of [_QuickPicksGrid] for [gridWidth]: the
/// heading row + its [sectionHeaderGap] + the tile grid with the room
/// under it, so the liked column can be cut to the same height.
double quickPicksHeight(ThemeData theme, double gridWidth, int pickCount) {
  final m = quickPickMetrics(gridWidth, pickCount);
  return sectionHeadingHeight(theme) +
      sectionHeaderGap +
      m.rows * m.tile +
      sectionHeaderGap;
}

/// Tiles in one phone quick-picks page: three rows of three.
const int phonePicksPerPage = 9;

/// Space between quick-pick tiles, and between the rows of a page.
const double quickPickGap = 4.0;

/// Breathing room under a quick-picks block, above the dot row on a
/// phone and the section gap on a desk. The space above the tiles comes
/// from the heading's own [sectionHeaderGap].
const EdgeInsets quickPickGridPadding = EdgeInsets.only(
  bottom: sectionHeaderGap,
);

/// Pages the phone quick-picks grid needs for [pickCount] picks.
int quickPickPages(int pickCount) => pickCount <= 0
    ? 0
    : (pickCount + phonePicksPerPage - 1) ~/ phonePicksPerPage;

/// Rows in one phone quick-picks page: three for a full page, fewer when
/// the pool cannot fill it.
int quickPickPageRows(int pickCount) {
  final shown = pickCount < phonePicksPerPage ? pickCount : phonePicksPerPage;
  return shown <= 0 ? 0 : (shown + 2) ~/ 3;
}

/// Height of one phone quick-picks page at [gridWidth]: the tile rows
/// plus the gap above the dot row.
double quickPickPageHeight(double gridWidth, int pickCount) {
  final rows = quickPickPageRows(pickCount);
  if (rows == 0) return 0;
  final tile = (gridWidth - quickPickGap * 2) / 3;
  return sectionHeaderGap + rows * tile + (rows - 1) * quickPickGap;
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
    final k = PinnedPicksState.keyOf(item);
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

/// Quick picks: a responsive grid on wide windows, and on phones the
/// same three rows of tiles as one page of a swipeable set, with a dot
/// per page under them.
///
/// Art-diverse, so the same cover never shows twice, with user pins
/// first. Play/shuffle follow the displayed order.
class _QuickPicksGrid extends StatefulWidget {
  const _QuickPicksGrid({required this.songs, this.pins = const []});

  /// Recent songs, most recent first (duplicates already removed).
  final List<ShelfItem> songs;

  /// User pins, rendered ahead of the songs. Empty while the
  /// grid shows skeletons (pins never mix with placeholders).
  final List<ShelfItem> pins;

  @override
  State<_QuickPicksGrid> createState() => _QuickPicksGridState();
}

class _QuickPicksGridState extends State<_QuickPicksGrid> {
  /// Pages the phone grid sideways; unused (and untouched) on wide
  /// windows, where the grid renders in one block.
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    if (!_controller.hasClients) return;
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Pins count toward the slots and the row count: sizing the grid
        // from songs alone could drop pins (or leave the last row clipped
        // when they filled it).
        final compact = isCompactLayout(context);
        final measured = quickPickMetrics(
          constraints.maxWidth,
          widget.songs.length + widget.pins.length,
        );
        // Phones page through every pick the pool offers; wide windows
        // keep the single three-row block.
        final slots = compact
            ? widget.songs.length + widget.pins.length
            : measured.shown;
        // Pins first, then the ranked pool in order (per-launch
        // variety already shuffled into it by rankPickSongs).
        final picks = orderQuickPicks(
          pins: widget.pins,
          songs: widget.songs,
          slots: slots,
        );
        // Playback follows the displayed order (pins included), and on a
        // phone it spans every page rather than the one on screen.
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
            state.playSongs(playList, idx, sourceName: 'Quick picks');
          } else if (item is BrowseItem) {
            final id = item.browseId;
            if (id.startsWith('UC') || id.startsWith('MPRE')) {
              // Artist (UC) or album (MPRE): both open the detail page.
              state.go(Screen.detail, detail: item);
            } else {
              state.openPlaylistById(id, item: item);
            }
          }
        }

        // [index] and [count] describe the block the tile belongs to: the
        // whole grid on a wide window, one page on a phone.
        BorderRadius tileRadius(int index, int count) {
          if (!compact) {
            return const BorderRadius.all(Radius.circular(cardRadius));
          }
          const radius = Radius.circular(ExpressiveCorners.largeIncreased);
          const innerRadius = Radius.circular(4);
          final row = index ~/ 3;
          final lastRow = (count / 3).ceil() - 1;
          return BorderRadius.only(
            topLeft: row == 0 && index % 3 == 0 ? radius : innerRadius,
            topRight: row == 0 && index % 3 == 2 ? radius : innerRadius,
            bottomLeft: row == lastRow && index % 3 == 0 ? radius : innerRadius,
            bottomRight: row == lastRow && index == count - 1
                ? radius
                : innerRadius,
          );
        }

        Widget tile(ShelfItem item, int index, int count) {
          final radius = tileRadius(index, count);
          final tilePadding = compact
              ? EdgeInsets.zero
              : const EdgeInsets.all(4);
          if (item is SongItem) {
            final t = item.track;
            return QuickPickCard(
              title: t.title,
              subtitle: t.artistNames(),
              art: t.displayArtwork,
              squareCoverKey: t.videoId,
              playing: t.videoId == playingId,
              padding: tilePadding,
              borderRadius: radius,
              track: t,
              onTap: () => open(item),
            );
          }
          // Pinned browsable entries (albums, artists, playlists).
          final b = item as BrowseItem;
          final art = b.thumbnails.isEmpty ? null : b.bestArtwork;
          return QuickPickCard(
            title: b.title,
            subtitle: b.subtitle,
            art: art,
            playing: false,
            padding: tilePadding,
            borderRadius: radius,
            showArrow:
                b.browseId.startsWith('UC') || b.browseId.startsWith('MPRE'),
            onTap: () => open(item),
          );
        }

        Widget pickTile(ShelfItem item, int index, int count) {
          Widget t = tile(item, index, count);
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
          return Semantics(
            onLongPressHint: 'Pin or unpin to quick picks',
            child: GestureDetector(
              onLongPress: () => state.togglePin(item),
              child: t,
            ),
          );
        }

        final heading = _PersonalHeading(
          title: 'Quick picks',
          trailing: (height) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded),
                tooltip: 'Play quick picks',
                // As tall as the heading text, not the 48px default.
                padding: EdgeInsets.zero,
                iconSize: height * 0.8,
                splashRadius: height / 2,
                // No 48px tap-target padding: the button is exactly
                // as tall as the heading text.
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: BoxConstraints.tightFor(
                  height: height,
                  width: height,
                ),
                onPressed: playList.isEmpty
                    ? null
                    : () => state.playSongs(
                        playList,
                        0,
                        sourceName: 'Quick picks',
                      ),
              ),
              IconButton(
                icon: const Icon(Icons.shuffle_rounded),
                tooltip: 'Shuffle quick picks',
                padding: EdgeInsets.zero,
                iconSize: height * 0.8,
                splashRadius: height / 2,
                // No 48px tap-target padding: the button is exactly
                // as tall as the heading text.
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: BoxConstraints.tightFor(
                  height: height,
                  width: height,
                ),
                onPressed: playList.isEmpty
                    ? null
                    : () => state.playShuffled(
                        playList,
                        sourceName: 'Quick picks',
                      ),
              ),
            ],
          ),
        );

        if (!compact) {
          // Wide: one grid, sized by the row count the metrics give (the
          // liked column beside it is cut to the same height).
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: measured.cols,
                  childAspectRatio: 1,
                  crossAxisSpacing: 0,
                  mainAxisSpacing: 0,
                ),
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                itemCount: picks.length,
                itemBuilder: (context, i) =>
                    pickTile(picks[i], i, picks.length),
                padding: quickPickGridPadding,
              ),
            ],
          );
        }

        // Phone: pages of nine tiles, each page its own 3x3 block so the
        // expressive corners wrap the page instead of the whole grid.
        final pages = quickPickPages(picks.length);
        final page = pages == 0 ? 0 : _page.clamp(0, pages - 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            SizedBox(
              height: quickPickPageHeight(constraints.maxWidth, picks.length),
              child: PageView.builder(
                controller: _controller,
                itemCount: pages,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, pageIndex) {
                  final start = pageIndex * phonePicksPerPage;
                  final end = (start + phonePicksPerPage).clamp(
                    0,
                    picks.length,
                  );
                  final pagePicks = picks.sublist(start, end);
                  return GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 1,
                          crossAxisSpacing: quickPickGap,
                          mainAxisSpacing: quickPickGap,
                        ),
                    physics: const NeverScrollableScrollPhysics(),
                    // Only the room under the tiles sits in the grid: the
                    // gap above them is the heading's, like every other
                    // section heading.
                    padding: quickPickGridPadding,
                    itemCount: pagePicks.length,
                    itemBuilder: (context, i) =>
                        pickTile(pagePicks[i], i, pagePicks.length),
                  );
                },
              ),
            ),
            // A single page keeps the dot row's space anyway, so the
            // loading skeleton (one page of bones) and the loaded grid are
            // the same height and nothing below them jumps.
            if (pages > 1)
              _PageDots(count: pages, index: page, onSelect: _goToPage)
            else
              const SizedBox(height: _PageDots.height),
          ],
        );
      },
    );
  }
}

/// Page indicator for the phone quick-picks grid: one dot per page, the
/// page on screen drawn as a wider pill. Tapping a dot turns to it.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.index,
    required this.onSelect,
  });

  /// Height the row takes: a 6dp dot in a 24dp tap target, under a 6dp
  /// gap. A single-page grid reserves the same space.
  static const double height = 30;

  final int count;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Semantics(
              button: true,
              selected: i == index,
              label: 'Page ${i + 1} of $count',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                // A fixed slot per dot, so the row keeps its width and
                // the other dots do not shift as the pill moves.
                child: SizedBox(
                  width: 22,
                  height: 24,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      width: i == index ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == index
                            ? scheme.primary
                            : scheme.onSurfaceVariant.withValues(alpha: 0.38),
                        borderRadius: const BorderRadius.all(
                          Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}


/// The heading of a personal-block column.
///
/// Both columns use it, so "Quick picks" and "Liked songs" sit on the
/// same line: the title lives in a box of the title's own line height,
/// and the trailing controls are built for that height too.
class _PersonalHeading extends StatelessWidget {
  const _PersonalHeading({
    required this.title,
    required this.trailing,
    this.note,
  });

  /// The heading text.
  final String title;

  /// A caption next to the title (the liked list's loaded count).
  final String? note;

  /// The controls on the right, built for the heading's height.
  final Widget Function(double height) trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = sectionHeadingHeight(theme);
    return Padding(
      padding: const EdgeInsets.only(bottom: sectionHeaderGap),
      child: Row(
      children: [
        Expanded(
          child: SizedBox(
            height: height,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                // The note sits on the title's baseline, so it reads as
                // a caption of it.
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(title, style: theme.textTheme.titleLarge),
                  ),
                  if (note != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Tooltip(
                        message:
                            'YouTube counts every song of the playlist, but '
                            'its playlist page only serves the ones it '
                            'renders — the rest cannot be loaded.',
                        child: Text(
                          note!,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        trailing(height),
      ],
      ),
    );
  }
}

/// Liked songs list: rows under a header with Play all. Fills the height
/// given by the parent (grid height on wide windows, 400px when stacked)
/// with the rows scrolling inside a measured column.
class _LikedSideList extends StatelessWidget {
  const _LikedSideList({required this.liked});

  final List<Track> liked;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final playingId = context.select<AppState, String?>(
      (s) => s.playerState.current?.videoId,
    );
    final note = state.likedLoadNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PersonalHeading(
          title: 'Liked songs',
          // How many of the playlist's songs are listed, next to the
          // title it belongs to.
          note: note,
          trailing: (height) => M3ETextButton(
            // As tall as the heading text, not the button's own height.
            decoration: M3EButtonDecoration(
              minimumSize: Size(0, height),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: liked.isEmpty
                ? null
                : () => state.playSongs(liked, 0, sourceName: 'Liked songs'),
            child: const Text('Play all'),
          ),
        ),
        Expanded(
          child: screenListBuilder(
            itemCount: liked.length,
            topPadding: 0,
            horizontalPadding: 0,
            bottomClearance: 0,
            itemBuilder: (context, i) {
              final t = liked[i];
              return TrackRow(
                track: t,
                playing: t.videoId == playingId,
                onPlay: () =>
                    state.playSongs(liked, i, sourceName: 'Liked songs'),
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
    unawaited(state.playMixSeed(tapped));
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
      t.contains('mix') ||
      t.contains('liked'));
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
    final loadingMore = state.isLoadingMoreShelf(shelf.title);
    Widget body;
    if (songs.isNotEmpty && browses.isEmpty) {
      // Phones only use the cover rail: the multi-column row list is a
      // desktop shape, so a song shelf becomes a track rail there.
      if (songRail || isCompactLayout(context)) {
        body = CardRail(
          title: header,
          itemCount: songs.length,
          itemBuilder: (context, i, width) => TrackRailCard(
            track: songs[i],
            width: width,
            playing: songs[i].videoId == playingId,
            onTap: () => _playShelfSong(state, songs, i),
          ),
        );
      } else {
        body = TrackColumns(
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
    } else {
      body = CardRail(
        title: header,
        itemCount: shelf.items.length,
        itemBuilder: (context, i, width) {
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
              width: width,
              track: t,
              onTap: () {
                if (AppState.isMixSeed(t)) {
                  unawaited(state.playMixSeed(t));
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
            width: width,
            onTap: () {
              if (b.isPlaylist) {
                state.openPlaylistById(b.browseId, item: b);
              } else {
                state.go(Screen.detail, detail: b);
              }
            },
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        if (shelf.hasMore) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (loadingMore)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                M3ETextButton(
                  onPressed: () => unawaited(state.loadMoreShelf(shelf)),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
