// Central UI state holder wiring navigation, content, library, ratings
// and playback reporting.
//
// State changes reach the widgets through ChangeNotifier + Provider.
// Async jobs are fenced with generation counters, so a stale load never
// publishes over a newer one.

import 'dart:async';
import 'dart:convert';
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
        ValueNotifier;
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
import '../sys/cache_store.dart';
import '../sys/updater.dart';
import '../sys/sys_config.dart';
import '../sys/log.dart';
import '../core/innertube/stream_resolver.dart';
import 'state/navigation_state.dart'
    show Screen, NavigationState, sameNavigationName;
import 'state/pinned_picks_state.dart' show PinnedPicksState;
import 'state/rating_service.dart' show RatingService;
import 'state/search_state.dart' show SearchState, SearchUiState;
import 'theme.dart' show ThemeSource, resolveColorScheme;

export 'state/navigation_state.dart' show Screen;
export 'state/search_state.dart' show SearchUiState;

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
  OpenPlaylist(
    this.playlist,
    this.tracks, {
    this.subtitle = '',
    this.author,
    this.editable = false,
  });

  AccountPlaylist playlist;
  List<Track> tracks;

  /// Page subtitle as YouTube Music reports it (e.g. "Playlist • 2024").
  final String subtitle;

  /// Creator credit from the playlist page, with its channel link.
  final ArtistRef? author;

  /// Whether the signed-in account can edit this playlist.
  final bool editable;

  OpenPlaylist copyWith({
    AccountPlaylist? playlist,
    List<Track>? tracks,
    String? subtitle,
    ArtistRef? author,
    bool? editable,
  }) {
    return OpenPlaylist(
      playlist ?? this.playlist,
      tracks ?? this.tracks,
      subtitle: subtitle ?? this.subtitle,
      author: author ?? this.author,
      editable: editable ?? this.editable,
    );
  }
}

/// Normalizes a name for navigation matching.
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
const _log = TaggedLog('app');

