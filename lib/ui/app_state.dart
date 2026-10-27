// Central UI state holder wiring navigation, content, library, ratings
// and playback reporting. Ported from Kotlin `AppState`.
//
// Kotlin StateFlow/collectAsState becomes ChangeNotifier + Provider.
// Async jobs are fenced with generation counters (Kotlin cancels Jobs).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math' show Random;

import 'package:material_ui/material_ui.dart'
    show
        BuildContext,
        ChangeNotifier,
        Color,
        ColorScheme,
        ScaffoldMessenger,
        SnackBar,
        Text,
        ValueNotifier,
        debugPrint;
import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart' show PaintingBinding;

import '../core/artwork/artwork_store.dart';
import 'playback_reporter.dart';
import '../core/innertube/account_library.dart';
import '../core/innertube/auth_session.dart';
import '../core/innertube/inner_tube.dart';
import '../core/innertube/lyrics.dart';
import '../core/innertube/parse.dart';
import '../core/innertube/metadata.dart'
    show canonical, hasGenericReleaseArtist;
import '../core/models/models.dart';
import '../core/player/player_controller.dart';
import '../core/player/player_state.dart';
import '../sys/browser_cookies.dart';
import '../sys/cache_store.dart';
import '../sys/paths.dart';
import '../sys/sys_config.dart';
import 'theme.dart' show ThemeSource, resolveColorScheme;

/// Navigation destinations for the single-window app.
enum Screen { home, search, library, settings, detail }

/// History entry for back navigation.
class HistoryEntry {
  HistoryEntry(this.screen, this.detail);
  final Screen screen;
  final BrowseItem? detail;
}

/// Loaded state of the home feed.
///
/// Entries the "Trending globally" home row previews. The worldwide
/// chart is a 100-track playlist and every row costs an artwork load
/// plus a cover lookup, so the row carries a preview the size of the
/// screen's other rows instead of the whole chart.
const _globalTrendingMax = 25;

/// Immutable: every update reassigns a new instance via [copyWith], so
/// `context.select((s) => s.home)` can detect changes by identity and the
/// home screen rebuilds only when the feed actually changes.
class HomeUiState {
  HomeUiState({
    this.loading = true,
    this.shelves = const [],
    this.explore = const [],
    this.country,
    this.globalTrending = const [],
    this.moods = const [],
    this.error,
  });
  final bool loading;
  final List<Shelf> shelves;

  /// Stable editorial shelves from YouTube's Explore feed ("New albums
  /// & singles", "Trending", …), kept separate from the rotating
  /// personalized [shelves] so the home screen can pin fixed sections
  /// that would otherwise come and go.
  final List<Shelf> explore;

  /// Display name of the user's own country, as the Charts feed labels
  /// it; null when unknown, in which case the country trending row
  /// drops the name.
  final String? country;

  /// Preview of YouTube's worldwide music chart (the Charts feed's
  /// "Trending globally" row), empty while loading or when the feed is
  /// unavailable.
  final List<Track> globalTrending;

  /// Mood filter chips from the feed's chip cloud (feed order, no
  /// hardcoding). Empty while loading or when the feed has none, in
  /// which case the chips row hides.
  final List<String> moods;
  final String? error;

  static const _unset = Object();

  HomeUiState copyWith({
    bool? loading,
    List<Shelf>? shelves,
    List<Shelf>? explore,
    String? country,
    List<Track>? globalTrending,
    List<String>? moods,
    Object? error = _unset,
  }) {
    return HomeUiState(
      loading: loading ?? this.loading,
      shelves: shelves ?? this.shelves,
      explore: explore ?? this.explore,
      country: country ?? this.country,
      globalTrending: globalTrending ?? this.globalTrending,
      moods: moods ?? this.moods,
      // `error` may be cleared explicitly (set to null).
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }
}

/// Loaded state of the search results.
class SearchUiState {
  SearchUiState({
    this.query = '',
    this.loading = false,
    this.sections = const {},
    this.error,
  });
  String query;
  bool loading;
  Map<String, List<ShelfItem>> sections;
  String? error;
}

/// Loaded state of the current detail page.
class DetailUiState {
  DetailUiState({
    this.loading = true,
    this.album,
    this.artist,
    this.playlist,
    this.error,
  });
  bool loading;
  AlbumDetail? album;
  ArtistDetail? artist;
  PlaylistDetail? playlist;
  String? error;
}

/// Open playlist with its tracks, or null when browsing the library root.
class OpenPlaylist {
  OpenPlaylist(this.playlist, this.tracks);
  AccountPlaylist playlist;
  List<Track> tracks;
}

/// Normalizes a name for navigation matching.
String navigationName(String value) => canonical(value);

/// Content signature for change detection: length plus per-item identity
/// and rating. Ratings arrive through the player stream, so they must
/// participate or like buttons would go stale.
int queueSignature(List<Track> queue) {
  var h = queue.length * 31 + 7;
  for (final t in queue) {
    h = 0x1fffffff & (h * 33 + t.videoId.hashCode);
    h = 0x1fffffff & (h * 33 + t.rating.index);
  }
  return h;
}

/// True when [next] differs from [prev] only in playback progress
/// (position ticks). Everything else — track, transport, queue content,
/// settings — requires a full rebuild. `durationMs` participates because
/// its 0→actual latch reveals the duration label; `seekEpoch` because
/// sliders re-anchor on it.
bool isProgressOnlyUpdate(PlayerState prev, PlayerState next) {
  return prev.current?.videoId == next.current?.videoId &&
      prev.current?.rating == next.current?.rating &&
      prev.playing == next.playing &&
      prev.loading == next.loading &&
      prev.stopped == next.stopped &&
      prev.durationMs == next.durationMs &&
      prev.seekEpoch == next.seekEpoch &&
      prev.volume == next.volume &&
      prev.index == next.index &&
      prev.shuffle == next.shuffle &&
      prev.repeat == next.repeat &&
      prev.autoplay == next.autoplay &&
      prev.error == next.error &&
      prev.sleepTimerMode == next.sleepTimerMode &&
      prev.sleepTimerEndsAtMs == next.sleepTimerEndsAtMs &&
      queueSignature(prev.queue) == queueSignature(next.queue);
}

/// True when [next] differs from [prev] only in volume: everything a
/// progress tick covers, plus the volume equality flipped. Volume drags
/// (throttled to ~8/s) must bump [AppState.volumeTick], not rebuild the
/// whole app through [AppState.notifyListeners].
bool isVolumeOnlyUpdate(PlayerState prev, PlayerState next) {
  return prev.volume != next.volume &&
      prev.current?.videoId == next.current?.videoId &&
      prev.current?.rating == next.current?.rating &&
      prev.playing == next.playing &&
      prev.loading == next.loading &&
      prev.stopped == next.stopped &&
      prev.durationMs == next.durationMs &&
      prev.seekEpoch == next.seekEpoch &&
      prev.index == next.index &&
      prev.shuffle == next.shuffle &&
      prev.repeat == next.repeat &&
      prev.autoplay == next.autoplay &&
      prev.error == next.error &&
      prev.sleepTimerMode == next.sleepTimerMode &&
      prev.sleepTimerEndsAtMs == next.sleepTimerEndsAtMs &&
      queueSignature(prev.queue) == queueSignature(next.queue);
}

bool sameNavigationName(String left, String right) {
  if (left.toLowerCase() == right.toLowerCase()) return true;
  final a = navigationName(left);
  return a.isNotEmpty && a == navigationName(right);
}

/// Watchtime failure log (successes stay silent).

/// Remembered panel enrichment for one track (see
/// `AppState._trackMeta`): fuller artists, album, explicit flag.
/// Compact JSON (`home.trackMeta`); junk-tolerant decode, null when
/// the stored value no longer parses.
class _TrackMeta {
  const _TrackMeta({
    this.artists = const [],
    this.album,
    this.explicit = false,
  });

  final List<ArtistRef> artists;
  final AlbumRef? album;
  final bool explicit;

  Map<String, dynamic> toJson() => {
    if (artists.isNotEmpty)
      'a': [
        for (final a in artists) [a.name, if (a.browseId != null) a.browseId],
      ],
    if (album != null)
      'al': [
        album!.name,
        if (album!.browseId != null) album!.browseId,
        if (album!.kind != null) album!.kind!.name,
        if (album!.year.isNotEmpty) album!.year,
      ],
    if (explicit) 'e': 1,
  };

  static _TrackMeta? fromJson(dynamic e) {
    if (e is! Map) return null;
    try {
      final artists = <ArtistRef>[];
      final a = e['a'];
      if (a is List) {
        for (final r in a) {
          if (r is List && r.isNotEmpty && r[0] is String) {
            final name = r[0] as String;
            if (name.isEmpty) continue;
            artists.add(
              ArtistRef(
                name,
                browseId: r.length > 1 && r[1] is String
                    ? r[1] as String
                    : null,
              ),
            );
          }
        }
      }
      AlbumRef? album;
      final al = e['al'];
      if (al is List && al.isNotEmpty && al[0] is String) {
        final name = al[0] as String;
        if (name.isNotEmpty) {
          ReleaseKind? kind;
          if (al.length > 2 && al[2] is String) {
            for (final k in ReleaseKind.values) {
              if (k.name == al[2]) kind = k;
            }
          }
          album = AlbumRef(
            name,
            browseId: al.length > 1 && al[1] is String ? al[1] as String : null,
            kind: kind,
            year: al.length > 3 && al[3] is String ? al[3] as String : '',
          );
        }
      }
      return _TrackMeta(artists: artists, album: album, explicit: e['e'] == 1);
    } catch (_) {
      return null;
    }
  }
}

/// Central UI state holder (ChangeNotifier).
class AppState extends ChangeNotifier {
  AppState({
    required InnerTube tube,
    required PlayerController player,
    required ArtworkStore art,
    required SysConfig config,
    required Future<void> Function(String url) openUrl,
    // Test seam: cookie session file. Production uses the shared
    // config dir; tests must pass a temp path — the login/logout
    // flows create and delete this file, and must never touch the
    // real session.
  }) {
    _tube = tube;
    _player = player;
    _art = art;
    _library = AccountLibrary(tube: tube);
    _config = config;
    _openUrl = openUrl;
    _playback = PlaybackReporter(
      tube: tube,
      config: config,
      notify: _safeNotify,
    );
    _playerSub = _player.states.listen(_onPlayerState);
    _loadLocalRecents();
    _loadTrackMeta();
    _loadArtistAvatars();
    _loadPlayCounts();
    _loadPinnedPicks();
    // Seed the published scheme from the remembered system accent:
    // the tray/window icon renders before the async platform fetch
    // lands, so without this it would start on the built-in fallback
    // every launch. The themed shell republishes live values after.
    displayScheme.value = resolveColorScheme(
      source: ThemeSource.fromKey(_config.themeSource),
      seedColor: _config.themeSeedColor,
      rememberedSystemPrimary: _config.themeSystemPrimary,
      primaryOverride: _config.themePrimaryOverride,
      secondaryOverride: _config.themeSecondaryOverride,
      tertiaryOverride: _config.themeTertiaryOverride,
      surfaceOverride: _config.themeSurfaceOverride,
    );
  }

  late final InnerTube _tube;
  late final PlaybackReporter _playback;
  late final PlayerController _player;
  late final ArtworkStore _art;
  late final AccountLibrary _library;
  late final SysConfig _config;
  late final Future<void> Function(String url) _openUrl;

  /// Opens [url] in the system's external browser (see the `openUrl`
  /// wiring in `main.dart`).
  Future<void> openUrl(String url) => _openUrl(url);
  StreamSubscription<PlayerState>? _playerSub;

  /// Set on dispose: fire-and-forget chains (lyrics, palette) can
  /// outlive the state in tests when the network lags past teardown,
  /// and must not notify afterwards.
  bool _disposed = false;

  /// Notifies only while the state is alive. Every call site that
  /// can run after an `await` or on a timer goes through this: the
  /// framework still lets a stray `notifyListeners()` on a disposed
  /// `ChangeNotifier` through in debug, so the guard matters.
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  InnerTube get tube => _tube;
  PlayerController get player => _player;
  ArtworkStore get art => _art;
  SysConfig get config => _config;

  /// Set by the startup audio probe when the native backend is
  /// unusable: playback refuses to start and the shell shows why,
  /// instead of a console message and a frozen transport.
  String? _audioBackendError;

  /// True when the native audio backend failed the startup probe.
  bool get audioBackendUnavailable => _audioBackendError != null;

  /// Records a failed audio backend: the player refuses playback
  /// (see `PlayerController.backendUnavailable`) and the shell shows
  /// this text until restart.
  void reportAudioBackendUnavailable(String message) {
    if (_audioBackendError != null) return;
    _audioBackendError = message;
    _player.backendUnavailable = true;
    _player.backendUnavailableReason = message;
    _safeNotify();
  }

  /// Latest player snapshot for selective UI reads.
  PlayerState get playerState => _player.state;

  /// The account library (playlists, likes, artists, subscriptions).
  AccountLibrary get library => _library;

  @override
  void dispose() {
    _disposed = true;
    _paletteHoldTimer?.cancel();
    _paletteHoldTimer = null;
    unawaited(_playerSub?.cancel());
    progressTick.dispose();
    paletteTick.dispose();
    volumeTick.dispose();
    squareCoverTick.dispose();
    displayScheme.dispose();
    super.dispose();
  }

  // ---------- Navigation ----------

  Screen _screen = Screen.home;
  Screen get screen => _screen;

  BrowseItem? _detailItem;
  BrowseItem? get detailItem => _detailItem;

  final List<HistoryEntry> _history = [];
  bool _canGoBack = false;
  bool get canGoBack => _canGoBack;

  void _pushHistory() {
    _history.add(HistoryEntry(_screen, _detailItem));
    if (_history.length > 100) _history.removeAt(0);
    _canGoBack = true;
  }

  /// Direction of the latest navigation: false only for back pops.
  /// Pushes rise from the bottom, pops sink back down.
  bool _lastNavForward = true;
  bool get lastNavForward => _lastNavForward;

  /// Navigates forward, pushing the current screen for [goBack].
  /// Detail screens kick off their load on arrival.
  void go(Screen screen, {BrowseItem? detail}) {
    _lastNavForward = true;
    _pushHistory();
    _screen = screen;
    _detailItem = detail;
    if (screen == Screen.detail && detail != null) {
      _loadDetail(detail);
    }
    _safeNotify();
  }

  /// Returns to the pushed screen, if any. Detail entries reload on
  /// arrival so back navigation never shows a stale page.
  void goBack() {
    if (_history.isEmpty) return;
    _lastNavForward = false;
    final entry = _history.removeLast();
    _canGoBack = _history.isNotEmpty;
    _screen = entry.screen;
    _detailItem = entry.detail;
    if (entry.screen == Screen.detail && entry.detail != null) {
      _loadDetail(entry.detail!);
    }
    _safeNotify();
  }

  /// Opens an artist page, resolving unlinked credits first.
  Future<void> openArtist(ArtistRef artist, [Track? track]) async {
    final id = artist.browseId;
    if (id != null && id.startsWith('UC')) {
      go(
        Screen.detail,
        detail: BrowseItem(
          title: artist.name,
          subtitle: 'Artist',
          browseId: id,
          thumbnails: track?.thumbnails ?? const [],
        ),
      );
      return;
    }
    if (track != null) {
      try {
        final enriched = await _tube.enrichTrack(track);
        final linked = enriched.artists
            .where((a) => a.browseId != null && a.browseId!.startsWith('UC'))
            .toList();
        if (linked.isNotEmpty) {
          final match = linked.firstWhere(
            (a) => sameNavigationName(a.name, artist.name),
            orElse: () => linked.first,
          );
          go(
            Screen.detail,
            detail: BrowseItem(
              title: match.name,
              subtitle: 'Artist',
              browseId: match.browseId!,
              thumbnails: enriched.thumbnails,
            ),
          );
          return;
        }
        if (enriched.artistId != null && enriched.artistId!.startsWith('UC')) {
          go(
            Screen.detail,
            detail: BrowseItem(
              title: enriched.artistNames(),
              subtitle: 'Artist',
              browseId: enriched.artistId!,
              thumbnails: enriched.thumbnails,
            ),
          );
          return;
        }
      } catch (_) {}
    }
    searchAndGo(artist.name);
  }

  /// Opens an album page, resolving unlinked refs first.
  Future<void> openAlbum(Track track, AlbumRef album) async {
    final id = album.browseId;
    if (id != null && id.startsWith('MPRE')) {
      go(
        Screen.detail,
        detail: BrowseItem(
          title: album.name,
          subtitle: 'Album',
          browseId: id,
          thumbnails: track.thumbnails,
        ),
      );
      return;
    }
    try {
      final enriched = await _tube.enrichTrack(track);
      final ref = enriched.album;
      if (ref != null &&
          ref.browseId != null &&
          ref.browseId!.startsWith('MPRE')) {
        go(
          Screen.detail,
          detail: BrowseItem(
            title: ref.name,
            subtitle: 'Album',
            browseId: ref.browseId!,
            thumbnails: enriched.thumbnails,
          ),
        );
        return;
      }
    } catch (_) {}
    searchAndGo('${track.artistNames()} ${album.name}');
  }

  // ---------- Home / search / detail ----------

  HomeUiState home = HomeUiState();
  SearchUiState search = SearchUiState();
  DetailUiState detail = DetailUiState();

  List<Shelf>? _rankedShelvesCache;
  String _rankedShelvesKey = '';
  final Set<String> _loadingMoreShelves = {};

  /// Whether a load-more fetch for [title] is in flight, so the row's load
  // more button shows a spinner instead of being tapped again.
  bool isLoadingMoreShelf(String title) => _loadingMoreShelves.contains(title);

  /// Home shelves with user-overlapping rows first (history, liked
  /// songs, followed artists, personalized mixes outrank generic
  /// editorial rows). Memoized on identities: track enrichment
  /// replaces shelf objects with the same ids every few seconds
  /// after load, which must not re-rank rows out from under the
  /// user. Recomputes only when the shelf contents or the profile
  /// id sets change. Empty profile (signed out) keeps feed order.
  List<Shelf> rankedHomeShelves(List<Shelf> shelves) {
    final trackIds = <String>{
      for (final t in _activity) t.videoId,
      for (final t in _liked) t.videoId,
    };
    final artistKeys = shelfArtistKeys(
      artists: [..._recentArtists, ..._artists],
      tracks: [..._activity, ..._liked],
    );
    String itemId(ShelfItem item) => item is SongItem
        ? 's:${item.track.videoId}'
        : 'b:${(item as BrowseItem).browseId}';
    final shelfSig = shelves
        .map((s) => '${s.title}|${s.items.map(itemId).join(',')}')
        .join('\n');
    final profileSig =
        '${(trackIds.toList()..sort()).join(',')}\n'
        '${(artistKeys.toList()..sort()).join(',')}';
    final key = '$shelfSig\n$profileSig';
    if (key != _rankedShelvesKey) {
      _rankedShelvesKey = key;
      _rankedShelvesCache = rankShelvesByProfile(
        shelves,
        trackIds: trackIds,
        artistKeys: artistKeys,
      );
    }
    return _rankedShelvesCache ?? const [];
  }

  /// InnerTube-supplied custom mixes lifted out of the home shelves
  /// for the Mixed-for-you section: `VLRD…` mix playlist pages plus
  /// personalized mix seed cards (`RDEM…`/`RDCLAK…` watch cards such
  /// as My Mix or Discover Mix).
  List<HomeMix> get mixes => mixesOfShelves(home.shelves);

  /// Whether [item] is a mix (a `VLRD…` playlist page or a mix seed
  /// card) that the "Albums made for you" section already shows. Leftover
  /// shelves must not re-render these, or the same mix appears twice —
  /// once under its feed shelf and once under "Albums made for you".
  static bool isMixItem(ShelfItem item) {
    if (item is BrowseItem) return item.browseId.startsWith('VLRD');
    if (item is SongItem) return isMixSeed(item.track);
    return false;
  }

  /// True when [track] is a personalized mix seed card rather than a
  /// plain song: its radio list (not the single video) is the mix.
  /// Song radios (`RDAMVM…`, carried by every song card) are excluded.
  static bool isMixSeed(Track track) {
    final pid = track.playlistId ?? '';
    return pid.startsWith('RDEM') || pid.startsWith('RDCLAK');
  }

  /// True when [item] is the "Liked Music" auto-playlist the feed
  /// offers as a suggested playlist.
  ///
  /// The home lists the liked songs in its own column, so the card
  /// would only repeat it. Matched on the browse id, not the title:
  /// the feed names the playlist differently per locale.
  static bool isLikedPlaylistCard(ShelfItem item) =>
      item is BrowseItem && item.browseId == 'VLLM';

  /// The feed's shelves without the "Liked Music" card.
  static List<Shelf> withoutLikedPlaylistCard(List<Shelf> shelves) => [
    for (final shelf in shelves)
      Shelf(
        shelf.title,
        shelf.items.where((item) => !isLikedPlaylistCard(item)).toList(),
        continuation: shelf.continuation,
      ),
  ];

  /// Loads the next page of [shelf] (its continuation token) and appends
  /// the new items to it, replacing the shelf in [home.shelves]. Only one
  // load per shelf at a time; a shelf without a continuation is a no-op.
  Future<void> loadMoreShelf(Shelf shelf) async {
    if (!shelf.hasMore || _loadingMoreShelves.contains(shelf.title)) return;
    _loadingMoreShelves.add(shelf.title);
    // Notify for the spinner: without this the flag is read (as a
    // plain method call in build) only on unrelated notifications, so
    // the in-flight indicator never shows while the fetch runs.
    _safeNotify();
    try {
      final more = await tube.loadMoreShelf(shelf.continuation!);
      if (more.items.isEmpty) return;
      final updated = Shelf(shelf.title, [
        ...shelf.items,
        // The feed's suggested "Liked Music" card never shows.
        ...more.items.where((item) => !isLikedPlaylistCard(item)),
      ], continuation: more.continuation);
      home = home.copyWith(
        shelves: [
          for (final s in home.shelves)
            if (s.title == shelf.title) updated else s,
        ],
      );
      _safeNotify();
    } finally {
      _loadingMoreShelves.remove(shelf.title);
      _safeNotify();
    }
  }

  /// Collects deduplicated mixes from [shelves] in feed order.
  static List<HomeMix> mixesOfShelves(List<Shelf> shelves) {
    final seen = <String>{};
    final out = <HomeMix>[];
    void add(HomeMix mix, String key) {
      if (seen.add(key)) out.add(mix);
    }

    for (final shelf in shelves) {
      for (final item in shelf.items) {
        if (item is BrowseItem) {
          if (!item.browseId.startsWith('VLRD')) continue;
          add(
            HomeMix(
              title: item.title,
              subtitle: item.subtitle,
              thumbnails: item.thumbnails,
              browseId: item.browseId,
            ),
            item.browseId,
          );
        } else if (item is SongItem) {
          final seed = item.track;
          final pid = seed.playlistId ?? '';
          if (!isMixSeed(seed)) continue;
          final artists = seed.artistNames().trim();
          add(
            HomeMix(
              title: seed.title,
              subtitle: artists.isEmpty ? 'Mix' : artists,
              thumbnails: seed.thumbnails,
              browseId: 'VL$pid',
              seed: seed,
            ),
            'VL$pid',
          );
        }
      }
    }
    return out;
  }

  /// Plays a home mix: seed cards resolve through their radio list,
  /// playlist pages open as a playlist.
  Future<void> playMix(HomeMix mix) async {
    if (mix.seed != null) {
      await playMixSeed(mix.seed!);
      return;
    }
    final browseId = mix.browseId;
    if (browseId == null || browseId.isEmpty) return;
    PlaylistDetail? pl;
    try {
      pl = await _tube.playlist(browseId);
    } catch (_) {
      return;
    }
    final tracks = pl?.tracks.where((t) => t.videoId.isNotEmpty).toList() ?? [];
    if (tracks.isEmpty) return;
    playSongs(tracks, 0);
  }

  /// Plays a personalized mix seed card: the seed first, then its
  /// radio mix behind it (same shape as single-track playback).
  Future<void> playMixSeed(Track seed) async {
    final pid = seed.playlistId;
    if (pid == null || pid.isEmpty) return;
    List<Track> mix;
    try {
      mix = await _tube.upNext(seed.videoId, playlistId: pid);
    } catch (_) {
      return;
    }
    final upcoming = mix.where((t) => t.videoId != seed.videoId).toList();
    playSongs([seed, ...upcoming], 0);
  }

  int _searchGen = 0;
  int _detailGen = 0;
  int _homeGen = 0;

  /// Last queue identity seen on the player stream (video ids only;
  /// rating restamps must not retrigger). A change means new tracks
  /// entered Up Next, so their like states need a stamp pass.
  String _lastQueueKey = '';

  /// Reloads the home shelves feed from InnerTube.
  ///
  /// Generation-fenced with an overall timeout: concurrent reloads
  /// can't clobber each other, and even a hung transport lands in
  /// the error state (with Retry) instead of a forever spinner.
  Future<void> loadHome() async {
    final gen = ++_homeGen;
    home = home.copyWith(loading: true, error: null);
    _safeNotify();
    try {
      final homeFuture = _tube.home();
      // Explore feeds the pinned editorial sections; its failure must
      // not sink the home feed, so it degrades to no explore shelves.
      final exploreFuture = _tube.explore().catchError((_) => const <Shelf>[]);
      // Charts feed the country label and the worldwide chart row; a
      // failure there must not sink the rest either.
      final chartsFuture = _tube.charts().catchError(
        (_) => (country: null, tracks: const <Track>[]),
      );
      final feed = await homeFuture.timeout(const Duration(seconds: 60));
      final exploreShelves = await exploreFuture.timeout(
        const Duration(seconds: 60),
        onTimeout: () => const <Shelf>[],
      );
      final charts = await chartsFuture.timeout(
        const Duration(seconds: 60),
        onTimeout: () => (country: null, tracks: const <Track>[]),
      );
      if (gen != _homeGen) return;
      home = home.copyWith(
        shelves: _stampShelves(withoutLikedPlaylistCard(feed.shelves)),
        explore: _stampShelves(withoutLikedPlaylistCard(exploreShelves)),
        country: charts.country,
        globalTrending: charts.tracks
            .take(_globalTrendingMax)
            .toList(growable: false),
        moods: feed.moods,
      );
      unawaited(_healShelfArtists(gen));
    } catch (e) {
      if (gen != _homeGen) return;
      home = home.copyWith(
        error: e is TimeoutException
            ? 'Home timed out — check connection.'
            : friendlyError(e),
      );
    } finally {
      if (gen == _homeGen) {
        home = home.copyWith(loading: false);
        _safeNotify();
      }
    }
  }

  /// Heals distributor-placeholder credits ("Release") on home shelf
  /// rows in the background. Notifies only when a credit changed and
  /// this load is still current.
  Future<void> _healShelfArtists(int gen) async {
    final songTracks = [
      for (final shelf in home.shelves)
        for (final item in shelf.items)
          if (item is SongItem) item.track,
    ];
    if (songTracks.every((t) => !hasGenericReleaseArtist(t))) return;
    final before = songTracks
        .map((t) => '${t.videoId}=${t.artistNames()}')
        .join('\n');
    final fixed = await fixReleaseCredits(songTracks);
    if (gen != _homeGen) return;
    final byId = {for (final t in fixed) t.videoId: t};
    home = home.copyWith(
      shelves: [
        for (final shelf in home.shelves)
          Shelf(shelf.title, [
            for (final item in shelf.items)
              item is SongItem
                  ? SongItem(byId[item.track.videoId] ?? item.track)
                  : item,
          ]),
      ],
    );
    final after = home.shelves
        .expand((s) => s.items)
        .whereType<SongItem>()
        .map((i) => '${i.track.videoId}=${i.track.artistNames()}')
        .join('\n');
    if (after != before) notifyListeners();
  }

  File get _searchHistoryFile => File('${configDir().path}/search-history.txt');

  List<String> searchHistory = [];

  void _loadSearchHistory() {
    try {
      final f = _searchHistoryFile;
      if (!f.existsSync()) {
        searchHistory = [];
        return;
      }
      searchHistory = f
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toSet()
          .take(12)
          .toList();
    } catch (_) {
      searchHistory = [];
    }
  }

  void _recordSearchHistory(String query) {
    searchHistory = [
      query,
      ...searchHistory.where((q) => q.toLowerCase() != query.toLowerCase()),
    ].take(12).toList();
    unawaited(() async {
      try {
        await _searchHistoryFile.writeAsString('${searchHistory.join('\n')}\n');
      } catch (_) {}
    }());
  }