class AppState extends ChangeNotifier {
  AppState({
    required InnerTube tube,
    required PlayerController player,
    required ArtworkStore art,
    required SysConfig config,
    required Future<void> Function(String url) openUrl,
    StreamResolver? streamResolver,
    Updater? updater,
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
    _streamResolver = streamResolver ?? StreamResolver();
    _updater = updater ?? Updater();
    _rating = RatingService(likesTrack: _isLikedTrack);
    _nav = NavigationState(onLoadDetail: _loadDetail);
    _searchState = SearchState(
      tube: tube,
      stampSections: _stampSearchSections,
      formatError: friendlyError,
      recordEnrichedRating: _recordEnrichedRating,
      onChanged: _safeNotify,
    );
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
    _pins.load();
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
  late final StreamResolver _streamResolver;
  late final Updater _updater;
  late final RatingService _rating;
  late final NavigationState _nav;
  late final SearchState _searchState;

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
  RatingService get rating => _rating;

  /// Set by the startup audio probe when the native backend is
  /// unusable: playback refuses to start and the shell shows why,
  /// instead of a console message and a frozen transport.
  String? _audioBackendError;

  /// Startup update-check state: the newer release (if any), whether a
  /// check is in flight, and whether it has completed.
  UpdateInfo? _updateInfo;
  bool _updateChecking = false;
  bool _updateChecked = false;
  bool _updateApplying = false;
  bool _updateApplied = false;
  bool _updateFailed = false;
  bool _dismissedUpdateBanner = false;
  bool _focusAppUpdates = false;

  /// True when the native audio backend failed the startup probe.
  bool get audioBackendUnavailable => _audioBackendError != null;

  /// A newer release available on GitHub, or null when up to date.
  UpdateInfo? get updateInfo => _updateInfo;

  /// True while the startup update check is in flight.
  bool get updateChecking => _updateChecking;

  /// True when the startup update check has completed (available or not).
  bool get updateChecked => _updateChecked;

  /// True while a downloaded update is being written over the AppImage.
  bool get updateApplying => _updateApplying;

  /// True once the update was installed; it takes effect on the next launch.
  bool get updateApplied => _updateApplied;

  /// True when the install attempt could not replace the AppImage (for
  /// example when running from a plain `flutter run` build).
  bool get updateFailed => _updateFailed;

  /// True when the update banner asked Settings to show the App updates
  /// section; the screen scrolls there and clears the flag.
  bool get focusAppUpdates => _focusAppUpdates;

  /// Whether the user dismissed the update-available banner this session.
  bool get updateBannerDismissed => _dismissedUpdateBanner;

  /// Whether the user dismissed the expired-session banner this session.
  bool get sessionBannerDismissed => _dismissedSessionBanner;
  bool _dismissedSessionBanner = false;

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

  /// Checks GitHub for a newer release once at startup, or again when
  /// [force] is set from the settings card. Best-effort: a failure is
  /// logged and leaves the state up to date.
  Future<void> checkForUpdates({bool force = false}) async {
    if (_updateChecking) return;
    if (_updateChecked && !force) return;
    _updateChecking = true;
    if (force) {
      _updateApplied = false;
      _updateFailed = false;
    }
    _safeNotify();
    UpdateInfo? info;
    try {
      info = await _updater.checkForUpdates();
    } catch (_) {}
    if (_disposed) return;
    _updateInfo = info;
    _updateChecked = true;
    _updateChecking = false;
    _safeNotify();
  }

  /// Applies a downloaded update: replaces the running AppImage
  /// atomically so the new version takes effect on the next launch.
  /// Best-effort and never throws.
  Future<void> applyUpdate() async {
    final info = _updateInfo;
    if (info == null || _updateApplying) return;
    _updateApplying = true;
    _updateFailed = false;
    _safeNotify();
    String? path;
    try {
      path = await _updater.applyUpdate(info);
    } catch (_) {}
    if (_disposed) return;
    _updateApplying = false;
    _updateApplied = path != null;
    _updateFailed = path == null;
    _safeNotify();
  }

  /// Opens Settings with the App updates section in view, reusing the
  /// startup check instead of asking the user to scan again.
  void openAppUpdates() {
    _focusAppUpdates = true;
    go(Screen.settings);
  }

  /// Clears the Settings focus request once the screen scrolled to it.
  void clearAppUpdatesFocus() {
    if (!_focusAppUpdates) return;
    _focusAppUpdates = false;
    _safeNotify();
  }

  /// Dismisses the update-available banner for the rest of this session.
  void dismissUpdateBanner() {
    if (_dismissedUpdateBanner) return;
    _dismissedUpdateBanner = true;
    _safeNotify();
  }

  /// Dismisses the expired-session banner for the rest of this session.
  void dismissSessionBanner() {
    if (_dismissedSessionBanner) return;
    _dismissedSessionBanner = true;
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

  /// The current screen.
  Screen get screen => _nav.screen;

  /// The detail item shown by the detail screen.
  BrowseItem? get detailItem => _nav.detailItem;

  /// Whether the user can navigate back.
  bool get canGoBack => _nav.canGoBack;

  /// Direction of the latest navigation: false only for back pops.
  /// Pushes rise from the bottom, pops sink back down.
  bool get lastNavForward => _nav.lastNavForward;

  /// Navigates forward, pushing the current screen for [goBack].
  /// Detail screens kick off their load on arrival.
  void go(Screen screen, {BrowseItem? detail}) {
    _nav.go(screen, detail: detail);
    _safeNotify();
  }

  /// Returns to the pushed screen, if any. Detail entries reload on
  /// arrival so back navigation never shows a stale page.
  void goBack() {
    if (!_nav.goBack()) return;
    _safeNotify();
  }

  /// Reloads the current detail page in place (used after edits such as
  /// removing a track from an open playlist).
  void reloadDetail() {
    _nav.reloadDetail();
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

  /// The current search results.
  SearchUiState get search => _searchState.search;

  /// The recorded search queries, newest first.
  List<String> get searchHistory => _searchState.searchHistory;

  /// Reads the persisted search history into memory.
  void loadSearchHistory() => _searchState.loadSearchHistory();

  /// Clears the in-memory and the persisted search history.
  void clearSearchHistory() => _searchState.clearSearchHistory();

  /// Deletes the persisted search history file.
  Future<void> deletePersistedSearchHistory() =>
      _searchState.deletePersistedSearchHistory();

  /// Drops one query from the in-memory and the persisted history.
  void removeSearchHistory(String query) =>
      _searchState.removeSearchHistory(query);

  /// Runs a search and enriches the song rows, cancelling older queries.
  Future<void> searchFor(String query) => _searchState.searchFor(query);

  /// Clears the current search results and query.
  void clearSearch() => _searchState.clearSearch();

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
    // Start playback from the preview immediately so the tap is responsive;
    // the full playlist (when available) lands in the background and swaps
    // the queue in without restarting the song.
    playSongs(preview, index);
    try {
      final pid = artist.songsPlaylistId;
      if (pid == null) return;
      final full = (await _tube.playlist(
        pid,
        params: artist.songsPlaylistParams,
      ))?.tracks.takeIfNotEmpty();
      if (full == null) return;
      if (_player.state.current?.videoId != tapped.videoId) return;
      _player.replaceQueue(full, 0);
    } catch (_) {}
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

  /// Starts an artist "Mix" station from the first top song, reporting
  /// whether the mix loaded and whether the user moved on (seed changed)
  /// mid-fetch so the caller can skip the failure snackbar silently.
  Future<({bool loaded, bool movedOn})> startArtistMix(
    ArtistDetail artist,
  ) async {
    if (artist.topSongs.isEmpty) return (loaded: false, movedOn: false);
    final seed = artist.topSongs.first;
    final res = await startArtistRadio(artist);
    final movedOn = _player.state.current?.videoId != seed.videoId;
    return (loaded: res.loaded, movedOn: movedOn);
  }

  /// How many top songs to show in the multi-column grid: up to 5 per
  /// column, across up to 3 columns.
  static const artistTopSongsCap = 15;

  void _loadDetail(BrowseItem item) {
    final gen = ++_detailGen;
    detail = DetailUiState(loading: true);
    _safeNotify();
    unawaited(() async {
      try {
        if (item.browseId.startsWith('UC')) {
          await _loadArtistDetail(item, gen);
        } else if (item.browseId.startsWith('MPRE')) {
          await _loadAlbumDetail(item, gen);
        } else {
          await _loadPlaylistDetail(item, gen);
        }
      } catch (e) {
        if (gen != _detailGen) return;
        detail = DetailUiState(loading: false, error: friendlyError(e));
      }
      _safeNotify();
    }());
  }

  /// Loads an artist detail, enriching its top songs with durations and
  /// views from the songs playlist BEFORE publishing, so the first paint
  /// already shows durations instead of filling them in later. Falls back
  /// to the preview alone on failure.
  Future<void> _loadArtistDetail(BrowseItem item, int gen) async {
    final artist = await _tube.artist(item.browseId);
    if (gen != _detailGen) return;
    ArtistDetail? published = artist;
    if (artist != null && artist.songsPlaylistId != null) {
      try {
        final full = await _tube.playlist(
          artist.songsPlaylistId!,
          params: artist.songsPlaylistParams,
        );
        if (full != null && gen == _detailGen) {
          final merged = _mergePlaylistTracksIntoTopSongs(
            artist.topSongs,
            full.tracks,
          );
          if (merged != artist.topSongs) {
            published = artist.copyWith(topSongs: merged);
          }
        }
      } catch (_) {}
    }
    if (gen != _detailGen) return;
    detail = DetailUiState(loading: false, artist: published);
  }

  /// Merges a songs-playlist track list into the artist's top songs,
  /// backfilling durations/views and appending missing tracks up to the
  /// cap. Returns the merged list, or the original when unchanged.
  List<Track> _mergePlaylistTracksIntoTopSongs(
    List<Track> topSongs,
    List<Track> full,
  ) {
    final merged = List<Track>.of(topSongs);
    var changed = false;
    for (final t in full) {
      final idx = merged.indexWhere((e) => e.videoId == t.videoId);
      if (idx >= 0 && idx < merged.length) {
        final existing = merged[idx];
        if (existing.videoId == t.videoId || existing.title == t.title) {
          final enriched = existing.copyWith(
            durationSec: existing.durationSec > 0
                ? existing.durationSec
                : t.durationSec,
            views: existing.views.trim().isNotEmpty ? existing.views : t.views,
          );
          if (enriched != existing) {
            merged[idx] = enriched;
            changed = true;
          }
        }
      } else if (merged.length < artistTopSongsCap) {
        merged.add(t);
        changed = true;
      }
      if (merged.length >= artistTopSongsCap) break;
    }
    return changed ? merged : topSongs;
  }

  Future<void> _loadAlbumDetail(BrowseItem item, int gen) async {
    final album = await _tube.album(item.browseId);
    if (gen != _detailGen) return;
    detail = DetailUiState(loading: false, album: album);
    if (album != null) _stampDetailRatings(gen, album.tracks);
  }

  Future<void> _loadPlaylistDetail(BrowseItem item, int gen) async {
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
        _openPlaylist = opened.copyWith(
          tracks: _stampLikedIds(List.of(_liked)),
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

  /// User-pinned quick picks, most recent pin last.
  late final PinnedPicksState _pins = PinnedPicksState(
    read: _config.get,
    write: _config.set,
  );

  /// The pinned quick picks, most recent pin last.
  List<ShelfItem> get pinnedPicks => _pins.picks;

  /// True when [item] (by video/browse id) is in the pinned list.
  bool isPinned(ShelfItem item) => _pins.contains(item);

  /// Pins or unpins a quick-pick tile.
  void togglePin(ShelfItem item) {
    _pins.toggle(item);
    _safeNotify();
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
      // Fire-and-forget: covers pop in per chunk without
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
        _liked = _stampKnownRatings(_stampTrackMeta(liked));
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
          _liked = _stampKnownRatings(_stampTrackMeta(full));
          _likedCount = api.likedCount;
          _updateLikedPlaylistEntry();
          _safeNotify();
          // The longer tail can carry fresh placeholder credits.
          unawaited(refreshTrackMeta());
        }
      } catch (_) {}
    }());
  }

  /// Fills missing playlist artwork in background chunks of 4: largest
  /// InnerTube header art first, then the first tracks'
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
          _openPlaylist = opened.copyWith(playlist: r);
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

  /// The raw `PL…` id behind a playlist browse id (`VLPL…`), so the
  /// same playlist resolves identically from every surface.
  static String playlistIdFrom(String browseId) {
    final id = browseId.trim();
    if (id.length > 2 && id.startsWith('VL')) return id.substring(2);
    return id;
  }

  /// Whether the open playlist came from the library tab itself, which
  /// decides whether closing it returns to the library root or pops the
  /// screen the user opened it from.
  bool _openedPlaylistFromLibrary = true;

  /// Opens any playlist from any surface (library, home, search, an
  /// artist page) in the one playlist view, with the same information
  /// regardless of where it was tapped.
  ///
  /// [browseId] may be a raw `PL…` id or a `VL…` browse id; [params]
  /// carries a browse filter (e.g. an artist's top-songs list) and
  /// [item] the title/artwork the caller already has while the page
  /// loads.
  void openPlaylistById(String browseId, {String? params, BrowseItem? item}) {
    final id = playlistIdFrom(browseId);
    final known = _playlists.where((p) => p.id == id).firstOrNull;
    final seed =
        known ??
        AccountPlaylist(
          id: id,
          title: item?.title ?? '',
          itemCount: 0,
          art: item?.displayArtwork,
        );
    _openedPlaylistFromLibrary = screen == Screen.library;
    unawaited(
      _loadOpenPlaylist(
        seed,
        browseId: browseId,
        params: params,
        initialSubtitle: item?.subtitle ?? '',
      ),
    );
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
      if (_openPlaylist?.playlist.id == playlistId) closePlaylist();
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
        _openPlaylist = opened.copyWith(
          playlist: AccountPlaylist(
            id: opened.playlist.id,
            title: opened.playlist.title,
            itemCount: remaining.length,
            art: opened.playlist.art,
            arts: opened.playlist.arts,
            owner: opened.playlist.owner,
            ownerId: opened.playlist.ownerId,
          ),
          tracks: remaining,
        );
        _safeNotify();
      }
    }
    return ok;
  }