  /// Clears the in-memory and persisted search history.
  void clearSearchHistory() {
    searchHistory = [];
    unawaited(() async {
      try {
        final f = _searchHistoryFile;
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }());
    _safeNotify();
  }

  /// Drops one query from the in-memory and persisted search history.
  void removeSearchHistory(String query) {
    final key = query.trim().toLowerCase();
    if (key.isEmpty) return;
    final kept = searchHistory.where((q) => q.toLowerCase() != key).toList();
    if (kept.length == searchHistory.length) return;
    searchHistory = kept;
    unawaited(() async {
      try {
        await _searchHistoryFile.writeAsString('${searchHistory.join('\n')}\n');
      } catch (_) {}
    }());
    _safeNotify();
  }

  /// Runs a search and enriches song rows, cancelling older queries.
  Future<void> searchFor(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    _recordSearchHistory(normalized);
    final gen = ++_searchGen;
    search = SearchUiState(query: normalized, loading: true);
    _safeNotify();
    try {
      final sections = await _tube.search(normalized);
      if (gen != _searchGen) return;
      search = SearchUiState(
        query: normalized,
        loading: false,
        sections: _stampSearchSections(sections),
      );
      _safeNotify();
      final songs =
          sections['Songs']
              ?.whereType<SongItem>()
              .map((e) => e.track)
              .toList() ??
          [];
      if (songs.isNotEmpty) {
        final enriched = await _tube.enrichTracks(songs);
        if (gen != _searchGen) return;
        final byId = {for (final t in enriched) t.videoId: t};
        final stamped = <String, List<ShelfItem>>{};
        search.sections.forEach((key, items) {
          stamped[key] = items.map((item) {
            if (item is SongItem) {
              final fresh = byId[item.track.videoId];
              return fresh == null ? item : SongItem(fresh);
            }
            return item;
          }).toList();
        });
        search = SearchUiState(
          query: normalized,
          loading: false,
          sections: _stampSearchSections(stamped),
        );
        for (final t in enriched) {
          if (t.rating != RatingStatus.unknown &&
              _trustNetworkRating(t.videoId, t.rating)) {
            _ratingCache[t.videoId] = t.rating;
          }
        }
      }
    } catch (e) {
      if (gen != _searchGen) return;
      search = SearchUiState(
        query: normalized,
        loading: false,
        error: friendlyError(e),
      );
    }
    _safeNotify();
  }

  /// Clears the current search results and query.
  void clearSearch() {
    search = SearchUiState();
    _safeNotify();
  }

  /// Runs [searchFor] and navigates to the Search screen.
  void searchAndGo(String query) {
    unawaited(searchFor(query));
    go(Screen.search);
  }

  /// Plays [songs] starting at [index]. A lone track plays as its own
  /// radio station instead of a one-song queue (see [playSingle]).
  void playSongs(List<Track> songs, int index) {
    if (songs.length == 1) {
      unawaited(playSingle(songs.first));
      return;
    }
    _player.playTracks(songs, index);
  }

  /// Plays [track] immediately, then appends its radio mix behind it.
  ///
  /// Used for single taps (search results, single-track releases):
  /// playback starts at once from the track alone, and the watch-next
  /// mix lands via [PlayerController.appendRadio] without restarting
  /// the track. Stale fetches (user moved on meanwhile) are dropped.
  Future<void> playSingle(Track track) async {
    _player.playTracks([track], 0);
    List<Track> upcoming;
    try {
      final radio =
          (track.radioPlaylistId != null && track.radioPlaylistId!.isNotEmpty)
          ? track.radioPlaylistId!
          : 'RDAMVM${track.videoId}';
      upcoming = await _tube.upNext(track.videoId, playlistId: radio);
    } catch (_) {
      return;
    }
    if (_player.state.current?.videoId != track.videoId) return;
    upcoming = upcoming.where((t) => t.videoId != track.videoId).toList();
    _player.appendRadio(upcoming);
  }

  /// Plays [songs] in shuffled order.
  void playShuffled(List<Track> songs) {
    if (songs.isEmpty) return;
    final shuffled = List<Track>.of(songs)..shuffle(Random());
    _player.playTracks(shuffled, 0);
  }

  /// Plays an artist's full top-songs playlist from the tapped song onward.
  Future<void> playArtistTopSong(ArtistDetail artist, int index) async {
    final preview = artist.topSongs;
    if (index < 0 || index >= preview.length) return;
    final tapped = preview[index];
    List<Track>? full;
    try {
      final pid = artist.songsPlaylistId;
      if (pid != null) {
        full = (await _tube.playlist(
          pid,
          params: artist.songsPlaylistParams,
        ))?.tracks.takeIfNotEmpty();
      }
    } catch (_) {}
    if (full != null) {
      var pos = full.indexWhere((t) => t.videoId == tapped.videoId);
      if (pos < 0) pos = 0;
      playSongs(full, pos);
    } else {
      playSongs(preview, index);
    }
  }

  /// Plays an artist's full top-songs playlist, optionally shuffled.
  Future<void> playArtistSongs(ArtistDetail artist, bool shuffled) async {
    List<Track> tracks = artist.topSongs;
    try {
      final pid = artist.songsPlaylistId;
      if (pid != null) {
        final full = (await _tube.playlist(
          pid,
          params: artist.songsPlaylistParams,
        ))?.tracks.takeIfNotEmpty();
        if (full != null) tracks = full;
      }
    } catch (_) {}
    if (tracks.isEmpty) return;
    if (shuffled) {
      playShuffled(tracks);
    } else {
      playSongs(tracks, 0);
    }
  }

  /// Starts a song radio station from [track] plus its watch-next mix.
  ///
  /// When [track] is already playing, the mix takes over Up next
  /// (everything behind the current position is replaced) while the
  /// song keeps playing from its live position instead of restarting.
  /// A different seed starts a fresh station from its first beat.
  ///
  /// Returns how many station tracks were queued (excluding the seed)
  /// and whether the mix loaded at all, so callers can tell a loaded
  /// station from a failed fetch instead of leaving a silent no-op.
  Future<({int queued, bool loaded})> startRadio(Track track) async {
    if (_player.state.current?.videoId == track.videoId) {
      List<Track> upcoming;
      try {
        final radio =
            (track.radioPlaylistId != null && track.radioPlaylistId!.isNotEmpty)
            ? track.radioPlaylistId!
            : 'RDAMVM${track.videoId}';
        upcoming = await _tube.upNext(track.videoId, playlistId: radio);
      } catch (_) {
        return (queued: 0, loaded: false);
      }
      if (_player.state.current?.videoId != track.videoId) {
        return (queued: 0, loaded: false);
      }
      upcoming = upcoming.where((t) => t.videoId != track.videoId).toList();
      final fresh = _player.replaceUpcoming(upcoming);
      return (queued: fresh, loaded: true);
    }
    final radio =
        (track.radioPlaylistId != null && track.radioPlaylistId!.isNotEmpty)
        ? track.radioPlaylistId!
        : 'RDAMVM${track.videoId}';
    List<Track> upcoming;
    var loaded = true;
    try {
      upcoming = await _tube.upNext(track.videoId, playlistId: radio);
    } catch (_) {
      upcoming = [];
      loaded = false;
    }
    upcoming = upcoming.where((t) => t.videoId != track.videoId).toList();
    final seen = {track.videoId};
    upcoming = upcoming.where((t) => seen.add(t.videoId)).toList();
    _player.playTracks([track, ...upcoming], 0);
    return (queued: upcoming.length, loaded: loaded);
  }

  /// Starts an artist radio station from their first top song.
  /// Returns how many station tracks were queued (see [startRadio]).
  Future<({int queued, bool loaded})> startArtistRadio(
    ArtistDetail artist,
  ) async {
    if (artist.topSongs.isEmpty) return (queued: 0, loaded: false);
    return startRadio(artist.topSongs.first);
  }

  void _loadDetail(BrowseItem item) {
    final gen = ++_detailGen;
    detail = DetailUiState(loading: true);
    _safeNotify();
    unawaited(() async {
      try {
        if (item.browseId.startsWith('UC')) {
          final artist = await _tube.artist(item.browseId);
          if (gen != _detailGen) return;
          detail = DetailUiState(loading: false, artist: artist);
        } else if (item.browseId.startsWith('MPRE')) {
          final album = await _tube.album(item.browseId);
          if (gen != _detailGen) return;
          detail = DetailUiState(loading: false, album: album);
          if (album != null) _stampDetailRatings(gen, album.tracks);
        } else {
          final playlist = await _tube.playlist(
            item.browseId,
            params: item.browseParams,
          );
          if (gen != _detailGen) return;
          detail = DetailUiState(loading: false, playlist: playlist);
          if (playlist != null) {
            _stampDetailRatings(gen, playlist.tracks);
          }
        }
      } catch (e) {
        if (gen != _detailGen) return;
        detail = DetailUiState(loading: false, error: friendlyError(e));
      }
      _safeNotify();
    }());
  }

  // ---------- Account / library ----------

  String? _account;
  String? get account => testAccount ?? _account;

  /// Test-only sign-in stub: widget tests set this (with
  /// [libraryOverride]) to reach signed-in UI without running
  /// the login flow, which would touch the real auth files
  /// on disk and the network.
  @visibleForTesting
  String? testAccount;

  /// Test-only library stub (avoids network in widget tests).
  @visibleForTesting
  AccountLibrary? libraryOverride;

  String? _accountAvatar;
  String? get accountAvatar => _accountAvatar;

  /// Full InnerTube access needs cookie + derived hash; Bearer-only
  /// sessions are limited.
  bool get authFull {
    final s = _tube.auth;
    return (s.cookie != null && s.cookie!.isNotEmpty) &&
        (s.sapisidHash != null && s.sapisidHash!.isNotEmpty);
  }

  /// Whether a cookie session is saved at all.
  bool get hasCookieSession => (_tube.auth.cookie ?? '').isNotEmpty;

  /// True when the saved cookie session still reads the library.
  /// Re-checked at most every [_loginCheckIntervalMs]; starts
  /// optimistic so the UI doesn't flash "expired" before the
  /// first check lands.
  bool get loginValid => _playback.loginValid;

  /// The account library in use: the test stub when set, the
  /// InnerTube-backed one otherwise.
  AccountLibrary get _api => libraryOverride ?? _library;

  /// True when the account library is reachable (signed in).
  bool get libraryAvailable => account != null;

  /// True when the account session is usable: the browser cookie
  /// session carries the library (playlists, liked songs, recent
  /// activity, followed artists), so one sign-in covers them all.
  bool get signedIn => hasCookieSession;

  /// Whether the stored session has been read.
  ///
  /// The credentials come from the secret store, so the session is
  /// restored asynchronously: until this is true the app does not know
  /// yet whether the account is signed in.
  bool _authLoaded = false;
  bool get authLoaded => _authLoaded;

  /// Whether the first-run setup still has to be shown.
  ///
  /// It shows once, on the first start: a fresh install has no
  /// session yet, while an account that is already signed in has
  /// nothing to set up. The session is read asynchronously, so the
  /// setup waits for it — otherwise a returning user would see it
  /// flash by.
  bool get needsOnboarding =>
      _onboardingRequested ||
      (!config.getBool('onboarding.done') && !hasCookieSession && _authLoaded);

  /// Whether the setup is being re-run on request.
  bool _onboardingRequested = false;

  /// Puts the first-run setup back, so it can be walked through again.
  void restartOnboarding() {
    _onboardingRequested = true;
    _safeNotify();
  }

  /// Marks the first-run setup as done, for good.
  void completeOnboarding() {
    _onboardingRequested = false;
    config.setBool('onboarding.done', true);
    _safeNotify();
  }

  List<AccountPlaylist> _playlists = [];
  List<AccountPlaylist> get playlists => _playlists;

  List<Track> _liked = [];
  List<Track> get liked => _liked;

  /// The song count YouTube reports for the liked-music playlist.
  ///
  /// It counts every entry of the playlist, while the shelf renders
  /// only the ones it can show, so it can be larger than the number
  /// of listed rows — exactly as in YouTube Music itself.
  int? _likedCount;

  /// YouTube's own cover for the liked-music playlist.
  String? _likedCover;

  /// A short note when the liked list holds fewer songs than the
  /// playlist counts, null when every song of it is listed.
  ///
  /// YouTube's playlist header counts every entry of the playlist while
  /// its shelf only renders the ones it can serve, so the two differ
  /// and the list has to say so.
  String? get likedLoadNote {
    final count = _likedCount;
    if (count == null || _liked.length >= count) return null;
    return '${_liked.length} of $count songs loaded';
  }

  List<BrowseItem> _artists = [];
  List<BrowseItem> get artists => _artists;

  OpenPlaylist? _openPlaylist;
  OpenPlaylist? get openedPlaylist => _openPlaylist;

  /// Guards openPlaylist loads: closing or opening another playlist
  /// invalidates in-flight fetches so a stale one can never pop over
  /// the new view (or reopen a closed one) when it lands.
  int _openPlaylistGen = 0;

  bool _libraryLoading = false;
  bool get libraryLoading => _libraryLoading;

  List<Track> _activity = [];
  List<Track> get activity => _activity;

  /// Enriched track metadata remembered across launches (panel artists,
  /// album, explicit flag), keyed by video id. Library lists (liked,
  /// activity) carry thin credits — single channel artist, tag album
  /// or none, never explicit — and only a watch-next panel fills them
  /// in. Stamping the cache paints full rows instantly on cold start;
  /// the background refresh heals whatever the cache misses,
  /// chunk by chunk. Trimmed to the most recently verified entries.
  static const _trackMetaCap = 500;
  final Map<String, _TrackMeta> _trackMeta = {};

  /// The on-disk caches (JSON files next to the settings).
  late final CacheStore _caches = CacheStore(dir: _config.directory);

  /// The caches that used to be properties in the settings file.
  static const _legacyCacheKeys = <String, String>{
    'trackMeta': 'home.trackMeta',
    'localRecents': 'home.localRecents',
    'playCounts': 'home.playCounts',
    'artistAvatars': 'home.artistAvatars',
  };

  /// Reads a cache from its own file.
  ///
  /// The first read after the upgrade still finds the cache in the
  /// settings file (it held escaped JSON); it is moved to its file
  /// once and the property is dropped.
  String? _readCache(String name) {
    final raw = _caches.read(name);
    if (raw != null) return raw;
    final key = _legacyCacheKeys[name];
    if (key == null) return null;
    final legacy = _config.get(key, '');
    if (legacy.isEmpty) return null;
    _caches.write(name, legacy);
    _config.remove(key);
    return legacy;
  }

  /// Writes a cache to its own file.
  void _writeCache(String name, String json) => _caches.write(name, json);

  void _loadTrackMeta() {
    try {
      final raw = _readCache('trackMeta');
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        if (k is String && k.isNotEmpty) {
          final m = _TrackMeta.fromJson(v);
          if (m != null) _trackMeta[k] = m;
        }
      });
    } catch (_) {}
  }

  void _saveTrackMeta() {
    try {
      var entries = _trackMeta.entries.toList();
      if (entries.length > _trackMetaCap) {
        entries = entries.sublist(entries.length - _trackMetaCap);
        _trackMeta
          ..clear()
          ..addEntries(entries);
      }
      _writeCache(
        'trackMeta',
        jsonEncode({for (final e in entries) e.key: e.value.toJson()}),
      );
    } catch (_) {}
  }

  /// Panel (or remembered panel) artists win over thin credits: empty,
  /// placeholder, or a single unbrowsable credit that never saw feat.
  /// artists or an explicit verdict. Multi-artist and linked credits
  /// are assumed panel-complete, except a same-name link upgrade.
  /// Null means "keep the existing credit".
  List<ArtistRef>? _adoptArtists(Track t, List<ArtistRef> incoming) {
    if (incoming.isEmpty) return null;
    if (t.artists.isEmpty || hasGenericReleaseArtist(t)) {
      return List.of(incoming);
    }
    if (t.artists.length == 1 && (t.artists.single.browseId ?? '').isEmpty) {
      return List.of(incoming);
    }
    if (incoming.length == 1 && t.artists.length == 1) {
      final cur = t.artists.single;
      final inc = incoming.single;
      if ((cur.browseId ?? '').isEmpty &&
          (inc.browseId ?? '').isNotEmpty &&
          canonical(cur.name) == canonical(inc.name)) {
        return List.of(incoming);
      }
    }
    return null;
  }

  /// Paints cached enrichment onto [track] without network: fuller
  /// artists over thin credits, album over none, explicit OR-ed in
  /// (a missing badge means unmarked, not clean — but the cache only
  /// ever stores positive verdicts).
  Track _withCachedMeta(Track t) {
    final m = _trackMeta[t.videoId];
    if (m == null) return t;
    var out = t;
    final artists = _adoptArtists(t, m.artists);
    if (artists != null) out = out.copyWith(artists: artists);
    if (m.album != null && t.album == null) {
      out = out.copyWith(album: m.album);
    }
    if (m.explicit && !t.explicit) {
      out = out.copyWith(explicit: true);
    }
    return out;
  }

  List<Track> _stampTrackMeta(List<Track> tracks) =>
      tracks.map(_withCachedMeta).toList();

  /// True when [t] still needs a panel read: uncached plus thin
  /// credits (placeholder artist, no album, or a single unbrowsable
  /// credit that never saw feat. artists or an explicit verdict).
  /// Fully linked tracks are assumed panel-complete — explicit can
  /// never be proven absent, so it is not chased on its own.
  bool _metaSparse(Track t) {
    if (t.videoId.isEmpty || _trackMeta.containsKey(t.videoId)) return false;
    if (hasGenericReleaseArtist(t) || t.album == null) return true;
    return t.artists.length <= 1 &&
        (t.artists.isEmpty || (t.artists.single.browseId ?? '').isEmpty);
  }