  /// Opens [pl], entering its screen immediately while tracks load.
  /// Stale loads (closed or superseded meanwhile) are dropped.
  Future<void> openPlaylist(AccountPlaylist pl) {
    _openedPlaylistFromLibrary = screen == Screen.library;
    return _loadOpenPlaylist(pl, browseId: pl.id);
  }

  /// Shows the playlist view immediately (so the tapped row has
  /// somewhere to land) and then fills it from the canonical playlist
  /// page, whether or not the list belongs to the account.
  Future<void> _loadOpenPlaylist(
    AccountPlaylist seed, {
    required String browseId,
    String? params,
    String initialSubtitle = '',
  }) async {
    final gen = ++_openPlaylistGen;
    final id = seed.id;
    if (id == '__liked') {
      _openLikedPlaylist(seed);
      return;
    }
    final current = _playlists.where((p) => p.id == id).firstOrNull ?? seed;
    _openPlaylist = OpenPlaylist(
      current,
      [],
      subtitle: initialSubtitle,
      editable: _playlists.any((p) => p.id == id),
    );
    _libraryLoading = true;
    _enterPlaylistView();
    try {
      final detail = await _fetchPlaylistDetail(browseId, params);
      final tracks = await _playlistTracks(detail, id);
      if (gen != _openPlaylistGen) return;
      _publishPlaylist(detail, tracks, current, id, initialSubtitle);
      _stampOpenPlaylistRatings(tracks, id, gen);
    } finally {
      // A stale load must not clear the new view's spinner.
      if (gen == _openPlaylistGen) {
        _libraryLoading = false;
        _safeNotify();
      }
    }
  }

  /// Reads the playlist page, tolerating a failed request.
  Future<PlaylistDetail?> _fetchPlaylistDetail(
    String browseId,
    String? params,
  ) async {
    try {
      final pageId = browseId.startsWith('PL') ? 'VL$browseId' : browseId;
      return await _tube.playlist(pageId, params: params);
    } catch (_) {
      return null;
    }
  }

  /// The tracks of the open playlist, enriched and stamped.
  ///
  /// The playlist page carries the rows when it has one; some mixes and
  /// read-only lists only answer through the library row list.
  Future<List<Track>> _playlistTracks(PlaylistDetail? detail, String id) async {
    var tracks = detail?.tracks ?? const <Track>[];
    if (tracks.isEmpty) {
      try {
        tracks = await _api.playlistTracks(id);
      } catch (_) {}
    }
    tracks = await _enrichPlaylistTracks(tracks);
    return _stampLikedIds(tracks);
  }

  /// Resolves the missing credits of [tracks].
  ///
  /// Empty credits and distributor placeholders alike resolve through
  /// InnerTube's watch-next panel.
  Future<List<Track>> _enrichPlaylistTracks(List<Track> tracks) async {
    final sparse = tracks
        .where((t) => t.artists.isEmpty || hasGenericReleaseArtist(t))
        .toList();
    if (sparse.isEmpty) return tracks;
    try {
      final enriched = await _tube.enrichTracks(sparse);
      final byId = {for (final t in enriched) t.videoId: t};
      return _stampKnownRatings(
        tracks.map((t) => byId[t.videoId] ?? t).toList(),
      );
    } catch (_) {
      return tracks;
    }
  }