  /// Heals thin liked/activity credits chunk by chunk, painting each
  /// chunk as it lands instead of parking the lists behind the whole
  /// fetch. Merges panel fields (never ratings), remembers what it
  /// learned, and refreshes the open liked view in passing. Aborts
  /// when the library reloads underneath it.
  Future<void> refreshTrackMeta() async {
    final beforeIds = _liked.map((t) => t.videoId).join(',');
    final targets = <Track>[];
    final seen = <String>{};
    for (final t in [..._liked, ..._activity]) {
      if (t.videoId.isNotEmpty && seen.add(t.videoId) && _metaSparse(t)) {
        targets.add(t);
      }
    }
    if (targets.isEmpty) return;
    const chunk = 12;
    for (var i = 0; i < targets.length; i += chunk) {
      if (_liked.map((t) => t.videoId).join(',') != beforeIds) return;
      final end = (i + chunk < targets.length) ? i + chunk : targets.length;
      List<Track> enriched;
      try {
        enriched = await _tube.enrichTracks(
          targets.sublist(i, end),
          concurrency: 6,
        );
      } catch (_) {
        continue;
      }
      final byId = {for (final t in enriched) t.videoId: t};
      var rowsChanged = false;
      var cacheChanged = false;
      Track merge(Track t) {
        final e = byId[t.videoId];
        if (e == null) return t;
        var out = t;
        final artists = _adoptArtists(t, e.artists);
        if (artists != null) out = out.copyWith(artists: artists);
        if (e.album != null && t.album == null) {
          out = out.copyWith(album: e.album);
        }
        if (e.explicit && !t.explicit) {
          out = out.copyWith(explicit: true);
        }
        if (out != t) {
          rowsChanged = true;
          // Refresh recency (reinsert at the end) so trimming drops
          // the least-recently-verified entries first.
          _trackMeta.remove(t.videoId);
          _trackMeta[t.videoId] = _TrackMeta(
            artists: List.of(out.artists),
            album: out.album,
            explicit: out.explicit,
          );
          cacheChanged = true;
        }
        return out;
      }

      _liked = _liked.map(merge).toList();
      _activity = _stampKnownRatings(_activity.map(merge).toList());
      if (!rowsChanged) continue;
      _refreshRecentArtists();
      _updateLikedPlaylistEntry();
      final opened = _openPlaylist;
      if (opened != null && opened.playlist.id == '__liked') {
        _openPlaylist = OpenPlaylist(
          opened.playlist,
          _stampLikedIds(List.of(_liked)),
        );
      }
      if (cacheChanged) _saveTrackMeta();
      _safeNotify();
    }
  }

  /// Locally-played tracks (this session plus persisted recents from
  /// previous ones), most recent first. Server history lags behind
  /// what just played, so these are merged ahead of it on every
  /// library load — otherwise just-played songs vanish from quick
  /// picks until the server catches up.
  static const _localRecentCap = 30;
  List<Track> _localRecents = [];

  void _loadLocalRecents() {
    try {
      final raw = _readCache('localRecents');
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _localRecents = decoded
          .map(_decodeRecentTrack)
          .whereType<Track>()
          .take(_localRecentCap)
          .toList();
    } catch (_) {}
  }

  /// Best-effort decode of one persisted recent; null when the stored
  /// JSON no longer parses (schema drift must never break startup).
  static Track? _decodeRecentTrack(dynamic e) {
    if (e is! Map) return null;
    try {
      return Track.fromJson(e.map((k, v) => MapEntry(k.toString(), v)));
    } catch (_) {
      return null;
    }
  }

  void _saveLocalRecents() {
    try {
      _writeCache(
        'localRecents',
        jsonEncode([for (final t in _localRecents) t.toJson()]),
      );
    } catch (_) {}
  }

  /// Local play counts by video id, bumped every time a new track
  /// starts and persisted across launches. Quick picks ranks recent
  /// songs by these ("most listened first"); entries for songs long
  /// out of rotation are pruned on save so the map stays small.
  /// Counts only cover this device — server history carries no play
  /// numbers, so those songs rank 0.
  static const _playCountCap = 300;
  Map<String, int> _playCounts = {};

  /// Local play counts by video id (read-only use).
  Map<String, int> get playCounts => _playCounts;

  void _loadPlayCounts() {
    try {
      final raw = _readCache('playCounts');
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        if (k is String && k.isNotEmpty && v is int && v > 0) {
          _playCounts[k] = v;
        }
      });
    } catch (_) {}
  }

  void _savePlayCounts() {
    try {
      var entries = _playCounts.entries.toList();
      if (entries.length > _playCountCap) {
        entries.sort((a, b) => b.value.compareTo(a.value));
        entries = entries.take(_playCountCap).toList();
        _playCounts
          ..clear()
          ..addEntries(entries);
      }
      _writeCache(
        'playCounts',
        jsonEncode({for (final e in entries) e.key: e.value}),
      );
    } catch (_) {}
  }

  /// Imports YouTube watch history into the local play counts:
  /// history entries repeat per play, so occurrence counts merge
  /// with local counts, max wins. Max (not sum), because the
  /// history window overlaps recent local plays and summing would
  /// double-count them. Runs on login and session restore (effectively
  /// once per launch); empty remote results keep existing counts.
  /// The top history tracks are also kept for the quick-picks pool
  /// (in memory only) so heavy rotation from other sessions can
  /// surface here. Both maps are reassigned (not mutated) so the
  /// home selects fire and quick picks re-rank.
  List<Track> _historyTracks = [];

  /// Top watch-history tracks by merged play count, for the
  /// quick-picks pool. In-memory only; refreshed by [importHistoryCounts].
  List<Track> get historyTracks => _historyTracks;

  Future<void> importHistoryCounts() async {
    ({Map<String, int> counts, List<Track> tracks}) snap;
    try {
      snap = await _tube.historySnapshot();
    } catch (_) {
      return;
    }
    if (snap.counts.isEmpty) return;
    final merged = Map<String, int>.of(_playCounts);
    var changed = false;
    snap.counts.forEach((id, n) {
      if (id.isEmpty || n <= 0) return;
      if (n > (merged[id] ?? 0)) {
        merged[id] = n;
        changed = true;
      }
    });
    final byId = <String, Track>{};
    for (final t in snap.tracks) {
      if (t.videoId.isNotEmpty) byId.putIfAbsent(t.videoId, () => t);
    }
    final top = byId.values.toList()
      ..sort(
        (a, b) => (merged[b.videoId] ?? 0).compareTo(merged[a.videoId] ?? 0),
      );
    _historyTracks = top.take(30).toList();
    if (changed) {
      _playCounts = merged;
      _savePlayCounts();
    }
    _safeNotify();
  }

  List<Track> _discover = [];
  List<Track> get discover => _discover;

  /// Per-launch shuffle nonce for the quick-picks grid: mixed into
  /// the deterministic picks seed so the grid rotates every app
  /// start instead of looking frozen while the library is static.
  /// Final per AppState, so the order never jumps mid-session.
  final int quickPicksNonce = Random().nextInt(1 << 31);

  /// User-pinned quick picks, most recent pin last. YTM pins live
  /// only in the official clients, so pins are stored locally as
  /// snapshots and rendered ahead of the rotating pools.
  static const _pinnedPicksCap = 12;
  List<ShelfItem> _pinnedPicks = [];
  List<ShelfItem> get pinnedPicks => _pinnedPicks;

  static String? pickKeyOf(ShelfItem item) {
    if (item is SongItem) {
      return item.track.videoId.isEmpty ? null : 's:${item.track.videoId}';
    }
    if (item is BrowseItem) {
      return item.browseId.isEmpty ? null : 'b:${item.browseId}';
    }
    return null;
  }

  /// True when [item] (by video/browse id) is in the pinned list.
  bool isPinned(ShelfItem item) {
    final id = pickKeyOf(item);
    return id != null && _pinnedPicks.any((p) => pickKeyOf(p) == id);
  }

  /// Pins or unpins a quick-pick tile. Skeleton tiles and over-cap
  /// pins are ignored. Reassigns (never mutates) so selects detect
  /// the change and the grid rebuilds.
  void togglePin(ShelfItem item) {
    final id = pickKeyOf(item);
    if (id == null || id.startsWith('s:skeleton-')) return;
    if (_pinnedPicks.any((p) => pickKeyOf(p) == id)) {
      _pinnedPicks = [
        for (final p in _pinnedPicks)
          if (pickKeyOf(p) != id) p,
      ];
    } else {
      if (_pinnedPicks.length >= _pinnedPicksCap) return;
      _pinnedPicks = [..._pinnedPicks, item];
    }
    _savePinnedPicks();
    _safeNotify();
  }

  /// Snapshot encoding for one pin (static so it stays unit-testable
  /// without an AppState instance).
  static Map<String, dynamic> pinToJson(ShelfItem item) {
    if (item is SongItem) return {'k': 's', 'track': item.track.toJson()};
    final b = item as BrowseItem;
    return {
      'k': 'b',
      'title': b.title,
      'subtitle': b.subtitle,
      'browseId': b.browseId,
      'thumbnails': [for (final t in b.thumbnails) t.toJson()],
    };
  }

  /// Decodes one pin snapshot; null on any schema drift (a stale pin
  /// must never break startup).
  static ShelfItem? pinFromJson(dynamic e) {
    if (e is! Map) return null;
    try {
      if (e['k'] == 's') {
        final t = e['track'];
        if (t is! Map) return null;
        return ShelfItem.song(
          Track.fromJson(t.map((k, v) => MapEntry(k.toString(), v))),
        );
      }
      if (e['k'] == 'b') {
        final browseId = e['browseId']?.toString() ?? '';
        if (browseId.isEmpty) return null;
        final thumbs = e['thumbnails'];
        return ShelfItem.browse(
          title: e['title']?.toString() ?? '',
          subtitle: e['subtitle']?.toString() ?? '',
          browseId: browseId,
          thumbnails: [
            if (thumbs is List)
              for (final t in thumbs)
                if (t is Map)
                  Thumbnail.fromJson(
                    t.map((k, v) => MapEntry(k.toString(), v)),
                  ),
          ],
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  void _loadPinnedPicks() {
    try {
      final raw = _config.get('home.pinnedPicks', '');
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pinnedPicks = decoded
          .map(pinFromJson)
          .whereType<ShelfItem>()
          .take(_pinnedPicksCap)
          .toList();
    } catch (_) {}
  }

  void _savePinnedPicks() {
    try {
      _config.set(
        'home.pinnedPicks',
        jsonEncode([for (final p in _pinnedPicks) pinToJson(p)]),
      );
    } catch (_) {}
  }

  List<BrowseItem> _recentArtists = [];
  List<BrowseItem> get recentArtists => _recentArtists;

  final Map<String, String> _artistAvatarCache = {};

  /// Loads remembered channel avatars so recent artists paint profile
  /// pictures (not song covers) from the first frame. Empty values
  /// are negative cache (looked, none found).
  void _loadArtistAvatars() {
    try {
      final raw = _readCache('artistAvatars');
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        if (k is String && k.isNotEmpty && v is String) {
          _artistAvatarCache[k] = v;
        }
      });
    } catch (_) {}
  }

  void _saveArtistAvatars() {
    try {
      var entries = _artistAvatarCache.entries.toList();
      if (entries.length > 300) {
        entries = entries.sublist(entries.length - 300);
        _artistAvatarCache
          ..clear()
          ..addEntries(entries);
      }
      _writeCache(
        'artistAvatars',
        jsonEncode({for (final e in entries) e.key: e.value}),
      );
    } catch (_) {}
  }

  final Map<String, bool> _artistPageCache = {};
  String? _ownChannelId;
  bool _ownChannelIdLoaded = false;
  final Map<String, RatingStatus> _ratingCache = {};
  Set<String> _likedIds = {};

  /// Track lengths (seconds) learned for queue rows from the queue
  /// metadata pass, so a re-queued or re-opened row never costs another
  /// read. Ids an answer came back for without a length are remembered
  /// separately: asking again would only repeat the same empty answer.
  final Map<String, int> _knownDurations = {};
  final Set<String> _durationMisses = {};

  String? _loginDetail;
  String? get loginDetail => _loginDetail;

  bool _loginBusy = false;
  bool get loginBusy => _loginBusy;

  int _discoverGen = 0;
  int _avatarGen = 0;

  /// Loads fresh song suggestions from recent/liked seeds via mix stations.
  /// Falls back to InnerTube home shelves when history is missing.
  Future<void> loadDiscover() async {
    final gen = ++_discoverGen;
    List<Track> distinct(List<Track> tracks) {
      final seen = <String>{};
      return tracks.where((t) => seen.add(t.videoId)).toList();
    }

    var seeds = [
      ...distinct(_activity).take(3),
      ...(_liked.toList()..shuffle(Random())).take(2),
    ];
    seeds = distinct(seeds).take(5).toList();
    if (seeds.isEmpty) {
      try {
        final homeSeeds = <Track>[];
        final shelves = home.shelves.isNotEmpty
            ? home.shelves
            : (await _tube.home()).shelves;
        for (final shelf in shelves) {
          if (homeSeeds.length >= 5) break;
          for (final item in shelf.items) {
            if (item is SongItem) {
              homeSeeds.add(item.track);
              if (homeSeeds.length >= 5) break;
            }
          }
        }
        seeds = distinct(homeSeeds).take(5).toList();
      } catch (_) {
        seeds = [];
      }
    }
    if (seeds.isEmpty) return;
    final known = {
      ...seeds.map((t) => t.videoId),
      ..._activity.map((t) => t.videoId),
      ..._liked.map((t) => t.videoId),
    };
    final mixed = <Track>[];
    final results = await Future.wait(
      seeds.map((seed) async {
        final radioId =
            (seed.radioPlaylistId != null &&
                seed.radioPlaylistId!.trim().isNotEmpty)
            ? seed.radioPlaylistId!
            : 'RDAMVM${seed.videoId}';
        try {
          return await _tube.upNext(seed.videoId, playlistId: radioId);
        } catch (_) {
          return <Track>[];
        }
      }),
    );
    for (final list in results) {
      mixed.addAll(list);
    }
    if (gen != _discoverGen) return;
    final seen = <String>{};
    _discover = _stampKnownRatings(
      mixed
          .where(
            (t) =>
                t.videoId.isNotEmpty &&
                !known.contains(t.videoId) &&
                seen.add(t.videoId),
          )
          .take(20)
          .toList(),
    );
    if (_discover.isEmpty) return;
    _safeNotify();
  }

  /// Rebuilds the recent-artists list from activity credits.
  void _refreshRecentArtists() {
    final seen = <String, BrowseItem>{};
    for (final t in _activity) {
      for (final artist in t.artists) {
        final id = artist.browseId;
        final name = artist.name.trim();
        if (id == null || !id.startsWith('UC') || name.isEmpty) continue;
        seen.putIfAbsent(id, () {
          // Profile picture when remembered; the song cover only as a
          // last resort for ids never resolved (healed in background).
          final avatar = _artistAvatarCache[id];
          final thumbs = (avatar != null && avatar.isNotEmpty)
              ? [Thumbnail(avatar)]
              : t.thumbnails;
          return BrowseItem(
            title: name,
            subtitle: 'Artist',
            browseId: id,
            thumbnails: thumbs,
          );
        });
      }
    }
    _recentArtists = seen.values.take(20).toList();
    unawaited(_enrichRecentArtistArtwork());
  }

  /// Resolves real channel avatars for recent artists in batches of 50.
  /// Ids with a remembered avatar (hit or miss) are skipped; each
  /// batch persists so later launches paint profile pictures from
  /// the first frame instead of song covers.
  Future<void> _enrichRecentArtistArtwork() async {
    final api = _api;
    final ids = _recentArtists
        .map((e) => e.browseId)
        .toSet()
        .where((id) => !_artistAvatarCache.containsKey(id))
        .toList();
    if (ids.isEmpty) return;
    try {
      for (var i = 0; i < ids.length; i += 50) {
        final end = (i + 50 < ids.length) ? i + 50 : ids.length;
        final fetched = await api.channelAvatars(ids.sublist(i, end));
        for (final id in ids.sublist(i, end)) {
          final url = fetched[id] ?? '';
          // Known profile pictures are never overwritten with a miss.
          if (url.isNotEmpty || !_artistAvatarCache.containsKey(id)) {
            _artistAvatarCache[id] = url;
          }
        }
        _saveArtistAvatars();
        _recentArtists = _recentArtists.map((e) {
          final art = _artistAvatarCache[e.browseId];
          if (art == null || art.isEmpty) return e;
          return BrowseItem(
            title: e.title,
            subtitle: e.subtitle,
            browseId: e.browseId,
            thumbnails: [Thumbnail(art)],
            kind: e.kind,
            browseParams: e.browseParams,
          );
        }).toList();
        _safeNotify();
      }
    } catch (_) {}
  }

  /// Loads playlists, activity, subscriptions and liked songs concurrently.
  /// A failed slot keeps its last-known-good rows: only a successful
  /// fetch (even an empty one) replaces a list, so a transient blip
  /// can never wipe the library — liked songs included.
  Future<void> loadLibrary() async {
    final api = _api;
    _libraryLoading = true;
    _safeNotify();
    try {
      final results = await Future.wait<Object?>([
        api.playlists().then<Object?>((v) => v).catchError((_) => null),
        api.recentActivity().then<Object?>((v) => v).catchError((_) => null),
        api.subscriptions().then<Object?>((v) => v).catchError((_) => null),
        api
            .likedVideos(max: 150)
            .then<Object?>((v) => v)
            .catchError((_) => null),
      ]);
      final playlists = results[0];
      if (playlists is List<AccountPlaylist>) _playlists = playlists;
      // Fire-and-forget like Kotlin: covers pop in per chunk without
      // parking the library behind the slowest artwork fetch.
      unawaited(_enrichPlaylistArtwork());
      final activity = results[1];
      if (activity is List<Track>) {
        _activity = mergeLocalRecents(
          _stampKnownRatings(_stampTrackMeta(activity)),
          _localRecents,
        );
        _refreshRecentArtists();
      }
      final artists = results[2];
      if (artists is List<ShelfItem>) {
        _artists = artists.whereType<BrowseItem>().toList();
      }
      final liked = results[3];
      if (liked is List<Track>) {
        _liked = _stampTrackMeta(liked);
        // The playlist's own count, which can exceed the rows the
        // shelf renders.
        _likedCount = api.likedCount;
        _updateLikedPlaylistEntry();
        // The playlist's own cover, fetched once.
        if (_likedCover == null) unawaited(_loadLikedCover());
      }
    } finally {
      _libraryLoading = false;
      _safeNotify();
    }
    // Cached enrichment already painted above; the refresh heals
    // whatever the cache missed, chunk by chunk.
    unawaited(refreshTrackMeta());
    unawaited(loadDiscover());
    // Full liked list for library completeness, in the background.
    unawaited(() async {
      try {
        final full = await api.likedVideos();
        if (full.length > _liked.length) {
          _liked = _stampTrackMeta(full);
          _likedCount = api.likedCount;
          _updateLikedPlaylistEntry();
          _safeNotify();
          // The longer tail can carry fresh placeholder credits.
          unawaited(refreshTrackMeta());
        }
      } catch (_) {}
    }());
  }

  /// Fills missing playlist artwork in background chunks of 4 (Kotlin
  /// parity): largest InnerTube header art first, then the first tracks'
  /// artwork as a fallback. Track covers also backfill [AccountPlaylist.arts]
  /// whenever empty so cards and the header collage have something to show
  /// even when the header art resolved but no collage sources exist yet.
  /// Each resolved chunk refreshes the visible lists immediately instead
  /// of parking behind the slowest fetch.
  Future<void> _enrichPlaylistArtwork() async {
    final targets = _playlists.where((p) => p.id != '__liked').toList();
    if (targets.isEmpty) return;
    for (var i = 0; i < targets.length; i += 4) {
      final end = (i + 4 < targets.length) ? i + 4 : targets.length;
      final resolved = await Future.wait(
        targets.sublist(i, end).map((pl) async {
          String? art = pl.art;
          List<String> arts = pl.arts;
          // Always try InnerTube header art first — it may be larger/fresher
          // than the stored thumbnail, which for some playlists is a track
          // cover auto-generated by YouTube.
          try {
            final thumbs = await _tube.playlistArtwork(pl.id);
            if (thumbs.isNotEmpty) {
              art = thumbs.reduce((a, b) => a.width >= b.width ? a : b).url;
            }
          } catch (_) {}
          if (arts.isEmpty && art == null && pl.itemCount > 0) {
            try {
              final tracks = await _api.playlistTracks(pl.id, max: 4);
              final covers = tracks
                  .map((t) => t.displayArtwork)
                  .whereType<String>()
                  .where((u) => u.isNotEmpty)
                  .toList();
              if (covers.isNotEmpty) {
                art = covers.first;
                arts = covers;
              }
            } catch (_) {}
          }
          if (art == null || art.isEmpty) return pl;
          return AccountPlaylist(
            id: pl.id,
            title: pl.title,
            itemCount: pl.itemCount,
            art: art,
            arts: arts,
            owner: pl.owner,
            ownerId: pl.ownerId,
          );
        }),
      );
      final byId = {for (final p in resolved) p.id: p};
      var changed = false;
      _playlists = _playlists.map((p) {
        final r = byId[p.id];
        if (r != null && (r.art != p.art || r.arts.length != p.arts.length)) {
          changed = true;
          return r;
        }
        return p;
      }).toList();
      final opened = _openPlaylist;
      if (opened != null) {
        final r = byId[opened.playlist.id];
        if (r != null &&
            (r.art != opened.playlist.art ||
                r.arts.length != opened.playlist.arts.length)) {
          _openPlaylist = OpenPlaylist(r, opened.tracks);
          changed = true;
        }
      }
      if (changed) notifyListeners();
    }
  }

  /// Prepends the synthetic YTM-style "Liked songs" entry.
  void _updateLikedPlaylistEntry() {
    if (_liked.isNotEmpty) {
      final collage = _liked
          .take(4)
          .map((t) => t.displayArtwork)
          .whereType<String>()
          .toList();
      _playlists = [
        AccountPlaylist(
          id: '__liked',
          title: 'Liked songs',
          // YouTube's own count for the playlist: it counts every
          // entry, while the shelf only renders the ones it can show.
          itemCount: _likedCount ?? _liked.length,
          // The playlist's own cover, once it is fetched; the first
          // song's art stands in until then.
          art: _likedCover ?? (collage.isEmpty ? null : collage.first),
          arts: collage,
        ),
        ..._playlists.where((p) => p.id != '__liked'),
      ];
    }
  }

  /// Fetches YouTube's cover for the liked-music playlist.
  ///
  /// The library's "Liked songs" card shows the playlist's own art
  /// instead of a collage of the first songs.
  Future<void> _loadLikedCover() async {
    try {
      final thumbs = await _tube.playlistArtwork('VLLM');
      if (thumbs.isEmpty) return;
      // The card is small: take the smallest cover that still fills it
      // (the 1200px original is a needless download).
      final sorted = [...thumbs]..sort((a, b) => a.width.compareTo(b.width));
      var pick = sorted.first;
      for (final t in sorted) {
        pick = t;
        if (t.width >= 512) break;
      }
      final url = pick.url;
      if (url.isEmpty || url == _likedCover) return;
      _likedCover = url;
      _updateLikedPlaylistEntry();
      _safeNotify();
    } catch (_) {}
  }

  /// Resolves distributor-placeholder credits ("Release") in [tracks]
  /// via InnerTube's watch-next panel, which names the real artist
  /// when the stored tags don't. Only placeholder tracks are
  /// fetched; everything else passes through untouched.
  Future<List<Track>> fixReleaseCredits(List<Track> tracks) async {
    // Placeholder credits and album-less rows alike resolve through
    // InnerTube's watch-next panel (which also carries the explicit
    // flag the library list never sends).
    final targets = tracks
        .where((t) => hasGenericReleaseArtist(t) || t.album == null)
        .toList();
    if (targets.isEmpty) return tracks;
    try {
      final fixed = await _tube.enrichTracks(targets);
      final byId = {for (final t in fixed) t.videoId: t};
      return _stampKnownRatings(
        tracks.map((t) => byId[t.videoId] ?? t).toList(),
      );
    } catch (_) {
      return tracks;
    }
  }

  /// Opens the library playlist with [id].
  void openPlaylistById(String id) {
    for (final pl in _playlists) {
      if (pl.id == id) {
        unawaited(openPlaylist(pl));
        go(Screen.library);
        return;
      }
    }
  }

  /// Creates a new playlist and refreshes the library.
  /// Returns the new playlist's id, or null on failure.
  Future<String?> createPlaylist(String title) async {
    final api = _api;
    final id = await api.createPlaylist(title);
    if (id != null && id.isNotEmpty) {
      // Show the new playlist immediately; the refresh reconciles the
      // rest (counts, artwork) in the background.
      _playlists = [
        AccountPlaylist(id: id, title: title, itemCount: 0),
        ..._playlists.where((p) => p.id != id),
      ];
      _safeNotify();
      await loadLibrary();
    }
    return id;
  }

  /// Renames a playlist and refreshes the library.
  Future<bool> renamePlaylist(String playlistId, String newTitle) async {
    final api = _api;
    final ok = await api.renamePlaylist(playlistId, newTitle);
    if (ok) await loadLibrary();
    return ok;
  }

  /// Deletes a playlist, closes it if open, and refreshes the library.
  Future<bool> deletePlaylist(String playlistId) async {
    final api = _api;
    final ok = await api.deletePlaylist(playlistId);
    if (ok) {
      if (_openPlaylist?.playlist.id == playlistId) _openPlaylist = null;
      await loadLibrary();
    }
    return ok;
  }

  /// Removes [track] from [playlistId] and updates the open playlist in
  /// place (no reload) if it is the one being viewed.
  Future<bool> removeTrackFromPlaylist(String playlistId, Track track) async {
    final api = _api;
    final itemId = await api.playlistItemId(playlistId, track.videoId);
    if (itemId == null) return false;
    final ok = await api.removeFromPlaylist(playlistId, track.videoId, itemId);
    if (ok) {
      final opened = _openPlaylist;
      if (opened != null && opened.playlist.id == playlistId) {
        final remaining = opened.tracks
            .where((t) => t.videoId != track.videoId)
            .toList();
        _openPlaylist = OpenPlaylist(
          AccountPlaylist(
            id: opened.playlist.id,
            title: opened.playlist.title,
            itemCount: remaining.length,
            art: opened.playlist.art,
            arts: opened.playlist.arts,
            owner: opened.playlist.owner,
            ownerId: opened.playlist.ownerId,
          ),
          remaining,
        );
        _safeNotify();
      }
    }
    return ok;
  }

  /// Opens [pl], entering its screen immediately while tracks load.
  /// Stale loads (closed or superseded meanwhile) are dropped.
  Future<void> openPlaylist(AccountPlaylist pl) async {
    final gen = ++_openPlaylistGen;
    if (pl.id == '__liked') {
      _openPlaylist = OpenPlaylist(pl, _stampLikedIds(List.of(_liked)));
      // Panel enrichment (album/explicit/full credits — the library
      // lists send none) refreshes the open view progressively via
      // refreshTrackMeta, which republishes it per chunk.
      unawaited(refreshTrackMeta());
      unawaited(
        _requestTrackRatings(_openPlaylist!.tracks, (statuses) {
          final opened = _openPlaylist;
          if (opened != null && opened.playlist.id == pl.id) {
            _openPlaylist = OpenPlaylist(
              opened.playlist,
              opened.tracks
                  .map(
                    (t) => statuses[t.videoId] == null
                        ? t
                        : t.copyWith(rating: statuses[t.videoId]!),
                  )
                  .toList(),
            );
            _safeNotify();
          }
        }),
      );
      _safeNotify();
      return;
    }
    final api = _api;
    final current = _playlists.where((p) => p.id == pl.id).firstOrNull ?? pl;
    _openPlaylist = OpenPlaylist(current, []);
    _libraryLoading = true;
    _safeNotify();
    try {
      var tracks = await api.playlistTracks(pl.id);
      // Empty credits and distributor placeholders alike resolve
      // through InnerTube's watch-next panel.
      final sparse = tracks
          .where((t) => t.artists.isEmpty || hasGenericReleaseArtist(t))
          .toList();
      if (sparse.isNotEmpty) {
        try {
          final enriched = await _tube.enrichTracks(sparse);
          final byId = {for (final t in enriched) t.videoId: t};
          tracks = _stampKnownRatings(
            tracks.map((t) => byId[t.videoId] ?? t).toList(),
          );
        } catch (_) {}
      }
      tracks = _stampLikedIds(tracks);
      if (gen != _openPlaylistGen) return;
      _openPlaylist = OpenPlaylist(current, tracks);
      unawaited(
        _requestTrackRatings(tracks, (statuses) {
          final opened = _openPlaylist;
          if (gen != _openPlaylistGen) return;
          if (opened != null && opened.playlist.id == pl.id) {
            _openPlaylist = OpenPlaylist(
              opened.playlist,
              opened.tracks
                  .map(
                    (t) => statuses[t.videoId] == null
                        ? t
                        : t.copyWith(rating: statuses[t.videoId]!),
                  )
                  .toList(),
            );
            _safeNotify();
          }
        }),
      );
    } finally {
      // A stale load must not clear the new view's spinner.
      if (gen == _openPlaylistGen) {
        _libraryLoading = false;
        _safeNotify();
      }
    }
  }

  /// Closes the open playlist, returning to the library root.
  /// Invalidates any in-flight load so it cannot reopen the view.
  void closePlaylist() {
    ++_openPlaylistGen;
    _openPlaylist = null;
    _libraryLoading = false;
    _safeNotify();
  }

  // ---------- Playlist dialog ----------

  Track? _playlistDialogTrack;
  Track? get playlistDialogTrack => _playlistDialogTrack;

  Map<String, bool> _playlistMembership = {};
  Map<String, bool> get playlistMembership => _playlistMembership;

  final Map<String, String> _playlistItemIds = {};

  bool _playlistDialogLoading = false;
  bool get playlistDialogLoading => _playlistDialogLoading;

  String? _playlistDialogError;
  String? get playlistDialogError => _playlistDialogError;

  /// Opens the add-to-playlist dialog for [track].
  Future<void> openPlaylistDialog(Track track) async {
    _playlistDialogTrack = track;
    _playlistMembership = {};
    _playlistItemIds.clear();
    _playlistDialogError = null;
    _playlistDialogLoading = true;
    _safeNotify();
    final api = _api;
    try {
      final mine = _playlists.where((p) => p.id != '__liked').toList();
      var failed = 0;
      final results = await Future.wait(
        mine.map((pl) async {
          try {
            final itemId = await api.playlistItemId(pl.id, track.videoId);
            return MapEntry(pl.id, itemId);
          } catch (_) {
            failed++;
            return MapEntry(pl.id, null);
          }
        }),
      );
      if (_playlistDialogTrack?.videoId != track.videoId) return;
      if (failed > 0) {
        _playlistDialogError =
            'Some playlists could not be checked; toggling them '
            'may add a duplicate.';
      }
      // Fresh map identities: the dialog selects the
      // membership map, and `select` only rebuilds on a
      // changed (==) value — mutating the old map in place
      // would leave the spinner up forever.
      final membership = <String, bool>{};
      final itemIds = <String, String>{};
      for (final e in results) {
        membership[e.key] = e.value != null;
        if (e.value != null) itemIds[e.key] = e.value!;
      }
      _playlistMembership = membership;
      _playlistItemIds
        ..clear()
        ..addAll(itemIds);
    } finally {
      if (_playlistDialogTrack?.videoId == track.videoId) {
        _playlistDialogLoading = false;
        _safeNotify();
      }
    }
  }

  /// Closes the playlist dialog.
  void closePlaylistDialog() {
    _playlistDialogTrack = null;
    _playlistMembership = {};
    _playlistItemIds.clear();
    _playlistDialogError = null;
    _safeNotify();
  }

  /// Adds/removes the dialog track to/from [playlistId], optimistically.
  Future<void> toggleTrackPlaylist(String playlistId, Track track) async {
    final api = _api;
    final member = _playlistMembership[playlistId] == true;
    try {
      if (member) {
        var itemId = _playlistItemIds[playlistId];
        itemId ??= await api.playlistItemId(playlistId, track.videoId);
        if (itemId == null) return;
        if (!await api.removeFromPlaylist(playlistId, track.videoId, itemId)) {
          _playlistDialogError = 'Could not remove from playlist.';
          _safeNotify();
          return;
        }
        // Copy-on-write (see openPlaylistDialog): the dialog
        // selects this map by identity.
        _playlistMembership = {..._playlistMembership, playlistId: false};
        _playlistItemIds.remove(playlistId);
      } else {
        if (!await api.addToPlaylist(playlistId, track.videoId)) {
          _playlistDialogError = 'Could not add to playlist.';
          _safeNotify();
          return;
        }
        _playlistMembership = {..._playlistMembership, playlistId: true};
      }
      _playlists = _playlists.map((pl) {
        if (pl.id != playlistId) return pl;
        return AccountPlaylist(
          id: pl.id,
          title: pl.title,
          itemCount: (pl.itemCount + (member ? -1 : 1)).clamp(0, 1 << 31),
          art: pl.art,
          arts: pl.arts,
          owner: pl.owner,
          ownerId: pl.ownerId,
        );
      }).toList();
      if (_openPlaylist != null && _openPlaylist!.playlist.id == playlistId) {
        unawaited(openPlaylist(_openPlaylist!.playlist));
      }
    } finally {
      _safeNotify();
    }
  }

  // ---------- Ratings ----------

  bool get ratingsAvailable => _account != null || !_tube.auth.isAnonymous;

  /// Rates the currently playing track. Returns whether either backend
  /// accepted the change.
  Future<bool> rateCurrent(RatingStatus rating) {
    final id = _player.state.current?.videoId;
    if (id == null) return Future.value(false);
    return rateTrack(id, rating);
  }

  /// Rates a track with a SnackBar when both backends refuse, so a dead
  /// like button is diagnosable instead of silently stuck.
  Future<void> rateTrackFeedback(
    BuildContext context,
    String videoId,
    RatingStatus rating,
  ) async {
    final ok = await rateTrack(videoId, rating);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save rating — check connection and sign-in."),
        ),
      );
    }
  }

  /// Rates the current track with failure feedback (see
  /// [rateTrackFeedback]).
  Future<void> rateCurrentFeedback(
    BuildContext context,
    RatingStatus rating,
  ) async {
    final id = _player.state.current?.videoId;
    if (id == null) return;
    await rateTrackFeedback(context, id, rating);
  }

  /// Rates a track via InnerTube, updating player, views and liked
  /// songs. The button flips optimistically and is reverted (with a
  /// failure result) if the backend rejects the change.
  Future<bool> rateTrack(String videoId, RatingStatus rating) async {
    if (rating == RatingStatus.unknown) return false;
    final previous =
        _ratingCache[videoId] ?? _likedRating(videoId) ?? RatingStatus.unknown;
    final wasLiked =
        _likedIds.contains(videoId) || _liked.any((t) => t.videoId == videoId);

    // Optimistic UI: the tapped button responds immediately.
    _applyRating(videoId, rating);
    if (rating == RatingStatus.like) {
      _likedIds.add(videoId);
    } else {
      _likedIds.remove(videoId);
    }
    _safeNotify();

    var innerOk = false;
    try {
      innerOk = await _tube.rate(videoId, rating);
    } catch (_) {}
    debugPrint('[rate] $videoId -> $rating innerTube=$innerOk');
    if (!innerOk) {
      debugPrint('[rate] $videoId FAILED');
      // Revert the optimistic change.
      _applyRating(videoId, previous);
      if (wasLiked) {
        _likedIds.add(videoId);
      } else {
        _likedIds.remove(videoId);
      }
      _safeNotify();
      return false;
    }
    // Backend accepted: maintain the liked list.
    if (rating == RatingStatus.like) {
      final track = _player.state.current?.videoId == videoId
          ? _player.state.current
          : _player.state.queue.where((t) => t.videoId == videoId).firstOrNull;
      if (track != null && !_liked.any((t) => t.videoId == videoId)) {
        _liked = [..._liked, track];
        _updateLikedPlaylistEntry();
      }
    } else {
      _liked = _liked.where((t) => t.videoId != videoId).toList();
      _updateLikedPlaylistEntry();
    }
    return true;
  }

  /// Applies [rating] to the player's track, the rating cache, and every
  /// view (home rows, detail, open playlist), notifying listeners.
  void _applyRating(String videoId, RatingStatus rating) {
    _player.updateTrackRating(videoId, rating);
    _ratingCache[videoId] = rating;
    applyRatingToViews(videoId, rating);
    // Home rows keep their own track copies: restamp them from the cache
    // so the tapped like repaints everywhere, not just detail views.
    _activity = _stampKnownRatings(_activity);
    _discover = _stampKnownRatings(_discover);
    home = home.copyWith(shelves: _stampShelves(home.shelves));
  }

  /// Pushes a new rating into the visible detail and open-playlist track
  /// lists so like buttons update where the user tapped them. Mirrors
  /// Kotlin `applyRatingToViews`.
  void applyRatingToViews(String videoId, RatingStatus rating) {
    Track update(Track t) =>
        t.videoId == videoId ? t.copyWith(rating: rating) : t;
    final stamped = _detailWithRatings(detail, update);
    if (stamped != null) detail = stamped;
    final opened = _openPlaylist;
    if (opened != null) {
      _openPlaylist = OpenPlaylist(
        opened.playlist,
        opened.tracks.map(update).toList(),
      );
    }
    _safeNotify();
  }

  /// Returns [d] with [update] applied to its album/playlist tracks, or
  /// null when it shows neither (artist page).
  DetailUiState? _detailWithRatings(
    DetailUiState d,
    Track Function(Track) update,
  ) {
    if (d.album != null) {
      final album = d.album!;
      return DetailUiState(
        loading: d.loading,
        album: AlbumDetail(
          title: album.title,
          subtitle: album.subtitle,
          description: album.description,
          thumbnails: album.thumbnails,
          tracks: album.tracks.map(update).toList(),
          kind: album.kind,
          year: album.year,
          artist: album.artist,
        ),
        artist: d.artist,
        error: d.error,
      );
    }
    if (d.playlist != null) {
      final pl = d.playlist!;
      return DetailUiState(
        loading: d.loading,
        artist: d.artist,
        playlist: PlaylistDetail(
          title: pl.title,
          subtitle: pl.subtitle,
          thumbnails: pl.thumbnails,
          tracks: pl.tracks.map(update).toList(),
          author: pl.author,
        ),
        error: d.error,
      );
    }
    return null;
  }

  /// Fetches like-state for detail album/playlist tracks and stamps it
  /// into the visible page (guarded by the detail generation). Kotlin
  /// requests detail-track ratings the same way; without this pass liked
  /// songs never highlight on detail pages.
  void _stampDetailRatings(int gen, List<Track> tracks) {
    if (tracks.isEmpty) return;
    unawaited(
      _requestTrackRatings(tracks, (statuses) {
        debugPrint(
          '[rating] detail stamp: ${tracks.length} tracks -> ${statuses.length} known',
        );
        if (statuses.isEmpty || gen != _detailGen) return;
        final stamped = _detailWithRatings(
          detail,
          (t) => statuses[t.videoId] == null
              ? t
              : t.copyWith(rating: statuses[t.videoId]!),
        );
        if (stamped == null) return;
        detail = stamped;
        _safeNotify();
      }),
    );
  }

  /// Batch-resolves like states and track lengths for the Up Next queue
  /// and stamps them into the player state.
  ///
  /// The queue otherwise keeps whatever the row parse carried — unknown
  /// ratings, and no length at all for most sources (home shelves, album
  /// and artist pages never include one in their rows, unlike the queue
  /// panel), so liked songs never highlight and unplayed rows read
  /// without a duration until they play. Both fields come out of the
  /// *same* watch-next read per row the signed-in like-state pass already
  /// made, so lengths ride along for free.
  ///
  /// Local knowledge (rating cache, liked ids/list, learned lengths)
  /// applies instantly with zero network; only ids unknown locally go to
  /// InnerTube, and only ids still queued are applied (stale fetches land
  /// in the caches for later instead of touching a moved-on queue).
  void _stampQueueMetadata() {
    final queue = _player.state.queue;
    if (queue.isEmpty) return;
    final local = <String, RatingStatus>{};
    for (final t in queue) {
      final known = _ratingCache[t.videoId] ?? _likedRating(t.videoId);
      if (known != null && known != t.rating) local[t.videoId] = known;
    }
    if (local.isNotEmpty) _player.updateTrackRatings(local);
    unawaited(_requestQueueMetadata(queue));
  }

  /// Fetches the queue rows unknown locally and stamps what still
  /// applies. The read below exists for like state, which needs a
  /// session; track lengths ride along on the same response, so this pass
  /// runs while signed in and signed-out sessions make no read at all
  /// (their rows fill from each track's stream resolve instead).
  Future<void> _requestQueueMetadata(List<Track> queue) async {
    if (!ratingsAvailable) return;
    final ids = <String>[];
    final seen = <String>{};
    for (final t in queue) {
      final id = t.videoId;
      if (id.isEmpty || !seen.add(id)) continue;
      final needsRating = (_ratingCache[id] ?? _likedRating(id)) == null;
      final needsDuration =
          t.durationSec <= 0 &&
          !_knownDurations.containsKey(id) &&
          !_durationMisses.contains(id);
      if (needsRating || needsDuration) ids.add(id);
    }
    if (ids.isEmpty) return;
    final Map<String, ({RatingStatus rating, Map<String, int> durations})>
    reads;
    try {
      reads = await _tube.watchInfos(ids);
    } catch (_) {
      return;
    }
    for (final e in reads.entries) {
      // The response lists the whole queue, so lengths for rows this pass
      // did not ask about are cached too (album/playlist plays hand over
      // their context in one read).
      _knownDurations.addAll(e.value.durations);
      if (!e.value.durations.containsKey(e.key)) _durationMisses.add(e.key);
      final rating = e.value.rating;
      if (rating != RatingStatus.unknown &&
          _trustNetworkRating(e.key, rating)) {
        _ratingCache[e.key] = rating;
      }
    }
    final live = _player.state.queue.map((t) => t.videoId).toSet();
    final durations = <String, int>{};
    final ratings = <String, RatingStatus>{};
    for (final t in queue) {
      if (!live.contains(t.videoId)) continue;
      final secs = _knownDurations[t.videoId];
      if (secs != null && secs > 0 && t.durationSec <= 0) {
        durations[t.videoId] = secs;
      }
      final known = _ratingCache[t.videoId];
      if (known != null && known != t.rating) ratings[t.videoId] = known;
    }
    if (durations.isNotEmpty) _player.updateTrackDurations(durations);
    if (ratings.isNotEmpty) _player.updateTrackRatings(ratings);
  }

  /// Batch-resolves ratings for [tracks], using the cache first.
  Future<void> _requestTrackRatings(
    List<Track> tracks,
    void Function(Map<String, RatingStatus>) onComplete,
  ) async {
    if (!ratingsAvailable) return;
    final pending = tracks
        .map((t) => t.videoId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final cached = <String, RatingStatus>{};
    final missing = <String>[];
    for (final id in pending) {
      final known = _ratingCache[id] ?? _likedRating(id);
      if (known != null) {
        cached[id] = known;
      } else {
        missing.add(id);
      }
    }
    if (missing.isNotEmpty) {
      try {
        final fetched = await _tube.ratings(missing);
        // Drop logged-out INDIFFERENTs contradicting local LIKE knowledge
        // (also covers likes tapped mid-fetch).
        final trusted = {
          for (final e in fetched.entries)
            if (_trustNetworkRating(e.key, e.value)) e.key: e.value,
        };
        _ratingCache.addAll(trusted);
        cached.addAll(trusted);
      } catch (_) {}
    }
    onComplete(cached);
  }

  RatingStatus? _likedRating(String videoId) =>
      (_likedIds.contains(videoId) || _liked.any((t) => t.videoId == videoId))
      ? RatingStatus.like
      : null;

  /// Whether a network-fetched rating may be applied. Logged-out InnerTube
  /// reads confidently report INDIFFERENT for liked songs; those must
  /// never clobber locally known LIKE state (cache, liked ids/list).
  /// Explicit LIKE/DISLIKE always applies (it requires a real session).
  bool _trustNetworkRating(String videoId, RatingStatus fetched) {
    if (fetched == RatingStatus.like || fetched == RatingStatus.dislike) {
      return true;
    }
    if (fetched != RatingStatus.indifferent) return false;
    final local = _ratingCache[videoId] ?? _likedRating(videoId);
    return local != RatingStatus.like;
  }

  /// Applies locally known like-state (rating cache, then liked ids/list)
  /// onto [t]. Explicit cache entries always win, so unlikes/relikes
  /// repaint correctly even when the track object predates them.
  Track _stampKnownRating(Track t) {
    final known = _ratingCache[t.videoId] ?? _likedRating(t.videoId);
    if (known == null || known == t.rating) return t;
    return t.copyWith(rating: known);
  }

  /// Maps [_stampKnownRating] over a track list.
  List<Track> _stampKnownRatings(List<Track> tracks) =>
      tracks.map(_stampKnownRating).toList();

  /// Maps [_stampKnownRating] over the song items of every home shelf.
  List<Shelf> _stampShelves(List<Shelf> shelves) => [
    for (final s in shelves)
      Shelf(s.title, [
        for (final item in s.items)
          item is SongItem ? SongItem(_stampKnownRating(item.track)) : item,
      ], continuation: s.continuation),
  ];

  List<Track> _stampLikedIds(List<Track> tracks) => _stampKnownRatings(tracks);

  Map<String, List<ShelfItem>> _stampSearchSections(
    Map<String, List<ShelfItem>> sections,
  ) {
    return sections.map(
      (key, items) => MapEntry(
        key,
        items
            .map(
              (item) => item is SongItem
                  ? SongItem(_stampKnownRating(item.track))
                  : item,
            )
            .toList(),
      ),
    );
  }

  /// Refreshes the account liked-ids set and restamps visible surfaces.
  Future<void> refreshLikedIds() async {
    final api = _api;
    try {
      final ids = await api.likedVideoIds();
      _likedIds = ids;
      search = SearchUiState(
        query: search.query,
        sections: _stampSearchSections(search.sections),
      );
      // Liked ids are stamp input for Up Next too: repaint the queue
      // from local knowledge without waiting for a queue change.
      final local = <String, RatingStatus>{};
      for (final t in _player.state.queue) {
        if (_likedIds.contains(t.videoId) && t.rating != RatingStatus.like) {
          local[t.videoId] = RatingStatus.like;
        }
      }
      if (local.isNotEmpty) _player.updateTrackRatings(local);
      _safeNotify();
    } catch (_) {}
  }

  /// Re-resolves the current track's rating when the account changes.
  Future<void> refreshCurrentRating() async {
    final current = _player.state.current;
    if (current == null || !ratingsAvailable) return;
    try {
      final rating = await _tube.rating(current.videoId);
      if (rating != RatingStatus.unknown &&
          _trustNetworkRating(current.videoId, rating)) {
        _player.updateTrackRating(current.videoId, rating);
        _ratingCache[current.videoId] = rating;
      }
    } catch (_) {}
  }

  // ---------- Lyrics / enrichment ----------

  List<LyricLine> _lyrics = [];
  List<LyricLine> get lyrics => _lyrics;

  /// True while the current track's lyrics are being fetched
  /// (network paths only — cache hits set [_lyrics] without
  /// going through a loading state, so they never flash a
  /// skeleton). Drives the shimmering placeholder lines.
  bool _lyricsLoading = false;
  bool get lyricsLoading => _lyricsLoading;

  /// Fences concurrent lyric fetches (track skips, source
  /// switches): only the latest fetch may publish or clear
  /// the loading flag.
  int _lyricsGen = 0;

  /// Selected lyrics provider, persisted. Defaults to LRCLIB.
  LyricsSource get lyricsSource => LyricsSource.fromKey(_config.lyricsSource);

  /// Switches the lyrics provider, refetching the current track from
  /// the newly selected source.
  void setLyricsSource(LyricsSource source) {
    if (lyricsSource == source) return;
    _config.lyricsSource = source.name;
    final track = _player.state.current;
    final key = track?.videoId;
    _lyrics = [];
    _safeNotify();
    if (track != null && key != null && key.isNotEmpty) {
      unawaited(_fetchLyricsFor(key));
    }
  }

  /// Lyrics lines per track and source (`$videoId:${source.name}`),
  /// so switching providers back and forth never refetches.
  final Map<String, List<LyricLine>> _lyricsCache = {};

  /// Loads lyrics for [key] from the selected provider (LRCLIB with
  /// album fill, or plain YTM text), serving the cache first.
  Future<void> _fetchLyricsFor(String key) async {
    final current = _player.state.current;
    if (current == null || current.videoId != key) return;
    final source = lyricsSource;
    final cacheKey = '$key:${source.name}';
    final cached = _lyricsCache[cacheKey];
    if (cached != null) {
      if (_player.state.current?.videoId == key) {
        _lyrics = cached;
        _safeNotify();
      }
      return;
    }
    final gen = ++_lyricsGen;
    _lyricsLoading = true;
    _safeNotify();
    try {
      if (source == LyricsSource.ytmusic) {
        final lines = await fetchYtmLyrics(key);
        if (_player.state.current?.videoId != key || gen != _lyricsGen) return;
        _lyricsCache[cacheKey] = lines;
        _lyrics = lines;
        _safeNotify();
        return;
      }
      try {
        final res = await fetchLyricsAndAlbum(
          current.artistNames(),
          current.title,
          current.album?.name ?? '',
          current.durationSec,
        );
        if (_player.state.current?.videoId != key || gen != _lyricsGen) return;
        _lyricsCache[cacheKey] = res.lines;
        _lyrics = res.lines;
        if (res.album != null && res.album!.isNotEmpty) {
          _player.updateTrackAlbum(key, res.album!);
        }
        if (!_disposed) notifyListeners();
      } catch (_) {}
    } finally {
      if (gen == _lyricsGen && _player.state.current?.videoId == key) {
        _lyricsLoading = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// Cover palette bands for the Now Playing backdrop (Kotlin
  /// `rememberCoverPalette`); empty until the artwork loads.
  List<Color> _coverPalette = [];
  List<Color> get coverPalette => _coverPalette;
  final Map<String, List<Color>> _paletteCache = {};

  String? _lastLyricKey;
  String? _lastRatingVideoId;

  /// Records a played track at the head of recent activity so quick
  /// picks (and jump-back-in) update as you listen instead of only on
  /// library reloads. Local-only and capped; the next server history
  /// fetch replaces it wholesale. No notify here — callers notify.
  void _noteLocalHistory(Track track) {
    if (track.videoId.isEmpty) return;
    if (_activity.isNotEmpty && _activity.first.videoId == track.videoId) {
      return;
    }
    // Every new entry is a listen: quick picks ranks by this.
    _playCounts[track.videoId] = (_playCounts[track.videoId] ?? 0) + 1;
    _savePlayCounts();
    _activity = [
      _stampKnownRating(track),
      for (final t in _activity)
        if (t.videoId != track.videoId) t,
    ].take(50).toList();
    // Persisted too: the next library load merges these ahead of the
    // (lagging) server history instead of dropping just-played songs.
    _localRecents = [
      track,
      for (final t in _localRecents)
        if (t.videoId != track.videoId) t,
    ].take(_localRecentCap).toList();
    _saveLocalRecents();
  }

  void _onPlayerState(PlayerState s) {
    if (_config.reportPlayback) {
      // Fire-and-forget: beacons never touch UI state (see
      // _reportPlaybackProgress), so reporting can't jank playback.
      unawaited(_playback.report(s));
    }
    // New tracks entered Up Next (play, radio mix, autoplay advance):
    // stamp their like states and track lengths. Keyed on ids only so the
    // restamp's own emission doesn't retrigger; progress ticks share the
    // queue, so this is a cheap string join twice a second at most.
    final queueKey = s.queue.map((t) => t.videoId).join(',');
    if (queueKey != _lastQueueKey) {
      _lastQueueKey = queueKey;
      _stampQueueMetadata();
    }
    final track = s.current;
    final key = track?.videoId;
    final prev = _lastNotified;
    _lastNotified = s;
    if (track != null && key != null && key != _lastLyricKey) {
      _lastLyricKey = key;
      _lyrics = [];
      _noteLocalHistory(track);
      _safeNotify();
      unawaited(_resolveCurrentMetadata(track));
      unawaited(ensureSquareCover(key));
      unawaited(_refreshPalette(_playerArtwork(track)));
      return;
    }
    if (track == null || key == null) {
      _safeNotify();
      return;
    }
    // Pure progress ticks (position polling) bump a lightweight notifier
    // that only sliders and time labels listen to, instead of rebuilding
    // the whole tree twice a second.
    if (prev != null && isProgressOnlyUpdate(prev, s)) {
      progressTick.value++;
      return;
    }
    // Volume-only changes (slider drags) get their own tick for the
    // same reason: the volume slider listens to it, nobody else pays.
    if (prev != null && isVolumeOnlyUpdate(prev, s)) {
      volumeTick.value++;
      return;
    }
    _safeNotify();
  }

  /// Bumped on player updates that carry only playback progress. Sliders
  /// and time labels listen to this; everything else uses notifications.
  final ValueNotifier<int> progressTick = ValueNotifier(0);

  /// Bumped on player updates that carry only a volume change. The
  /// volume slider listens to this; volume drags no longer rebuild the
  /// whole app on every throttled step.
  final ValueNotifier<int> volumeTick = ValueNotifier(0);

  /// Effective UI color scheme for non-widget consumers (tray icon),
  /// published by the themed shell next to MaterialApp.
  final ValueNotifier<ColorScheme?> displayScheme = ValueNotifier(null);

  /// Last snapshot seen on the player stream, for progress detection.
  PlayerState? _lastNotified;

  Future<void> _refreshPalette(String? url) async {
    if (url == null || url.isEmpty) {
      _coverPalette = [];
      _safeNotify();
      return;
    }
    final cached = _paletteCache[url];
    if (cached != null) {
      _coverPalette = cached;
      paletteTick.value++;
      _safeNotify();
      return;
    }
    try {
      final image = await _art.image(url);
      if (image == null || _disposed) return;
      final bands = coverBands(image);
      if (bands == null) return;
      final colors = bands
          .map((b) => Color.fromRGBO(b.$1, b.$2, b.$3, 1))
          .toList();
      _paletteCache[url] = colors;
      paletteTick.value++;
      final hold = _paletteHoldUntil;
      if (hold != null && DateTime.now().isBefore(hold)) {
        // Transition running: hold the result instead of rebuilding
        // (and starting the wash animation) mid-slide.
        _pendingPalette = colors;
        return;
      }
      _coverPalette = colors;
      _safeNotify();
    } catch (_) {}
  }

  /// Returns the cached palette for [url], or null if not yet computed.
  /// Call [ensurePalette] first to trigger computation.
  List<Color>? paletteFor(String? url) => _paletteCache[url];

  // ---------- Square cover resolution for lists ----------

  /// Bumped when a square cover is resolved, so artwork widgets that
  /// opted into resolution re-check their video's cached cover.
  final ValueNotifier<int> squareCoverTick = ValueNotifier(0);

  /// Bumped whenever a palette resolves or the cache resets: the
  /// backdrop washes listen to this instead of watching the whole
  /// app state, so ~2 Hz progress notifications never recompute them.
  final ValueNotifier<int> paletteTick = ValueNotifier(0);

  /// Bumped when the on-disk artwork cache is cleared (Settings debug
  /// action), so every visible artwork tile re-downloads/re-renders.
  final ValueNotifier<int> artworkCacheTick = ValueNotifier(0);

  /// Clears the on-disk artwork cache (raw bytes + rendered crops),
  /// the failure skip-lists and banner memo, the in-memory cover
  /// palettes, and Flutter's decoded-image cache, then bumps
  /// [artworkCacheTick] so visible tiles re-fetch, and re-computes the
  /// Now Playing backdrop palette.
  /// Debug-only: Settings → Debug → "Clear artwork cache".
  void clearArtworkCache() {
    _art.clearCache();
    _tube.clearSquareCovers();
    _paletteCache.clear();
    _coverPalette = [];
    paletteTick.value++;
    squareCoverTick.value++;
    // Same-path re-renders must not decode stale pixels from memory.
    PaintingBinding.instance.imageCache.clear();
    artworkCacheTick.value++;
    _safeNotify();
    unawaited(_refreshPalette(_player.state.current?.displayArtwork));
  }

  /// The cached square cover URL for [videoId], or null (disk-backed).
  String? cachedSquareCover(String videoId) => _tube.cachedSquareCover(videoId);

  /// Artwork URL the player UI shows for [track]: the resolved square
  /// cover when cached, else the raw frame. Tiles and palette use the
  /// same URL, so a tap reuses the bytes the list already downloaded
  /// instead of fetching the frame again.
  String? _playerArtwork(Track track) =>
      cachedSquareCover(track.videoId) ?? track.displayArtwork;

  /// Resolves the square cover for [videoId] in the background (coalesced
  /// and disk-cached in `InnerTube`), bumping [squareCoverTick] when it
  /// lands so the artwork can swap the frame for the square cover.
  /// The album id rides along so video-only panels (16:9 frames, no
  /// square art) still resolve through the fetched album page; it is
  /// looked up across the player and the whole library, not just the
  /// queue. Returns when the resolution settles (null when missing)
  /// so tiles can give up to a placeholder instead of shimmering
  /// forever; fire-and-forget callers simply ignore the future.
  Future<void> ensureSquareCover(String videoId) async {
    if (videoId.isEmpty) return;
    if (_tube.cachedSquareCover(videoId) != null) return;
    final albumId = _albumIdFor(videoId);
    try {
      final url = await _tube.squareCoverOf(videoId, albumId: albumId);
      if (url == null || url.isEmpty) return;
      squareCoverTick.value++;
      // The current track's cover just resolved: repaint the backdrop
      // from the same bytes the tile now shows, so the wash matches
      // the displayed cover without a re-download.
      if (_player.state.current?.videoId == videoId) {
        unawaited(_refreshPalette(url));
      }
    } catch (_) {}
  }

  /// Album browse id for [videoId] from the player or any library
  /// list, or null. Square-cover resolution rides it to the fetched
  /// album art when the track's own thumbs have no true square.
  String? _albumIdFor(String videoId) {
    String? linked(String? id) => (id == null || id.isEmpty) ? null : id;
    final current = _player.state.current;
    if (current?.videoId == videoId) {
      final id = linked(current?.album?.browseId);
      if (id != null) return id;
    }
    for (final list in [_player.state.queue, _liked, _activity, _discover]) {
      for (final t in list) {
        if (t.videoId == videoId) {
          final id = linked(t.album?.browseId);
          if (id != null) return id;
        }
      }
    }
    for (final shelf in home.shelves) {
      for (final item in shelf.items) {
        if (item is SongItem && item.track.videoId == videoId) {
          final id = linked(item.track.album?.browseId);
          if (id != null) return id;
        }
      }
    }
    return null;
  }

  /// Computes and caches the cover palette for [url] if not already
  /// present. Used by album/playlist views that need a backdrop wash
  /// independent of the Now Playing cover.
  Future<List<Color>?> ensurePalette(String? url) async {
    if (url == null || url.isEmpty) {
      _safeNotify();
      return null;
    }
    final cached = _paletteCache[url];
    if (cached != null) return cached;
    try {
      final image = await _art.image(url);
      if (image == null) {
        _safeNotify();
        return null;
      }
      final bands = coverBands(image);
      if (bands == null) {
        _safeNotify();
        return null;
      }
      final colors = bands
          .map((b) => Color.fromRGBO(b.$1, b.$2, b.$3, 1))
          .toList();
      _paletteCache[url] = colors;
      paletteTick.value++;
      _safeNotify();
      return colors;
    } catch (_) {
      _safeNotify();
      return null;
    }
  }

  Future<void> _resolveCurrentMetadata(Track track) async {
    final key = track.videoId;
    // Paint locally known like-state first: queue copies from search,
    // radio or shelves often carry unknown ratings for liked songs, and
    // the network read below may fail while the answer is known locally.
    final known = _ratingCache[key] ?? _likedRating(key);
    if (known != null &&
        _player.state.current?.videoId == key &&
        _player.state.current!.rating == RatingStatus.unknown) {
      _player.updateTrackRating(key, known);
    }
    Track enriched = track;
    try {
      enriched = await _tube.enrichTrack(track);
    } catch (_) {}
    if (_player.state.current?.videoId != key) return;
    _player.updateTrackMetadata(
      key,
      artists: enriched.artists,
      album: enriched.album,
      thumbnails: enriched.thumbnails,
      title: enriched.title,
      durationSec: enriched.durationSec,
      explicit: enriched.explicit,
    );
    final current = _player.state.current;
    if (current == null || current.videoId != key) return;
    await _fetchLyricsFor(key);
    if (_lastRatingVideoId != key) {
      _lastRatingVideoId = key;
      if (ratingsAvailable) {
        try {
          final rating = await _tube.rating(key);
          debugPrint('[rating] current $key -> $rating');
          if (rating != RatingStatus.unknown &&
              _trustNetworkRating(key, rating) &&
              _player.state.current?.videoId == key) {
            _player.updateTrackRating(key, rating);
            _ratingCache[key] = rating;
          }
        } catch (_) {}
      }
      // Public like count for the info panel (InnerTube stream responses
      // carry none; the watch-next response does).
      final api = _api;
      if (_player.state.current?.videoId == key) {
        try {
          final likes = await api.videoLikeCount(key);
          if (likes != null &&
              likes >= 0 &&
              _player.state.current?.videoId == key) {
            _player.updateTrackStats(key, likes, -1);
          }
        } catch (_) {}
      }
    }
  }

  // ---------- Auth ----------

  /// Restores the persisted cookie session, if any.
  Future<void> loadAuth() async {
    _loadSearchHistory();
    try {
      // The credentials live in the platform secret store; the legacy
      // plain-text file is migrated (and deleted) on the first run.
      await config.loadCredentials();
      final cookie = config.get('cookie');
      if (cookie.isEmpty) {
        _authLoaded = true;
        _safeNotify();
        return;
      }
      final session = AuthSession.fromCookie(cookie);
      if (session == null) {
        _authLoaded = true;
        _safeNotify();
        return;
      }
      final savedToken = config.get('sessionToken');
      _tube.auth = AuthSession(
        cookie: session.cookie,
        sapisidHash: session.sapisidHash,
        sessionToken: savedToken.isNotEmpty ? savedToken : null,
      );
      _authLoaded = true;
      _safeNotify();
      unawaited(_refreshAccountAfterAuth());
    } catch (_) {
      _authLoaded = true;
      _safeNotify();
    }
  }

  Future<void> _refreshAccountAfterAuth() async {
    try {
      final name = await _tube.accountName();
      _account = name ?? 'YouTube Music account';
    } catch (_) {
      _account = 'YouTube Music account';
    }
    _safeNotify();
    try {
      final token = await _tube.fetchSessionToken();
      if (token != null) {
        final s = _tube.auth;
        _tube.auth = AuthSession(
          cookie: s.cookie,
          sapisidHash: s.sapisidHash,
          accessToken: s.accessToken,
          sessionToken: token,
        );
        await _saveAuth();
      }
    } catch (_) {}
    unawaited(_refreshAvatar());
    // Personal rows + discover need no interaction: refresh like a login
    // (loadLibrary needs the cookie session). The home feed
    // refetches too: startup's loadHome ran before the cookie was
    // restored, so without this it would stay anonymous/generic.
    // History counts seed quick-picks ranking the same way.
    unawaited(loadLibrary());
    unawaited(loadHome());
    unawaited(importHistoryCounts());
    // Surface an expired saved session in the UI right away
    // instead of waiting for the first playback heartbeat.
    unawaited(_playback.refreshLoginValidity());
  }

  Future<void> _saveAuth() async {
    final s = _tube.auth;
    if (s.cookie == null) return;
    await config.setCredential('cookie', s.cookie!);
    if (s.sapisidHash != null) {
      await config.setCredential('sapisidHash', s.sapisidHash!);
    }
    if (s.sessionToken != null) {
      await config.setCredential('sessionToken', s.sessionToken!);
    }
  }

  Future<void> _refreshAvatar() async {
    final gen = ++_avatarGen;
    try {
      final avatar = await _api.accountAvatar();
      if (gen != _avatarGen) return;
      _accountAvatar = avatar;
      _safeNotify();
    } catch (_) {}
  }

  /// Signs in with a pasted browser cookie. Returns true on success.
  Future<bool> login(String cookie) async {
    final problem = validateCookie(cookie);
    if (problem != null) {
      _loginDetail = problem;
      _safeNotify();
      return false;
    }
    _loginBusy = true;
    _loginDetail = null;
    _safeNotify();
    try {
      final session = AuthSession.fromCookie(cookie);
      if (session == null) {
        _loginDetail = 'Could not derive a session from that cookie.';
        return false;
      }
      final previous = _tube.auth;
      _tube.auth = session;
      final ok = await _tube.verifyLogin();
      if (!ok) {
        _tube.auth = previous;
        _loginDetail = 'YouTube rejected that cookie. Copy a fresh Cookie header while logged in.';
        return false;
      }
      // Fresh cookie verified: mark the session valid so the UI
      // reflects it immediately and skips a redundant re-check.
      _playback.loginValid = true;
      _playback.loginCheckedAt = DateTime.now().millisecondsSinceEpoch;
      _account = await _tube.accountName() ?? 'YouTube Music account';
      try {
        final token = await _tube.fetchSessionToken();
        if (token != null) {
          _tube.auth = AuthSession(
            cookie: session.cookie,
            sapisidHash: session.sapisidHash,
            sessionToken: token,
          );
        }
      } catch (_) {}
      await _saveAuth();
      unawaited(_refreshAvatar());
      unawaited(loadLibrary());
      // The cookie unlocks the personalized home feed: refetch it so
      // the anonymous rows from startup are replaced, not kept.
      // History counts seed quick-picks ranking the same way.
      unawaited(loadHome());
      unawaited(importHistoryCounts());
      unawaited(refreshCurrentRating());
      return true;
    } finally {
      _loginBusy = false;
      _safeNotify();
    }
  }

  /// Chromium-family profiles on this device, for the
  /// one-click cookie import (see [loginFromBrowser]).
  List<BrowserProfile> get browserProfiles => BrowserCookies.detectProfiles();

  /// Signs in by importing the YouTube cookie straight from a
  /// browser's own store (headless browser + DevTools protocol,
  /// the same idea as `yt-dlp --cookies-from-browser`), instead
  /// of the user copying a Cookie header out of DevTools.
  ///
  /// [profile] pins one browser/profile; without it the first
  /// detected profile is used. Returns true on success; every
  /// failure degrades to a [loginDetail] hint so the user can
  /// fall back to pasting the cookie manually.
  Future<bool> loginFromBrowser({BrowserProfile? profile}) async {
    final detected = BrowserCookies.detectProfiles();
    final source = profile ?? (detected.isEmpty ? null : detected.first);
    if (source == null) {
      _loginDetail =
          'No Chromium-family browser profile found on '
          'this device.';
      _safeNotify();
      return false;
    }
    _loginBusy = true;
    _loginDetail = null;
    _safeNotify();
    try {
      final header = await BrowserCookies.importYouTubeCookie(source);
      if (header == null || header.isEmpty) {
        _loginDetail =
            'No signed-in YouTube session found in ${source.label}.\n'
            'Log into music.youtube.com in that browser first.';
        return false;
      }
      return await login(header);
    } finally {
      _loginBusy = false;
      _safeNotify();
    }
  }

  /// Signs out everywhere: the session, the account display and the
  /// library rows.
  void logout() {
    _tube.auth = const AuthSession.anonymous();
    _tube.authProvider = null;
    _account = null;
    _accountAvatar = null;
    _clearLibraryLists();
    // Local recents survive sign-out on purpose: they are device-local
    // play history, and the next login's server merge dedups them
    // against fresh history. Clearing them here is what used to wipe
    // just-played songs back to stale server rows on every re-login.
    config.remove('cookie');
    config.remove('sapisidHash');
    config.remove('sessionToken');
    final current = _player.state.current;
    if (current != null) {
      _player.updateTrackRating(current.videoId, RatingStatus.unknown);
    }
    _safeNotify();
  }

  /// Clears library rows and rating state. Shared by the sign-out
  /// paths so a partially-signed-out UI never shows the other
  /// session's leftovers as its own.
  void _clearLibraryLists() {
    _liked = [];
    _likedIds = {};
    _ratingCache.clear();
    _playlists = [];
    _activity = [];
    _discover = [];
    _recentArtists = [];
    _openPlaylist = null;
    // No session left: reset the validity verdict so the UI
    // doesn't keep showing "expired" for a signed-out state.
    _playback.loginValid = true;
    _playback.loginCheckedAt = 0;
  }

  /// Signs out of the InnerTube browser-cookie session: it is the one
  /// session the app has, so the account display and the library rows
  /// are cleared with it.
  void logoutCookie() {
    _tube.auth = const AuthSession.anonymous();
    config.remove('cookie');
    config.remove('sapisidHash');
    config.remove('sessionToken');
    _ratingCache.clear();
    final current = _player.state.current;
    if (current != null) {
      _player.updateTrackRating(current.videoId, RatingStatus.unknown);
    }
    if (!signedIn) {
      _account = null;
      _accountAvatar = null;
      _clearLibraryLists();
    } else {
      // Cookie gone: reset the validity verdict so the card shows
      // "Not connected" instead of a stale "Expired".
      _playback.loginValid = true;
      _playback.loginCheckedAt = 0;
    }
    _safeNotify();
  }

  /// Re-emits state after external config edits (e.g. settings toggles).
  void refreshConfig() => notifyListeners();

  /// Full-screen Now Playing overlay visibility.
  bool _nowOpen = false;
  bool get nowOpen => _nowOpen;

  /// Duration of the overlay slide/fade (mirrored by
  /// `_NowPlayingOverlay`). Palette results landing inside this window
  /// are held until it ends so isolate completions don't rebuild
  /// mid-transition.
  static const nowPlayingTransition = Duration(milliseconds: 250);

  /// The overlay transition duration, collapsed to zero when the
  /// reduced-motion accessibility setting is on, so the Now Playing
  /// slide (and the palette hold that mirrors it) is instant.
  Duration get nowPlayingTransitionDuration =>
      config.reducedMotion ? Duration.zero : nowPlayingTransition;

  /// End of the current transition hold, if any.
  DateTime? _paletteHoldUntil;

  /// The release timer for [openNow]/[closeNow]; cancelled in
  /// [dispose] so no fired timer can notify after the state is gone.
  Timer? _paletteHoldTimer;

  /// Palette computed mid-transition, applied when the hold releases.
  List<Color>? _pendingPalette;

  /// Whether the overlay slide completed. The heavy tab contents stay
  /// out until then so the transition's first frames stay cheap.
  bool _nowReady = false;
  bool get nowReady => _nowReady;

  /// Opens the Now Playing overlay. Tabs stay out until the slide
  /// completes ([nowReady]) to keep the transition cheap.
  void openNow() {
    _nowOpen = true;
    _nowReady = false;
    _holdPaletteForTransition();
    _safeNotify();
  }

  /// Closes the overlay, also exiting full-screen lyrics so the next
  /// open lands on the standard view.
  void closeNow() {
    _nowOpen = false;
    _nowReady = false;
    _lyricsFull = false;
    _holdPaletteForTransition();
    _safeNotify();
  }

  /// Full-screen lyrics mode inside Now Playing: big auto-scrolling
  /// lyrics with the mini player bar at the bottom. Reset on close so
  /// reopening always lands on the standard two-column view.
  bool _lyricsFull = false;
  bool get lyricsFull => _lyricsFull;

  /// Remembered tab index (Up next / Lyrics / Info) for the Now
  /// Playing overlay, so reopening lands on the last tab used.
  int _nowPlayingTabIndex = 0;
  int get nowPlayingTabIndex => _nowPlayingTabIndex;
  set nowPlayingTabIndex(int v) {
    if (v == _nowPlayingTabIndex) return;
    _nowPlayingTabIndex = v;
    _safeNotify();
  }

  /// Enters full-screen lyrics (no-op when already there).
  void expandLyrics() {
    if (_lyricsFull) return;
    _lyricsFull = true;
    _safeNotify();
  }

  /// Leaves full-screen lyrics (no-op when not in it).
  void collapseLyrics() {
    if (!_lyricsFull) return;
    _lyricsFull = false;
    _safeNotify();
  }

  void _holdPaletteForTransition() {
    final transition = nowPlayingTransitionDuration;
    final until = DateTime.now().add(transition);
    _paletteHoldUntil = until;
    _paletteHoldTimer?.cancel();
    _paletteHoldTimer = Timer(
      transition + const Duration(milliseconds: 50),
      () {
        if (_paletteHoldUntil == until) _releasePaletteHold();
      },
    );
  }

  void _releasePaletteHold() {
    _paletteHoldUntil = null;
    var changed = false;
    if (_pendingPalette != null) {
      _coverPalette = _pendingPalette!;
      _pendingPalette = null;
      paletteTick.value++;
      changed = true;
    }
    if (!_nowReady) {
      _nowReady = true;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // ---------- Subscriptions ----------

  final Set<String> _subscribed = {};
  final Set<String> _subscribeBusy = {};

  /// Locally-known subscription state for [channelId]. The set fills
  /// from library loads; toggles update it optimistically.
  bool isSubscribed(String channelId) => _subscribed.contains(channelId);

  /// Resolves and toggles the subscription state for [channelId].
  Future<void> toggleSubscribe(String channelId) async {
    final api = _api;
    if (_subscribeBusy.contains(channelId)) return;
    _subscribeBusy.add(channelId);
    try {
      if (_subscribed.contains(channelId)) {
        if (await api.unsubscribe(channelId)) {
          _subscribed.remove(channelId);
        }
      } else if (await api.subscribe(channelId)) {
        _subscribed.add(channelId);
      }
    } finally {
      _subscribeBusy.remove(channelId);
      _safeNotify();
    }
  }

  /// Resolves a channel avatar URL, caching misses as empty. Used for
  /// creator rows where InnerTube only exposes wide banners.
  ///
  /// Prefers the channel thumbnail (true square avatar) and falls back
  /// to InnerTube artist imagery (square preferred, largest otherwise),
  /// mirroring Kotlin `resolveAuthorAvatar`.
  Future<String?> artistAvatar(String channelId) async {
    if (channelId.isEmpty) return null;
    final cached = _artistAvatarCache[channelId];
    if (cached != null) return cached.isEmpty ? null : cached;
    final api = _api;
    String? url;
    try {
      url = (await api.channelAvatars([channelId]))[channelId];
    } catch (_) {
      url = null;
    }
    if (url == null || url.isEmpty) {
      try {
        final thumbs = (await _tube.artist(channelId))?.thumbnails ?? [];
        final square = thumbs.where((t) => t.isSquare).toList();
        final pool = square.isNotEmpty ? square : thumbs;
        if (pool.isNotEmpty) {
          url = pool.reduce((a, b) => a.width >= b.width ? a : b).url;
        }
      } catch (_) {}
    }
    _artistAvatarCache[channelId] = url ?? '';
    return url;
  }

  /// Whether the InnerTube id is a real artist page (cached), mirroring
  /// Kotlin `isArtistPage`: a full artist response must resolve.
  Future<bool> isArtistPage(String browseId) async {
    if (browseId.isEmpty || !browseId.startsWith('UC')) return false;
    final cached = _artistPageCache[browseId];
    if (cached != null) return cached;
    var ok = false;
    try {
      ok = await _tube.artist(browseId) != null;
    } catch (_) {
      ok = false;
    }
    _artistPageCache[browseId] = ok;
    return ok;
  }

  /// Whether an author row may link out: never yourself, otherwise only
  /// verified artist pages (plain user channels stay inert text).
  Future<bool> isAuthorClickable(String browseId) async {
    if (browseId.isEmpty || !browseId.startsWith('UC')) return false;
    if (!_ownChannelIdLoaded) {
      _ownChannelIdLoaded = true;
      try {
        _ownChannelId = await _api.ownChannelId();
      } catch (_) {
        _ownChannelId = null;
      }
    }
    if (_ownChannelId != null &&
        _ownChannelId!.isNotEmpty &&
        browseId == _ownChannelId) {
      return false;
    }
    return isArtistPage(browseId);
  }

  /// Primes the subscription state for [channelId].
  Future<void> refreshSubscription(String channelId) async {
    final api = _api;
    try {
      if (await api.isSubscribed(channelId)) {
        _subscribed.add(channelId);
      } else {
        _subscribed.remove(channelId);
      }
      _safeNotify();
    } catch (_) {}
  }
}

extension _TakeIfNotEmpty on List<Track> {
  List<Track>? takeIfNotEmpty() => isEmpty ? null : this;
}

/// Maps an arbitrary failure into a short sentence suitable for the
/// home/detail/search error boxes: raw exception text ("Connection
/// reset by peer (errno 104)") is never shown verbatim to the user.
String friendlyError(Object error) {
  if (error is TimeoutException) {
    return 'Timed out — check your connection.';
  }
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return 'Could not reach the network.';
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'The server took too long to respond.';
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        if (code == 401 || code == 403) {
          return 'Sign in again to continue.';
        }
        if (code != null && code >= 500) {
          return 'YouTube Music is having trouble right now.';
        }
        return 'The request was rejected.';
      case DioExceptionType.cancel:
        return 'The request was cancelled.';
      case DioExceptionType.badCertificate:
        return 'The connection could not be secured.';
      case DioExceptionType.unknown:
        break;
      default:
        break;
    }
  }
  final text = '$error'.toLowerCase();
  if (text.contains('socketexception') || text.contains('connection refused')) {
    return 'Could not reach the network.';
  }
  if (text.contains('handshakeexception')) {
    return 'The connection could not be secured.';
  }
  return 'Something went wrong. Try again.';
}