  /// Publishes the loaded playlist as the open view.
  void _publishPlaylist(
    PlaylistDetail? detail,
    List<Track> tracks,
    AccountPlaylist current,
    String id,
    String initialSubtitle,
  ) {
    final author = detail?.author ?? _libraryOwner(current);
    _openPlaylist = OpenPlaylist(
      AccountPlaylist(
        id: id,
        title: (detail?.title.trim().isNotEmpty ?? false)
            ? detail!.title
            : current.title,
        itemCount: tracks.length,
        art: detail?.displayArtwork ?? current.art,
        arts: current.arts,
        owner: author?.name ?? current.owner,
        ownerId: author?.browseId ?? current.ownerId,
      ),
      tracks,
      subtitle: (detail?.subtitle.trim().isNotEmpty ?? false)
          ? detail!.subtitle
          : initialSubtitle,
      author: author,
      editable: detail?.editable ?? _playlists.any((p) => p.id == id),
    );
  }

  /// The owner of a library list, when it names one.
  ArtistRef? _libraryOwner(AccountPlaylist current) {
    if (current.owner.isEmpty) return null;
    return ArtistRef(
      current.owner,
      browseId: current.ownerId.isEmpty ? null : current.ownerId,
    );
  }

  /// Stamps the resolved ratings into the open playlist.
  void _stampOpenPlaylistRatings(List<Track> tracks, String id, int gen) {
    unawaited(
      _requestTrackRatings(tracks, (statuses) {
        final opened = _openPlaylist;
        if (gen != _openPlaylistGen) return;
        if (opened != null && opened.playlist.id == id) {
          _openPlaylist = opened.copyWith(
            tracks: _applyRatingStatuses(opened.tracks, statuses),
          );
          _safeNotify();
        }
      }),
    );
  }

  /// Opens the liked-songs list, which the library already holds.
  void _openLikedPlaylist(AccountPlaylist seed) {
    _openPlaylist = OpenPlaylist(seed, _stampLikedIds(List.of(_liked)));
    _libraryLoading = false;
    _enterPlaylistView();
    // Panel enrichment (album/explicit/full credits — the library
    // lists send none) refreshes the open view progressively via
    // refreshTrackMeta, which republishes it per chunk.
    unawaited(refreshTrackMeta());
    unawaited(
      _requestTrackRatings(_openPlaylist!.tracks, (statuses) {
        final opened = _openPlaylist;
        if (opened != null && opened.playlist.id == seed.id) {
          _openPlaylist = opened.copyWith(
            tracks: _applyRatingStatuses(opened.tracks, statuses),
          );
          _safeNotify();
        }
      }),
    );
  }

  /// Switches to the one playlist view. The library tab is the host;
  /// opening from anywhere else pushes the origin so Back returns there.
  void _enterPlaylistView() {
    if (screen != Screen.library) {
      go(Screen.library);
    } else {
      _safeNotify();
    }
  }

  /// Closes the open playlist. Returns to the library root when it was
  /// opened there, otherwise pops back to the screen it came from.
  /// Invalidates any in-flight load so it cannot reopen the view.
  void closePlaylist() {
    ++_openPlaylistGen;
    _openPlaylist = null;
    _libraryLoading = false;
    if (!_openedPlaylistFromLibrary && canGoBack) {
      _openedPlaylistFromLibrary = true;
      goBack();
    } else {
      _safeNotify();
    }
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
    final previous = _rating.knownRating(videoId) ?? RatingStatus.unknown;
    final wasLiked = _rating.isLiked(videoId);

    // Optimistic UI: the tapped button responds immediately.
    _applyRating(videoId, rating);
    if (rating == RatingStatus.like) {
      _rating.addLikedId(videoId);
    } else {
      _rating.removeLikedId(videoId);
    }
    _safeNotify();

    var innerOk = false;
    try {
      innerOk = await _tube.rate(videoId, rating);
    } catch (_) {}
    _log.i('[rate] $videoId -> $rating innerTube=$innerOk');
    if (!innerOk) {
      _log.w('[rate] $videoId FAILED');
      // Revert the optimistic change.
      _applyRating(videoId, previous);
      if (wasLiked) {
        _rating.addLikedId(videoId);
      } else {
        _rating.removeLikedId(videoId);
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
    _rating.setCachedRating(videoId, rating);
    applyRatingToViews(videoId, rating);
    // Home rows keep their own track copies: restamp them from the cache
    // so the tapped like repaints everywhere, not just detail views.
    _activity = _stampKnownRatings(_activity);
    _discover = _stampKnownRatings(_discover);
    home = home.copyWith(shelves: _stampShelves(home.shelves));
  }

  /// Pushes a new rating into the visible detail and open-playlist track
  /// lists so like buttons update where the user tapped them.
  void applyRatingToViews(String videoId, RatingStatus rating) {
    Track update(Track t) =>
        t.videoId == videoId ? t.copyWith(rating: rating) : t;
    final stamped = _detailWithRatings(detail, update);
    if (stamped != null) detail = stamped;
    final opened = _openPlaylist;
    if (opened != null) {
      _openPlaylist = opened.copyWith(
        tracks: opened.tracks.map(update).toList(),
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
          id: pl.id,
          editable: pl.editable,
        ),
        error: d.error,
      );
    }
    return null;
  }

  /// Fetches like-state for detail album/playlist tracks and stamps it
  /// into the visible page (guarded by the detail generation). Without
  /// this pass liked
  /// songs never highlight on detail pages.
  void _stampDetailRatings(int gen, List<Track> tracks) {
    if (tracks.isEmpty) return;
    unawaited(
      _requestTrackRatings(tracks, (statuses) {
        _log.d(
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
      final known = _rating.knownRating(t.videoId);
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
      final needsRating = _rating.knownRating(id) == null;
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
        _rating.setCachedRating(e.key, rating);
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
      final known = _rating.cachedRating(t.videoId);
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
      final known = _rating.knownRating(id);
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
        _rating.setCachedRatings(trusted);
        cached.addAll(trusted);
      } catch (_) {}
    }
    onComplete(cached);
  }

  /// Applies the resolved [statuses] to [tracks], leaving the tracks
  /// without a known status untouched.
  List<Track> _applyRatingStatuses(
    List<Track> tracks,
    Map<String, RatingStatus> statuses,
  ) {
    return tracks
        .map(
          (track) => statuses[track.videoId] == null
              ? track
              : track.copyWith(rating: statuses[track.videoId]!),
        )
        .toList();
  }

  /// Public like-state check used by row buttons so they reflect
  /// locally known likes even when the track object's rating is stale.
  bool isLiked(String videoId) => _rating.isLiked(videoId);

  /// Whether [videoId] belongs to the signed-in liked tracks.
  bool _isLikedTrack(String videoId) => _liked.any((t) => t.videoId == videoId);

  /// Whether a network-fetched rating may be applied. Logged-out InnerTube
  /// reads confidently report INDIFFERENT for liked songs; those must
  /// never clobber locally known LIKE state (cache, liked ids/list).
  /// Explicit LIKE/DISLIKE always applies (it requires a real session).
  bool _trustNetworkRating(String videoId, RatingStatus fetched) =>
      _rating.trustNetworkRating(videoId, fetched);

  /// Applies locally known like-state (rating cache, then liked ids/list)
  /// onto [t]. Explicit cache entries always win, so unlikes/relikes
  /// repaint correctly even when the track object's rating is stale.
  Track _stampKnownRating(Track t) => _rating.stampKnownRating(t);

  /// Maps [_stampKnownRating] over a track list.
  List<Track> _stampKnownRatings(List<Track> tracks) =>
      _rating.stampKnownRatings(tracks);

  /// Maps [_stampKnownRating] over the song items of every home shelf.
  List<Shelf> _stampShelves(List<Shelf> shelves) =>
      _rating.stampShelves(shelves);

  List<Track> _stampLikedIds(List<Track> tracks) =>
      _rating.stampKnownRatings(tracks);

  Map<String, List<ShelfItem>> _stampSearchSections(
    Map<String, List<ShelfItem>> sections,
  ) => _rating.stampSearchSections(sections);

  /// Records the rating carried by a freshly resolved track, when the
  /// network rating may be trusted over the locally known state.
  void _recordEnrichedRating(Track track) {
    if (track.rating == RatingStatus.unknown) return;
    if (!_rating.trustNetworkRating(track.videoId, track.rating)) return;
    _rating.setCachedRating(track.videoId, track.rating);
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
        _rating.setCachedRating(current.videoId, rating);
      }
    } catch (_) {}
  }

  // ---------- Lyrics / enrichment ----------

  // YTM play counts: queue and playlist rows carry no views string, so
  // they are fetched lazily from the player endpoint and cached per
  // session (keyed by videoId). Failures stay uncached and refetch.
  final Map<String, int> _ytmPlays = <String, int>{};
  final Map<String, Future<int>> _ytmPlayJobs = <String, Future<int>>{};

  /// Cached YTM play count for [videoId], or null when not fetched yet.
  int? ytmPlayCount(String videoId) => _ytmPlays[videoId];

  /// Fetches (and caches) YTM's canonical play count for a track.
  Future<int> fetchYtmPlayCount(String videoId) {
    if (videoId.trim().isEmpty) return Future.value(0);
    final cached = _ytmPlays[videoId];
    if (cached != null) return Future.value(cached);
    final inflight = _ytmPlayJobs[videoId];
    if (inflight != null) return inflight;
    final job = _fetchYtmPlayCount(videoId);
    _ytmPlayJobs[videoId] = job;
    return job;
  }

  Future<int> _fetchYtmPlayCount(String videoId) async {
    try {
      final n = await _tube.viewCount(videoId);
      if (n > 0) {
        _ytmPlays[videoId] = n;
        _safeNotify();
      }
      return n;
    } catch (_) {
      return 0;
    } finally {
      // Fire-and-forget removal; the dropped future is marked handled so
      // it can't settle with an unwatched error.
      _ytmPlayJobs.remove(videoId)?.ignore();
    }
  }

  List<LyricLine> _lyrics = [];
  List<LyricLine> get lyrics => _lyrics;

  /// True while the current track's lyrics are being fetched
  /// (network paths only — cache hits set [_lyrics] without
  /// going through a loading state, so they never flash a
  /// skeleton). Drives the shimmering placeholder lines.
  bool _lyricsLoading = false;
  bool get lyricsLoading => _lyricsLoading;

  /// True when the last lyrics fetch failed (network/parse error)
  /// rather than legitimately finding none. Drives the retry affordance.
  bool _lyricsError = false;
  bool get lyricsError => _lyricsError;

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
    if (track != null && key != null && key.isNotEmpty) {
      final cached = _lyricsCache['$key:${source.name}'];
      if (cached != null) {
        final otherKey =
            '$key:${source == LyricsSource.lrclib ? 'ytmusic' : 'lrclib'}';
        final other = _lyricsCache[otherKey];
        _lyrics = cached.isNotEmpty ? cached : (other ?? cached);
        _safeNotify();
        // Ensure the other provider is cached too, in the background.
        unawaited(_fetchLyricsFor(key));
        return;
      }
    }
    _lyrics = [];
    _safeNotify();
    if (track != null && key != null && key.isNotEmpty) {
      unawaited(_fetchLyricsFor(key));
    }
  }

  /// Lyrics lines per track and source (`$videoId:${source.name}`),
  /// so switching providers back and forth never refetches. Evicts the
  /// oldest entries past [lyricsCacheCap] so a long queue can't grow
  /// the map without bound.
  final Map<String, List<LyricLine>> _lyricsCache = {};

  /// Upper bound on the per-provider lyric cache.
  static const lyricsCacheCap = 96;

  /// Stores a provider's result under [cacheKey], evicting the oldest
  /// entry when the cap is reached. Reinserting on read keeps hot
  /// tracks (the ones being revisited) fresh.
  void _cacheLyrics(String cacheKey, List<LyricLine> lines) {
    if (_lyricsCache.length >= lyricsCacheCap &&
        !_lyricsCache.containsKey(cacheKey)) {
      _lyricsCache.remove(_lyricsCache.keys.first);
    }
    _lyricsCache[cacheKey] = lines;
  }

  /// Loads lyrics for [key] from the selected provider (LRCLIB with
  /// album fill, or plain YTM text), serving the cache first.
  Future<void> _fetchLyricsFor(String key) async {
    final current = _player.state.current;
    if (current == null || current.videoId != key) return;

    final selected = lyricsSource;
    final lrclibKey = '$key:lrclib';
    final ytmKey = '$key:ytmusic';
    final cachedLrclib = _lyricsCache[lrclibKey];
    final cachedYtm = _lyricsCache[ytmKey];

    // Both providers already cached: switching the toggle is instant.
    if (cachedLrclib != null && cachedYtm != null) {
      if (_player.state.current?.videoId == key) {
        _applyLyrics(
          selected == LyricsSource.lrclib
              ? (cachedLrclib.isNotEmpty ? cachedLrclib : cachedYtm)
              : (cachedYtm.isNotEmpty ? cachedYtm : cachedLrclib),
        );
      }
      return;
    }

    final gen = ++_lyricsGen;
    _lyricsLoading = true;
    _lyricsError = false;
    _safeNotify();
    try {
      final fetched = await _fetchLyricsProviders(
        current,
        cachedLrclib,
        cachedYtm,
        lrclibKey,
        ytmKey,
      );
      if (_player.state.current?.videoId != key || gen != _lyricsGen) return;

      if (cachedLrclib == null) _cacheLyrics(lrclibKey, fetched.lrclibLines);
      if (cachedYtm == null) _cacheLyrics(ytmKey, fetched.ytmLines);
      if (fetched.album != null && fetched.album!.isNotEmpty) {
        _player.updateTrackAlbum(key, fetched.album!);
      }
      final chosen = selected == LyricsSource.lrclib
          ? fetched.lrclibLines
          : fetched.ytmLines;
      final fallback = selected == LyricsSource.lrclib
          ? fetched.ytmLines
          : fetched.lrclibLines;
      _applyLyrics(chosen.isNotEmpty ? chosen : fallback);
    } catch (_) {
      _lyricsError = true;
      if (!_disposed) notifyListeners();
    } finally {
      // Only the latest fetch generation owns the loading flag; an
      // abandoned earlier fetch (skip, provider switch) never clears it.
      if (gen == _lyricsGen) {
        _lyricsLoading = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// Fetches the missing lyric providers for [current], returning cached
  /// values for any provider already in [cachedLrclib]/[cachedYtm].
  /// Both providers run in parallel so a later toggle never waits on the
  /// network. Failures degrade to empty/unknown.
  Future<
    ({List<LyricLine> lrclibLines, List<LyricLine> ytmLines, String? album})
  >
  _fetchLyricsProviders(
    Track current,
    List<LyricLine>? cachedLrclib,
    List<LyricLine>? cachedYtm,
    String lrclibKey,
    String ytmKey,
  ) async {
    Future<List<LyricLine>> lrclibFuture;
    Future<String?> albumFuture;
    if (cachedLrclib != null) {
      lrclibFuture = Future.value(cachedLrclib);
      albumFuture = Future.value(null);
    } else {
      final pending = fetchLyricsAndAlbum(
        current.artistNames(),
        current.title,
        current.album?.name ?? '',
        current.durationSec,
      );
      lrclibFuture = pending
          .then((r) => r.lines)
          .catchError((_) => <LyricLine>[]);
      albumFuture = pending.then((r) => r.album).catchError((_) => null);
    }
    final ytmFuture = cachedYtm != null
        ? Future.value(cachedYtm)
        : fetchYtmLyrics(current.videoId).catchError((_) => <LyricLine>[]);

    final results = await Future.wait<Object?>([
      lrclibFuture.then<Object?>((r) => r),
      albumFuture.then<Object?>((r) => r),
      ytmFuture.then<Object?>((r) => r),
    ]);
    return (
      lrclibLines: results[0] is List<LyricLine>
          ? results[0] as List<LyricLine>
          : <LyricLine>[],
      ytmLines: results[2] is List<LyricLine>
          ? results[2] as List<LyricLine>
          : <LyricLine>[],
      album: results[1] as String?,
    );
  }

  /// Applies [lines] as the current lyrics, with cache/error/loading state.
  void _applyLyrics(List<LyricLine> lines) {
    _lyrics = lines;
    _lyricsError = false;
    _lyricsLoading = false;
    _safeNotify();
  }

  /// Retries the current track's lyrics fetch after a failure.
  void retryLyrics() {
    final key = _player.state.current?.videoId;
    if (key != null && key.isNotEmpty) {
      unawaited(_fetchLyricsFor(key));
    }
  }

  /// Cover palette bands for the Now Playing backdrop; empty until the
  /// artwork loads.
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
    // Prefetch lyrics in parallel with the (slow) metadata enrichment so
    // the Lyrics tab is never waiting behind enrichTrack, and the result
    // is cached for instant re-serving on a later revisit.
    unawaited(_fetchLyricsFor(key));
    // Paint locally known like-state first: queue copies from search,
    // radio or shelves often carry unknown ratings for liked songs, and
    // the network read below may fail while the answer is known locally.
    final known = _rating.knownRating(key);
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
    _safeNotify();
    if (_lastRatingVideoId != key) {
      _lastRatingVideoId = key;
      if (ratingsAvailable) {
        try {
          final rating = await _tube.rating(key);
          _log.d('[rating] current $key -> $rating');
          if (rating != RatingStatus.unknown &&
              _trustNetworkRating(key, rating) &&
              _player.state.current?.videoId == key) {
            _player.updateTrackRating(key, rating);
            _rating.setCachedRating(key, rating);
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
    loadSearchHistory();
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
      final s = session;
      _tube.auth = AuthSession(
        cookie: s.cookie,
        sapisidHash: s.sapisidHash,
        accessToken: s.accessToken,
        sessionToken: savedToken.isNotEmpty ? savedToken : null,
      );
      _streamResolver.cookie = _tube.auth.cookie;
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
          final s = session;
          _tube.auth = AuthSession(
            cookie: s.cookie,
            sapisidHash: s.sapisidHash,
            accessToken: s.accessToken,
            sessionToken: token,
          );
        }
      } catch (_) {}
      await _saveAuth();
      _streamResolver.cookie = _tube.auth.cookie;
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

  /// Signs out everywhere: the session, the account display and the
  /// library rows.
  void logout() {
    _tube.auth = const AuthSession.anonymous();
    _tube.authProvider = null;
    _streamResolver.cookie = null;
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
    _rating.setLikedIds({});
    _rating.clearCachedRatings();
    _playlists = [];
    _activity = [];
    _discover = [];
    _recentArtists = [];
    ++_openPlaylistGen;
    _openPlaylist = null;
    _openedPlaylistFromLibrary = true;
    _libraryLoading = false;
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
    _streamResolver.cookie = null;
    config.remove('sessionToken');
    _rating.clearCachedRatings();
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
  /// to InnerTube artist imagery (square preferred, largest otherwise).
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

  /// Whether the InnerTube id is a real artist page (cached): a full
  /// artist response must resolve.
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
