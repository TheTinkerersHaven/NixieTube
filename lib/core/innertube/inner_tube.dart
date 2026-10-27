// Minimal YouTube Music InnerTube client over the public WEB_REMIX client,
// ported from Kotlin `InnerTube`.
//
// Anonymous by default; [AuthSession] headers (cookie + `SAPISIDHASH`)
// unlock library, likes and playlists, with an async [authProvider] hook
// (a token refresh) consulted before every request.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileMode;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/models.dart';
import '../../sys/http_client.dart';
import '../../sys/paths.dart';
import 'auth_session.dart';
import 'json.dart';
import 'metadata.dart';
import 'parse.dart';

const _base = 'https://music.youtube.com/youtubei/v1';
const _origin = 'https://music.youtube.com';
const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';

/// API key bundled with the WEB_REMIX client shape (sent on no request;
//  kept for beacon URL parity).
const innertubeApiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

/// Per-playback watchtime contexts kept (one entry per track playback).
const _watchtimeContextCacheSize = 16;

/// First rtn counter per playback; rti chains the previous value.
const _watchtimeInitialRtn = 28;

/// rtn increment between watchtime heartbeats of one playback.
const _watchtimeRtnStep = 10;

/// Client ID the real YTM web client uses in stats beacon URLs.
const _beaconClientId = '985604239';

/// Browser UA for stats beacons, matching the captured web client.
const _beaconUa =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36';

/// Browser version label for the cbrver beacon param.
const _beaconCbrVer = '153.0.0.0';

/// Fixed plausible offset between cmt and the rt beacon param.
const _beaconRtOffsetSec = 25.529;

/// Per-playback watchtime session tokens from the InnerTube player
/// response.
///
/// `ei`/`plid`/`of`/`vm` are minted fresh for EVERY player call, so they
/// must be fetched once per track playback (keyed by cpn) and reused for
/// that track's heartbeats, never shared across plays. Verified against
/// the real YTM web client: beacons built from these tokens land in
/// `FEmusic_history`; hand-built URLs without them 204 but never record.
class WatchtimeContext {
  const WatchtimeContext({
    required this.ei,
    required this.plid,
    required this.of,
    required this.vm,
    required this.lenSec,
    this.ptrackingUrl,
  });

  /// Session event id from the playbackTracking base URL.
  final String ei;

  /// Session playlist id from the playbackTracking base URL.
  final String plid;

  /// Opaque session token from the playbackTracking base URL.
  final String of;

  /// Opaque session token from the playbackTracking base URL.
  final String vm;

  /// Track length in seconds from videoDetails.
  final double lenSec;

  /// ptracking base URL, fired once per playback.
  final String? ptrackingUrl;
}

/// Thrown when a cover lookup could not reach a verdict (transport
/// failure, throttling, error body) — distinct from a lookup that
/// answered "no square art exists for this video".
class _CoverLookupUnavailable implements Exception {
  const _CoverLookupUnavailable();
}

/// InnerTube client: anonymous by default, authenticated via [AuthSession].
class InnerTube {
  InnerTube({
    this.auth = const AuthSession.anonymous(),
    Dio? dio,
    String? squareCoversPath,
  }) : _dio =
           dio ??
           newResilientClient(
             // Cover lookups already retry at the call level (and a
             // burst of tiles resolves at once), so keep the wire
             // budget small here: the layers must not multiply into a
             // storm when the backend is throttling.
             policy: const RetryPolicy(
               maxAttempts: 3,
               maxDelay: Duration(seconds: 5),
             ),
           ),
       _squareCoversFile = squareCoversPath == null
           ? null
           : File(squareCoversPath);

  /// Current auth session used (with fallbacks) for requests.
  AuthSession auth;

  /// Optional hook consulted before every request (e.g. a token refresh).
  Future<AuthSession?> Function()? authProvider;

  final Dio _dio;

  /// Release native resources.
  void close() {
    _dio.close();
    _requestCache.clear();
    // Settle pending cover retries now: their timers must not outlive
    // the client, and their late answers belong to nobody.
    _coverRetryGen++;
    for (final entry in _coverRetryWaits.entries) {
      entry.key.cancel();
      if (!entry.value.isCompleted) entry.value.complete();
    }
    _coverRetryWaits.clear();
    unawaited(flushSquareCovers());
  }

  /// Album details fetched during track enrichment.
  final Map<String, AlbumDetail> _albumDetailsCache = {};

  // ---------- Square cover resolution (disk-backed) ----------

  /// videoId → resolved square cover URL, persisted to
  /// `<cache>/square-covers.json` so lists can show the same square album
  /// art the player does without re-fetching on every launch.
  final Map<String, String> _squareCovers = {};
  final Map<String, Future<String?>> _squareCoverInflight = {};
  final Set<String> _squareCoverMissing = {};

  /// Missing-cover key: the video plus its known album (empty when
  /// unknown), so gaining an album id retries a track condemned
  /// without one.
  static String _missingKey(String videoId, String? albumId) =>
      '$videoId|${(albumId != null && albumId.isNotEmpty) ? albumId : ''}';
  File? _squareCoversFile;
  Timer? _squareCoverSaveTimer;
  bool _squareCoversLoaded = false;

  /// Album pages fetched for cover resolution, memoized by album id:
  /// lists routinely hold a dozen tracks off one album, and without
  /// this every tile would re-browse the same page while scrolling.
  final Map<String, AlbumDetail> _coverAlbums = {};

  /// Album page for cover resolution, memoized (failures re-fetch).
  Future<AlbumDetail?> _albumForCover(String albumId) async {
    final hit = _coverAlbums[albumId];
    if (hit != null) return hit;
    final detail = await album(albumId);
    if (detail != null) _coverAlbums[albumId] = detail;
    return detail;
  }

  /// Cap on concurrent square-cover resolutions: a list can surface many
  /// frame-only tracks at once, and this keeps the burst polite while
  /// still draining fast scrolls (matches the enrich batch width).
  static const _maxSquareCoverInflight = 8;
  int _squareCoverActive = 0;
  Completer<void>? _squareCoverSlot;

  void _loadSquareCovers() {
    if (_squareCoversLoaded) return;
    _squareCoversLoaded = true;
    _squareCoversFile ??= File('${cacheDir().path}/square-covers.json');
    try {
      if (_squareCoversFile!.existsSync()) {
        final data = jsonDecode(_squareCoversFile!.readAsStringSync());
        if (data is Map) {
          data.forEach((k, v) {
            if (k is String && v is String && v.isNotEmpty) {
              _squareCovers[k] = v;
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _writeSquareCovers() async {
    final f = _squareCoversFile;
    if (f == null) return;
    try {
      final tmp = '${f.path}.tmp';
      await File(tmp).writeAsString(jsonEncode(_squareCovers), flush: true);
      await File(tmp).rename(f.path);
    } catch (_) {}
  }

  /// Debounced disk write so bursts of resolutions coalesce into one save.
  void _scheduleSquareCoverSave() {
    _squareCoverSaveTimer ??= Timer(const Duration(seconds: 2), () {
      _squareCoverSaveTimer = null;
      unawaited(_writeSquareCovers());
    });
  }

  /// Flushes the square-cover cache to disk immediately (used on quit and
  /// in tests instead of waiting for the debounce).
  Future<void> flushSquareCovers() async {
    _squareCoverSaveTimer?.cancel();
    _squareCoverSaveTimer = null;
    await _writeSquareCovers();
  }

  /// Drops every remembered square cover (memory + disk) so they
  /// re-resolve on the next display. Used by "Clear artwork cache".
  void clearSquareCovers() {
    _squareCoverSaveTimer?.cancel();
    _squareCoverSaveTimer = null;
    _squareCovers.clear();
    _squareCoversLoaded = true;
    try {
      final f = _squareCoversFile;
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Remembers a resolved square cover for [videoId] (memory + disk).
  void noteSquareCover(String videoId, String url) {
    if (videoId.isEmpty || url.isEmpty) return;
    _loadSquareCovers();
    if (_squareCovers[videoId] == url) return;
    _squareCovers[videoId] = url;
    _scheduleSquareCoverSave();
  }

  /// Synchronous lookup of a previously-resolved square cover, or null.
  String? cachedSquareCover(String videoId) {
    _loadSquareCovers();
    return _squareCovers[videoId];
  }

  /// Resolves and caches the square cover for [videoId] (one album
  /// call on miss when the album id is known, else one `next` call),
  /// coalescing concurrent lookups and bounding concurrency.
  /// Tracks with no square cover are remembered per (video, album)
  /// so a retry with a newly known album id re-attempts, while
  /// identical repeats never refetch.
  Future<String?> squareCoverOf(String videoId, {String? albumId}) async {
    _loadSquareCovers();
    final cached = _squareCovers[videoId];
    if (cached != null) return cached;
    final missingKey = _missingKey(videoId, albumId);
    if (_squareCoverMissing.contains(missingKey)) return null;
    final inflight = _squareCoverInflight[videoId];
    if (inflight != null) return inflight;
    final future = _resolveSquareCoverBounded(videoId, albumId: albumId);
    _squareCoverInflight[videoId] = future;
    try {
      final url = await future;
      if (url != null && url.isNotEmpty) {
        noteSquareCover(videoId, url);
      } else {
        _squareCoverMissing.add(missingKey);
      }
      return url;
    } on _CoverLookupUnavailable {
      // The lookup itself failed, so nothing can be concluded about
      // this track's art: it is deliberately not remembered as
      // missing, and the next tile to ask tries again.
      return null;
    } finally {
      unawaited(_squareCoverInflight.remove(videoId));
    }
  }

  Future<String?> _resolveSquareCoverBounded(
    String videoId, {
    String? albumId,
  }) async {
    while (_squareCoverActive >= _maxSquareCoverInflight) {
      _squareCoverSlot ??= Completer<void>();
      await _squareCoverSlot!.future;
    }
    _squareCoverActive++;
    try {
      return await _resolveSquareCover(videoId, albumId: albumId);
    } finally {
      _squareCoverActive--;
      final slot = _squareCoverSlot;
      _squareCoverSlot = null;
      slot?.complete();
    }
  }

  /// Resolves the square cover for [videoId] from the watch-next
  /// panel's own row: for songs its last thumbnail is the square
  /// hi-res art, taken as-is — no ranking, no detour. Taken only
  /// when square (explicit dimensions or the `=w-h` URL shape):
  /// music-video rows end in a 16:9 still, which falls through to
  /// the fetched album art, then to missing. Only the row's own art
  /// ever counts — the first panel track carrying square art is
  /// often a *different* song, and stamping that as this video's
  /// cover would be wrong, not just letterboxed. A lookup that never
  /// answered (throttled, timed out, error body) throws instead of
  /// answering, so one hiccup cannot condemn the track for the
  /// session; only a real panel that carries no square art does.
  Future<String?> _resolveSquareCover(String videoId, {String? albumId}) async {
    final res = await _fetchWithRetry(() => _nextResponse(videoId));
    if (res == null || _isErrorResponse(res)) {
      throw const _CoverLookupUnavailable();
    }
    final url = _ownRowLastThumb(res, videoId);
    if (url != null) return url;
    if (albumId != null && albumId.isNotEmpty) {
      final detail = await _fetchWithRetry(() => _albumForCover(albumId));
      if (detail != null) {
        final url = _largestSquareThumb(detail.thumbnails);
        if (url != null) return url;
      }
    }
    return null;
  }

  /// Last thumbnail of the watch-next row for [videoId], or null
  /// unless it is square. Reads the raw response (not the merged
  /// track thumbs) so the pick is exactly the row's final entry.
  static String? _ownRowLastThumb(dynamic res, String videoId) {
    final contents = nav(res, const [
      'contents',
      'singleColumnMusicWatchNextResultsRenderer',
      'tabbedRenderer',
      'watchNextTabbedResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'musicQueueRenderer',
      'content',
      'playlistPanelRenderer',
      'contents',
    ]);
    if (contents is! List) return null;
    for (final entry in contents) {
      final row = nav(entry, const ['playlistPanelVideoRenderer']);
      if (row is! Map) continue;
      final id = str(
        nav(row, const ['navigationEndpoint', 'watchEndpoint', 'videoId']),
      );
      if (id != videoId) continue;
      final thumbs = nav(row, const ['thumbnail', 'thumbnails']);
      if (thumbs is! List || thumbs.isEmpty) return null;
      final last = thumbs.last;
      if (last is! Map) return null;
      final url = str(last['url']);
      if (url == null || url.isEmpty) return null;
      final thumb = Thumbnail(
        url,
        width: (last['width'] as num?)?.toInt() ?? 0,
        height: (last['height'] as num?)?.toInt() ?? 0,
      );
      return thumb.isSquare ? url : null;
    }
    return null;
  }

  /// Pending cover-fetch backoff waits, cancelled on [close] so no
  /// timer outlives the client (widget tests fail on stray timers).
  final Map<Timer, Completer<void>> _coverRetryWaits = {};

  /// Cover-fetch retry generation, bumped on [close]: a superseded
  /// waiter returns null instead of resolving into a dead client.
  int _coverRetryGen = 0;

  /// Runs [fetch] until it answers (error bodies and empty parses
  /// count as answers), retrying transport throws with backoff.
  /// Only timeouts and Dio transport failures retry: parse-level
  /// throws are deterministic, and retrying them would just burn
  /// timers (which also keeps widget tests clean — no stray waits).
  Future<T?> _fetchWithRetry<T>(Future<T?> Function() fetch) async {
    const delays = [Duration(milliseconds: 300), Duration(milliseconds: 700)];
    final gen = _coverRetryGen;
    for (var attempt = 0; ; attempt++) {
      try {
        return await fetch();
      } catch (e) {
        if (!_isRetryableCoverError(e)) return null;
        if (attempt >= delays.length) return null;
        await _coverRetryDelay(delays[attempt]);
        if (gen != _coverRetryGen) return null;
      }
    }
  }

  /// Transport blips worth another attempt: timeouts and Dio
  /// connection-level failures. HTTP error statuses never throw
  /// (validateStatus accepts everything) and parse throws mean the
  /// body itself is unusable.
  static bool _isRetryableCoverError(Object e) =>
      e is TimeoutException || e is DioException;

  /// Cancellable backoff wait; [close] fires all waiters early.
  Future<void> _coverRetryDelay(Duration delay) {
    final wait = Completer<void>();
    late final Timer timer;
    timer = Timer(delay, () {
      _coverRetryWaits.remove(timer);
      if (!wait.isCompleted) wait.complete();
    });
    _coverRetryWaits[timer] = wait;
    return wait.future.then((_) => _coverRetryWaits.remove(timer));
  }

  static String? _largestSquareThumb(List<Thumbnail> thumbs) {
    // Last wins ties (including missing dimensions): YouTube orders
    // thumbnail sizes ascending, so the final square entry is the
    // biggest — the `thumbnails[-1]` rule for song rows.
    Thumbnail? best;
    var bestW = -1;
    for (final t in thumbs) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t;
      }
    }
    return best?.url;
  }

  /// Coalesces in-flight identical requests (path + body) so a burst of
  /// the same call shares one request instead of hitting the network N
  /// times. Responses are NOT cached beyond the request itself — InnerTube
  /// responses are small and cheap, and serving a 5-minute-old
  /// `browse`/`search`/`next` response would make refresh and session
  /// changes look stale.
  final Map<String, Future<dynamic>> _requestCache = {};

  /// Per-cpn watchtime contexts (one entry per track playback, bounded).
  final Map<String, WatchtimeContext> _watchtimeContexts = {};

  /// Wall-clock start per cpn, for the `lact` beacon param.
  final Map<String, int> _watchtimeStartMs = {};

  /// Last `rtn` counter per cpn (`rti` chains the previous value).
  final Map<String, int> _watchtimeLastRtn = {};

  /// Bearer token WEB_REMIX already rejected: skip straight to a working
  /// session instead of paying a doomed request every time. Reset when the
  /// token rotates.
  String? _bearerBrokenFor;

  /// Upper bound on continuation pages walked for one list. A big
  /// liked-songs list runs to ~10 pages; the cap only guards against
  /// a server that keeps handing out tokens.
  static const _maxBrowsePages = 40;

  /// The WEB client version used for channel pages, which the music
  /// client does not answer.
  static const webClientVersion = '2.20250101.00.00';

  /// Today's WEB_REMIX client version string (`1.YYYYMMDD.01.00`).
  static String clientVersion([DateTime? now]) {
    final today = (now ?? DateTime.now()).toUtc();
    final y = today.year.toString().padLeft(4, '0');
    final m = today.month.toString().padLeft(2, '0');
    final d = today.day.toString().padLeft(2, '0');
    return '1.$y$m$d.01.00';
  }

  static Map<String, dynamic> _contextBlock() => {
    'context': {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': clientVersion(),
        'hl': 'en',
      },
      'user': <String, dynamic>{},
    },
  };

  static Map<String, dynamic> _bodyWith(Map<String, dynamic> extra) => {
    'context': _contextBlock()['context'],
    ...extra,
  };

  static bool _isErrorResponse(dynamic res) =>
      res is Map && res.containsKey('error');

  /// Creates a unique cache key for request deduplication.
  /// Uses path and body content to identify identical requests.
  String _createCacheKey(String path, String bodyString) {
    // Simple but effective: path + body hash
    // For consistent hashing across runs, we use the body content directly
    // since the order and content of the body determines the request identity
    return '$path:$bodyString';
  }

  /// Posts to an InnerTube endpoint with cookie/Bearer/anonymous auth
  /// fallback, mirroring Kotlin `post`.
  ///
  /// Identical concurrent requests are coalesced so a burst of the same
  /// call shares one in-flight request.
  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final bodyString = jsonEncode(body);
    final cacheKey = _createCacheKey(path, bodyString);

    // Reuse an in-flight identical request instead of duplicating it.
    final inflight = _requestCache[cacheKey];
    if (inflight != null) return inflight;

    late final Future<dynamic> requestFuture;
    requestFuture = _postWithAuth(path, bodyString);
    _requestCache[cacheKey] = requestFuture;
    // Drop the entry when it settles. `.ignore()` marks the derived
    // future's error as handled, so a failed request never surfaces as an
    // unhandled async error (the real callers await [requestFuture]).
    requestFuture.whenComplete(() async {
      await _requestCache.remove(cacheKey);
    }).ignore();

    return requestFuture;
  }

  /// Internal method to handle authenticated requests with auth fallbacks.
  Future<dynamic> _postWithAuth(String path, String bodyString) async {
    AuthSession? provided;
    try {
      provided = await authProvider?.call();
    } catch (_) {
      provided = null;
    }
    final session = provided ?? auth;
    final saved = auth;
    final token = session.accessToken;
    final isFeedback = path == 'feedback';
    final skipBearer =
        token != null && _bearerBrokenFor == token && !isFeedback;
    final sessions = <AuthSession>[];
    void add(AuthSession s) {
      if (!sessions.contains(s)) sessions.add(s);
    }

    if (isFeedback) {
      // feedback: Bearer first (valid), then cookie, then anonymous.
      if (!skipBearer) add(session);
      if ((saved.cookie ?? '').isNotEmpty && saved != session) add(saved);
    } else {
      // all other paths: cookie first, then Bearer, then anonymous.
      if ((saved.cookie ?? '').isNotEmpty && saved != session) add(saved);
      if (!skipBearer) add(session);
    }
    if (saved != session) add(saved);
    add(const AuthSession.anonymous());

    dynamic last;
    var bearerFailed = false;
    for (final candidate in sessions) {
      dynamic response;
      try {
        response = await _request(path, bodyString, candidate);
      } catch (_) {
        // Transport blips (timeout, reset) throw; auth verdicts come back
        // as error bodies. Retry the transport once, then propagate — the
        // Dio retry interceptor already front-loads resilience, and cover
        // lookups have their own [_fetchWithRetry] ladder.
        response = await _request(path, bodyString, candidate);
      }
      if (!_isErrorResponse(response)) {
        if (bearerFailed && token != null) _bearerBrokenFor = token;
        return response;
      }
      if (candidate.accessToken != null && candidate.accessToken == token) {
        bearerFailed = true;
      }
      last = response;
      if (!_canUseAnonymousFallback(path, bodyString)) break;
    }
    return last ?? <String, dynamic>{};
  }

  /// True when an authed error response may be retried with other sessions.
  bool _canUseAnonymousFallback(String path, String bodyString) {
    switch (path) {
      case 'search':
      case 'next':
      case 'feedback':
        return true;
      case 'browse':
        // Public music browse is safe to retry, but a library browse must
        // remain an honest authentication check (verifyLogin relies on it).
        return !bodyString.contains('FEmusic_library_landing');
      default:
        return false;
    }
  }

  /// Executes a single authenticated InnerTube POST. Shape mirrors
  /// ytmusicapi: no API key, `alt=json`, Firefox UA, always Origin;
  /// `X-Goog-Request-Time` only for Bearer sessions.
  Future<dynamic> _request(
    String path,
    String bodyString,
    AuthSession session,
  ) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': _userAgent,
      'Origin': _origin,
    };
    if (session.accessToken != null) {
      headers['Authorization'] = 'Bearer ${session.accessToken}';
      headers['X-Goog-Request-Time'] =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    } else {
      if (session.cookie != null) headers['Cookie'] = session.cookie!;
      if (session.sapisidHash != null) {
        headers['Authorization'] = 'SAPISIDHASH ${session.sapisidHash}';
      }
    }
    final res = await _dio
        .postUri<String>(
          Uri.parse('$_base/$path?alt=json'),
          data: bodyString,
          options: Options(headers: headers),
        )
        .timeout(const Duration(seconds: 30));
    return decodeJsonResponse(res.data ?? '');
  }

  /// Loads the home feed shelves plus the mood filter chips
  /// (chipCloudRenderer titles), empty when the response has no tabs.
  Future<({List<Shelf> shelves, List<String> moods})> home() async {
    final res = await post('browse', _bodyWith({'browseId': 'FEmusic_home'}));
    return (shelves: _browseShelvesFrom(res), moods: parseHomeMoods(res));
  }

  /// Loads YouTube's Explore feed. Unlike the personalized home feed,
  /// which rotates and routinely omits sections, Explore carries stable
  /// editorial shelves ("New albums & singles", "Trending", "Moods &
  /// genres", …) that the home screen pins as fixed sections. Empty
  /// when the response has no tabs.
  Future<List<Shelf>> explore() async {
    final res = await post(
      'browse',
      _bodyWith({'browseId': 'FEmusic_explore'}),
    );
    return _browseShelvesFrom(res);
  }

  /// Loads the next page of items for [continuation] (a shelf's load-more
  /// token) using the same signed `browse` request the home feed uses, with
  /// the continuation token in place of `browseId`. Returns the additional
  /// items plus any continuation token the response carries for a further
  /// page, or null when the shelf is exhausted.
  Future<({List<ShelfItem> items, String? continuation})> loadMoreShelf(
    String continuation,
  ) async {
    final res = await post('browse', _bodyWith({'continuation': continuation}));
    final shelves = _browseShelvesFrom(res);
    if (shelves.isEmpty) {
      return (items: const <ShelfItem>[], continuation: null);
    }
    final first = shelves.first;
    return (items: first.items, continuation: first.continuation);
  }

  /// YouTube's Charts feed: per-country and worldwide music charts.
  static const _chartsBrowseId = 'FEmusic_charts';

  /// Region code the Charts feed gives its worldwide (global) chart.
  static const _globalChartCode = 'ZZ';

  /// The home screen's trending sources, read from the Charts feed: the
  /// display name of the user's own country plus the worldwide chart's
  /// tracks.
  ///
  /// Explore's "Trending" shelf is region-derived (it follows the
  /// region the request comes from), so only the country row can use
  /// it; the worldwide chart lives on the Charts page behind its
  /// country filter, which starts on the request's region and lists the
  /// worldwide chart only once switched to Global. So this reads the
  /// filter first (the country's name and the Global option), switches
  /// the filter to Global and loads the chart playlist the feed then
  /// offers. Either half comes back empty when the feed, the option or
  /// the playlist is unavailable — the row just loses its name/hides.
  Future<({String? country, List<Track> tracks})> charts() async {
    final options = _chartCountryOptions(
      await post('browse', _bodyWith({'browseId': _chartsBrowseId})),
    );
    String? country;
    String? globalKey;
    final region = systemRegion();
    for (final option in options) {
      if (option.code == region) country = option.title;
      if (option.code == _globalChartCode) globalKey = option.key;
    }
    return (country: country, tracks: await _globalChartTracks(globalKey));
  }

  /// Selectable chart regions in a Charts response: each option's region
  /// code, display name and the key to submit when switching to it.
  static List<({String code, String title, String key})> _chartCountryOptions(
    dynamic res,
  ) {
    final options = nav(res, const [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
      'musicShelfRenderer',
      'subheaders',
      0,
      'musicSideAlignedItemRenderer',
      'startItems',
      0,
      'musicSortFilterButtonRenderer',
      'menu',
      'musicMultiSelectMenuRenderer',
      'options',
    ]);
    if (options is! List) return const [];
    const item = 'musicMultiSelectMenuItemRenderer';
    final out = <({String code, String title, String key})>[];
    for (final option in options) {
      final title = runsText(nav(option, const [item, 'title', 'runs']));
      final key =
          nav(option, const [item, 'formItemEntityKey'])?.toString() ?? '';
      final code = _chartCountryCode(key);
      if (title.isEmpty || code == null) continue;
      out.add((code: code, title: title, key: key));
    }
    return out;
  }

  /// Region code a chart country option encodes in its key: the key is
  /// base64 of an opaque form id ending in the region's ISO code
  /// ("ZZ" for the worldwide chart).
  static String? _chartCountryCode(String key) {
    if (key.isEmpty) return null;
    try {
      final text = utf8.decode(
        base64.decode(Uri.decodeComponent(key)),
        allowMalformed: true,
      );
      final tail = text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      if (tail.length < 2) return null;
      final code = tail.substring(tail.length - 2).toUpperCase();
      return RegExp(r'^[A-Z]{2}$').hasMatch(code) ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// Tracks of the worldwide chart: switch the Charts country filter to
  /// the option [globalKey] stands for, then load the chart playlist the
  /// feed lists (it names worldwide charts in its own words, so match
  /// "global" and prefer the top-100 chart).
  Future<List<Track>> _globalChartTracks(String? globalKey) async {
    if (globalKey == null) return const [];
    final res = await post('browse', {
      'context': _contextBlock()['context'],
      'browseId': _chartsBrowseId,
      'formData': {
        'selectedValues': [globalKey],
      },
    });
    final candidates = [
      for (final shelf in _browseShelvesFrom(res))
        for (final item in shelf.items.whereType<BrowseItem>())
          if (item.browseId.isNotEmpty &&
              item.title.toLowerCase().contains('global'))
            item,
    ];
    for (final candidate in candidates) {
      if (candidate.title.toLowerCase().contains('top 100')) {
        return (await playlist(candidate.browseId))?.tracks ?? const [];
      }
    }
    if (candidates.isEmpty) return const [];
    return (await playlist(candidates.first.browseId))?.tracks ?? const [];
  }

  /// Parses the section list of a `browse` response into shelves; the
  /// shared shape behind [home] and [explore].
  static List<Shelf> _browseShelvesFrom(dynamic res) {
    final tabs = nav(res, const [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
    ]);
    if (tabs is! List || tabs.isEmpty) return const [];
    final content = nav(tabs.first, const [
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (content is! List) return const [];
    final out = <Shelf>[];
    for (final el in content) {
      final shelf = parseShelf(el);
      if (shelf != null) out.add(shelf);
    }
    return out;
  }

  /// Searches YouTube Music and normalizes results into stable categories
  /// ("Songs", "Albums/EP/Singles", "Artists").
  Future<Map<String, List<ShelfItem>>> search(String query) async {
    final res = await post('search', _bodyWith({'query': query}));
    final tabs = nav(res, const [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
    ]);
    if (tabs is! List || tabs.isEmpty) return {};
    final sections = nav(tabs.first, const [
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (sections is! List) return {};
    final raw = <String, List<ShelfItem>>{};
    final directSongs = <SongItem>[];
    for (final section in sections) {
      if (section is! Map) continue;
      // Shelves may sit at top level or inside itemSectionRenderer.
      final candidates = <Map>[section];
      final inner = nav(section, const ['itemSectionRenderer', 'contents']);
      if (inner is List) {
        for (final it in inner) {
          if (it is Map) candidates.add(it);
        }
      }
      for (final c in candidates) {
        if (c.containsKey('musicShelfRenderer') ||
            c.containsKey('musicCardShelfRenderer')) {
          parseSearchShelf(c, raw);
          continue;
        }
        final li = c['musicResponsiveListItemRenderer'];
        if (li != null) {
          final song = parseListItem(li);
          if (song != null) {
            directSongs.add(SongItem(song));
          } else {
            final b = parseBrowseItem(li);
            if (b != null) {
              raw.putIfAbsent('Browse', () => []).add(b);
            }
          }
        }
      }
    }
    if (directSongs.isNotEmpty) {
      raw.putIfAbsent('Songs', () => []).addAll(directSongs);
    }

    // Normalize locale/shelf-specific sections into stable categories.
    final songs = <String, SongItem>{};
    final releases = <String, BrowseItem>{};
    final artists = <String, BrowseItem>{};
    for (final items in raw.values) {
      for (final item in items) {
        if (item is SongItem) {
          songs.putIfAbsent(item.track.videoId, () => item);
        } else if (item is BrowseItem) {
          if (item.browseId.startsWith('MPRE')) {
            releases.putIfAbsent(item.browseId, () => item);
          } else if (item.browseId.startsWith('UC')) {
            artists.putIfAbsent(item.browseId, () => item);
          }
        }
      }
    }
    final queryCanon = canonicalMetadata(query);
    final dominantIds = artists.values.map((a) => a.browseId).toSet();
    final dominantNames = artists.values
        .map((a) => canonicalMetadata(a.title))
        .where((n) => n.isNotEmpty)
        .toSet();

    bool isDominantRelease(BrowseItem b) {
      if (dominantNames.isEmpty) return false;
      final subtitle = ' ${canonicalMetadata(b.subtitle)} ';
      return dominantNames.any((n) => subtitle.contains(' $n '));
    }

    if (queryCanon.isNotEmpty) {
      // A single/EP sometimes arrives with no dedicated song row. When the
      // query names such a release exactly, surface its title tracks first.
      final cands =
          releases.values
              .where(
                (it) =>
                    (it.kind == ReleaseKind.single ||
                        it.kind == ReleaseKind.ep) &&
                    canonicalMetadata(it.title) == queryCanon,
              )
              .toList()
            ..sort(
              (a, b) =>
                  (isDominantRelease(b) ? 1 : 0) -
                  (isDominantRelease(a) ? 1 : 0),
            );
      final added = <Track>[];
      for (final release in cands.take(2)) {
        try {
          final detail = await album(release.browseId);
          if (detail != null) added.addAll(detail.tracks);
        } catch (_) {}
      }
      final fresh = added
          .where(
            (t) =>
                canonicalMetadata(t.title) == queryCanon &&
                !songs.containsKey(t.videoId),
          )
          .toList();
      final distinct = <String, SongItem>{};
      for (final t in fresh) {
        distinct.putIfAbsent(t.videoId, () => SongItem(t));
      }
      if (distinct.isNotEmpty) {
        for (final e in songs.entries) {
          distinct.putIfAbsent(e.key, () => e.value);
        }
        songs
          ..clear()
          ..addAll(distinct);
      }
      // "Title artist" queries sometimes return the artist's other
      // songs but not the named recording itself (e.g. "kid again
      // ivycomb" lists ivycomb tracks without "Kid Again"). When no
      // song matches both the title and an artist word, pull the
      // queried artist's top songs (one extra fetch) and merge any
      // title match in.
      final queryTokens = queryCanon
          .split(' ')
          .where((t) => t.isNotEmpty)
          .toSet();
      Set<String> wordSet(String v) =>
          canonicalMetadata(v).split(' ').where((t) => t.isNotEmpty).toSet();
      bool namesTitleAndArtist(SongItem s) {
        final titleWords = wordSet(s.track.title);
        if (titleWords.isEmpty || !titleWords.every(queryTokens.contains)) {
          return false;
        }
        final artistWords = s.track.artists.expand((a) => wordSet(a.name));
        return artistWords.any(queryTokens.contains);
      }

      if (songs.values.every((s) => !namesTitleAndArtist(s))) {
        final targets = artists.values
            .where((a) {
              final nameWords = wordSet(a.title);
              return nameWords.isNotEmpty &&
                  nameWords.every(queryTokens.contains);
            })
            .take(1);
        for (final target in targets) {
          ArtistDetail? detail;
          try {
            detail = await artist(target.browseId);
          } catch (_) {}
          if (detail == null) continue;
          bool titleMatches(Track t) {
            final titleWords = wordSet(t.title);
            return titleWords.isNotEmpty &&
                titleWords.every(queryTokens.contains) &&
                !songs.containsKey(t.videoId);
          }

          var hits = detail.topSongs.where(titleMatches).toList();
          // Top songs only skim the catalog: older cuts (e.g. a "Kid
          // Again" buried past the latest singles) surface through the
          // artist's full songs playlist instead.
          if (hits.isEmpty && detail.songsPlaylistId != null) {
            try {
              final full = await playlist(
                detail.songsPlaylistId!,
                params: detail.songsPlaylistParams,
              );
              hits = (full?.tracks ?? []).where(titleMatches).toList();
            } catch (_) {}
          }
          if (hits.isEmpty) continue;
          final merged = <String, SongItem>{
            for (final t in hits) t.videoId: SongItem(t),
          };
          for (final e in songs.entries) {
            merged.putIfAbsent(e.key, () => e.value);
          }
          songs
            ..clear()
            ..addAll(merged);
        }
      }
      // Best text match first (exact titles, then title+artist token
      // overlap so "title artist" queries surface the right
      // recording), ties keeping YouTube's order.
      final ranked = rankSearchSongs(
        songs.values,
        query,
        dominantIds: dominantIds,
        dominantNames: dominantNames,
      );
      songs.clear();
      for (final s in ranked) {
        songs[s.track.videoId] = s;
      }
      // Same preference inside releases.
      if (dominantNames.isNotEmpty) {
        final own = releases.values.where(isDominantRelease).toList();
        final other = releases.values
            .where((r) => !isDominantRelease(r))
            .toList();
        releases.clear();
        for (final r in [...own, ...other]) {
          releases[r.browseId] = r;
        }
      }
    }
    final out = <String, List<ShelfItem>>{};
    if (songs.isNotEmpty) out['Songs'] = songs.values.toList();
    if (releases.isNotEmpty) {
      out['Albums/EP/Singles'] = releases.values.toList();
    }
    if (artists.isNotEmpty) out['Artists'] = artists.values.toList();
    return out;
  }

  /// Opens an album/release page, backfilling track artists/artwork.
  Future<AlbumDetail?> album(String browseId) async {
    final res = await post('browse', _bodyWith({'browseId': browseId}));
    if (_isErrorResponse(res)) return null;
    return buildAlbum(res, browseId);
  }

  /// Opens an artist page (top songs + classified carousels).
  Future<ArtistDetail?> artist(String browseId) async {
    final res = await post('browse', _bodyWith({'browseId': browseId}));
    if (_isErrorResponse(res)) return null;
    return buildArtist(res);
  }

  /// Opens a playlist page. Raw `PL…` ids answer HTTP 400, so the canonical
  /// `VL…` form is tried as well, keeping the first non-error response.
  /// A browsed playlist, with every one of its songs.
  ///
  /// The playlist page carries the first rows and the token for the
  /// next ones, so the rest of the playlist is paged in: a long
  /// playlist lists all of its songs, not just the first page.
  Future<PlaylistDetail?> playlist(String browseId, {String? params}) async {
    final ids = browseId.startsWith('PL')
        ? [browseId, 'VL$browseId']
        : [browseId];
    for (final id in ids) {
      final extra = {'browseId': id};
      if (params != null && params.isNotEmpty) extra['params'] = params;
      dynamic res;
      try {
        res = await post('browse', _bodyWith(extra));
      } catch (_) {
        continue;
      }
      if (_isErrorResponse(res)) continue;
      final detail = buildPlaylist(res);
      if (detail != null) {
        final tracks = await _playlistSongs(res, detail.tracks);
        return PlaylistDetail(
          title: detail.title,
          subtitle: detail.subtitle,
          thumbnails: detail.thumbnails,
          tracks: tracks,
          author: detail.author,
        );
      }
    }
    return null;
  }

  /// The songs of a playlist: the page's own rows plus every page its
  /// continuation leads to.
  Future<List<Track>> _playlistSongs(dynamic page, List<Track> first) async {
    final out = List<Track>.of(first);
    var token = _playlistShelfToken(page);
    for (var p = 0; p < _maxBrowsePages && token != null; p++) {
      dynamic res;
      try {
        res = await post('browse', _bodyWith({'continuation': token}));
      } catch (_) {
        break;
      }
      if (_isErrorResponse(res)) break;
      final items = _appendedItems(res);
      if (items == null) break;
      for (final item in items) {
        final li = nav(item, const ['musicResponsiveListItemRenderer']);
        if (li == null) continue;
        final t = parseListItem(li);
        if (t == null) continue;
        // Playlist rows keep the running time in the fixed columns.
        final duration = parseRowDuration(li);
        out.add(duration > 0 ? t.copyWith(durationSec: duration) : t);
      }
      token = _tokenInRows(items);
    }
    return out;
  }

  /// The token that continues the playlist shelf in [res].
  ///
  /// Scoped to the playlist shelf: a playlist page carries other
  /// shelves (the description, recommendations) whose tokens lead
  /// somewhere else entirely.
  String? _playlistShelfToken(dynamic res) {
    final shelf =
        findFirst(res, 'musicPlaylistShelfRenderer') ??
        findFirst(res, 'musicPlaylistShelfContinuation');
    if (shelf is Map) {
      final contents = nav(shelf, const ['contents']);
      if (contents is List) {
        final token = _tokenInRows(contents);
        if (token != null) return token;
      }
    }
    final items = _appendedItems(res);
    if (items != null) return _tokenInRows(items);
    return null;
  }

  /// The rows a continued page appends: the row list and its trailing
  /// continuation row in one place.
  List<dynamic>? _appendedItems(dynamic res) {
    final actions = nav(res, const ['onResponseReceivedActions']);
    if (actions is List) {
      for (final action in actions) {
        final items = nav(action, const [
          'appendContinuationItemsAction',
          'continuationItems',
        ]);
        if (items is List && items.isNotEmpty) return items;
      }
    }
    return null;
  }

  /// Resolves just the artwork of a playlist, trying the PL/VL id variants.
  Future<List<Thumbnail>> playlistArtwork(
    String browseId, {
    String? params,
  }) async {
    if (browseId.trim().isEmpty) return [];
    final ids = browseId.startsWith('PL')
        ? [browseId, 'VL$browseId']
        : [browseId];
    for (final id in ids) {
      final extra = {'browseId': id};
      if (params != null && params.isNotEmpty) extra['params'] = params;
      dynamic res;
      try {
        res = await post('browse', _bodyWith(extra));
      } catch (_) {
        continue;
      }
      final thumbs = playlistArtworkThumbs(res);
      if (thumbs.isNotEmpty) return thumbs;
    }
    return [];
  }

  Future<dynamic> _nextResponse(String videoId, {String? playlistId}) {
    final extra = {'videoId': videoId, 'queueContext': ''};
    if (playlistId != null) extra['playlistId'] = playlistId;
    return post('next', _bodyWith(extra));
  }

  /// Returns the up-next queue for a video, optionally within a playlist.
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async {
    final res = await _nextResponse(videoId, playlistId: playlistId);
    if (_isErrorResponse(res)) return [];
    return panelsOf(res);
  }

  /// Liked songs of the signed-in account.
  ///
  /// The list is YouTube's "Liked Music" playlist (`VLLM`) — the
  /// playlist the YouTube Music sidebar links to as *Liked songs* —
  /// and nothing else: no library shelf, no other source. Every
  /// entry of that playlist is listed, whatever it holds: official
  /// music videos, user uploads and album tracks all count as liked
  /// songs.
  ///
  /// The playlist is read in its "Newest first" order, so the list
  /// reads newest-like first (and the first page already is the newest
  /// songs, not an arbitrary slice of the playlist). The rows also
  /// carry the like timestamp (`playlistItemData.voteSortValue`), which
  /// orders the list when the sorted order is unavailable.
  ///
  /// The count the playlist's header reports ([likedCount]) counts every
  /// entry of the playlist, while its shelf renders only the ones it
  /// can show, so the two differ — as they do in YouTube Music itself.
  Future<List<Track>> likedVideos({int max = 2000}) async {
    if (auth == const AuthSession.anonymous()) return const [];
    try {
      final rows = await _likedRows(limit: max);
      final seen = <String>{};
      final dated = <({Track track, int likedAt, int order})>[];
      final undated = <Track>[];
      for (final row in rows) {
        if (!seen.add(row.track.videoId)) continue;
        final likedAt = row.likedAt;
        if (likedAt == null) {
          undated.add(row.track);
        } else {
          dated.add((track: row.track, likedAt: likedAt, order: dated.length));
        }
      }
      // Newest like first; songs liked within the same second keep the
      // order the playlist listed them in.
      dated.sort((a, b) {
        final byTime = b.likedAt.compareTo(a.likedAt);
        return byTime != 0 ? byTime : a.order.compareTo(b.order);
      });
      final out = <Track>[...dated.map((e) => e.track), ...undated];
      return out.length <= max ? out : out.sublist(0, max);
    } catch (_) {
      return const [];
    }
  }

  /// The song count YouTube reports for the liked-music playlist.
  ///
  /// The playlist's header counts every entry of the playlist ("524
  /// songs"), while its shelf only renders the entries it can show —
  /// so the count and the number of rows differ, exactly as they do
  /// in YouTube Music itself. Null until a playlist page was read.
  int? get likedCount => _likedCount;
  int? _likedCount;

  /// Pages the liked-music playlist, pairing every row with the like
  /// timestamp it carries (null when the row exposes none).
  Future<List<({Track track, int? likedAt})>> _likedRows({
    int limit = 2000,
  }) async {
    final out = <({Track track, int? likedAt})>[];
    final page = await post('browse', _bodyWith({'browseId': 'VLLM'}));
    if (_isErrorResponse(page)) return out;
    // The count the playlist's header reports: every entry of the
    // playlist, not only the ones its shelf renders.
    _likedCount = _playlistSongCount(page);
    // The playlist in its "Newest first" order: the server sorts, so
    // even the first page is the newest songs.
    final newestFirst = _sortContinuation(page, 'VLLM_NEWEST_ADDED');
    final sizes = newestFirst != null
        ? await _shelfRows(
            out,
            () => post('browse', _bodyWith({'continuation': newestFirst})),
            limit: limit,
          )
        : await _shelfRows(out, () async => page, limit: limit);
    // The shelf renders the entries it can show while the header
    // counts all of them, so the two differ by design. A wider gap
    // means the walk lost rows on the way, and the page sizes say
    // which page it was.
    final counted = _likedCount;
    if (counted != null && out.length < counted) {
      debugPrint(
        '[liked] the playlist counts $counted songs, the shelf rendered '
        '${out.length} (pages: $sizes)',
      );
    }
    return out;
  }

  /// The song count the playlist page's header reports ("524 songs").
  static int? _playlistSongCount(dynamic page) {
    int? found;
    void walk(dynamic node) {
      if (found != null) return;
      if (node is Map) {
        final subtitle = node['secondSubtitle'];
        if (subtitle is Map) {
          final runs = subtitle['runs'];
          if (runs is List) {
            final text = runs
                .map((r) => r is Map ? (r['text'] ?? '') : '')
                .join(' ');
            final m = RegExp(r'(\d+)\s+songs?\b').firstMatch(text);
            if (m != null) {
              found = int.tryParse(m.group(1)!);
              return;
            }
          }
        }
        node.forEach((k, v) => walk(v));
      } else if (node is List) {
        for (final v in node) {
          walk(v);
          if (found != null) return;
        }
      }
    }

    walk(page);
    return found;
  }

  /// Walks a shelf, appending its rows to [out] until [limit] is
  /// reached or the shelf runs out of pages.
  ///
  /// Returns the number of rows every page carried, so the caller can
  /// tell a clean walk from one that lost rows on the way.
  ///
  /// The pages of a shelf all carry the same number of rows, so a page
  /// that comes back with fewer of them lost rows in the response: it
  /// is fetched once more and the fuller of the two answers is used.
  Future<List<int>> _shelfRows(
    List<({Track track, int? likedAt})> out,
    Future<dynamic> Function() fetch, {
    required int limit,
  }) async {
    final sizes = <int>[];
    var request = fetch;
    var res = await request();
    if (_isErrorResponse(res)) return sizes;
    var full = 0;
    for (var page = 0; page < _maxBrowsePages; page++) {
      var shelf = _likedShelf(res);
      if (shelf == null) break;
      var tracks = _shelfTracks(shelf.rows);
      if (tracks.length > full) full = tracks.length;
      if (tracks.length < full && shelf.token != null) {
        // The page came back short: its response dropped rows. Fetch
        // it again and keep whichever answer carries more of them.
        debugPrint(
          '[liked] page $page came back short: ${tracks.length} of '
          '$full rows',
        );
        final retry = await request();
        if (!_isErrorResponse(retry)) {
          final again = _likedShelf(retry);
          if (again != null) {
            final refetched = _shelfTracks(again.rows);
            if (refetched.length > tracks.length) {
              debugPrint(
                '[liked] page $page refetched: ${refetched.length} rows',
              );
              shelf = again;
              tracks = refetched;
            }
          }
        }
      }
      sizes.add(tracks.length);
      out.addAll(tracks);
      if (out.length >= limit) return sizes;
      final token = shelf.token;
      if (token == null) break;
      request = () => post('browse', _bodyWith({'continuation': token}));
      res = await request();
      if (_isErrorResponse(res)) break;
    }
    return sizes;
  }

  /// The tracks the shelf rows carry, with their like timestamp and
  /// their duration.
  List<({Track track, int? likedAt})> _shelfTracks(List<dynamic> rows) {
    final out = <({Track track, int? likedAt})>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final inner = row['musicResponsiveListItemRenderer'];
      final t = parseListItem(inner ?? row);
      if (t == null || t.videoId.isEmpty) continue;
      final likedAt =
          nav(row, const ['playlistItemData', 'voteSortValue']) ??
          nav(inner, const ['playlistItemData', 'voteSortValue']);
      final duration = parseRowDuration(inner ?? row);
      out.add((
        track: duration > 0 ? t.copyWith(durationSec: duration) : t,
        likedAt: likedAt is num ? likedAt.toInt() : null,
      ));
    }
    return out;
  }

  /// The rows of the liked shelf in [res] and the token that continues
  /// them, or null when the response carries no shelf rows.
  ///
  /// Shelf-scoped on purpose: the liked pages carry side shelves and
  /// carousels ("Listen again", "Forgotten favorites", "Recaps") whose
  /// rows are not liked songs, and reading the whole response would
  /// mix them into the list.
  ({List<dynamic> rows, String? token})? _likedShelf(dynamic res) {
    // A continued page arrives as appended items: the row list and
    // its trailing continuation row in one place.
    final actions = nav(res, const ['onResponseReceivedActions']);
    if (actions is List) {
      for (final action in actions) {
        final items = nav(action, const [
          'appendContinuationItemsAction',
          'continuationItems',
        ]);
        if (items is List && items.isNotEmpty) {
          return (rows: items, token: _tokenInRows(items));
        }
      }
    }
    // The shelf page: the playlist shelf when there is one (the
    // "Liked Music" playlist), else the plain music shelf (the
    // library's "Songs" list).
    List<dynamic>? playlistRows;
    List<dynamic>? musicRows;
    String? shelfToken;
    void walk(dynamic node) {
      if (playlistRows != null && musicRows != null) return;
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key;
          if (key is String) {
            final lower = key.toLowerCase();
            // Carousels ("Listen again", "Forgotten favorites") hold
            // rows that are not liked songs.
            final isShelf =
                lower.endsWith('shelfrenderer') ||
                lower.endsWith('shelfcontinuation');
            if (isShelf && !lower.contains('carousel')) {
              final contents = nav(entry.value, const ['contents']);
              if (contents is List && contents.isNotEmpty) {
                // Some shelves carry their token in a `continuations`
                // block next to the rows.
                final continuations = nav(entry.value, const ['continuations']);
                if (continuations is List) {
                  for (final c in continuations) {
                    final next = nav(c, const [
                      'nextContinuationData',
                      'continuation',
                    ]);
                    if (next is String && next.isNotEmpty) {
                      shelfToken = next;
                      break;
                    }
                  }
                }
                if (lower.contains('playlist')) {
                  playlistRows = contents;
                  return;
                }
                musicRows ??= contents;
              }
            }
          }
          walk(entry.value);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
          if (playlistRows != null) return;
        }
      }
    }

    walk(res);
    final rows = playlistRows ?? musicRows;
    if (rows == null) return null;
    return (rows: rows, token: _tokenInRows(rows) ?? shelfToken);
  }

  /// The continuation that reloads a browse page in one of its sort
  /// orders, or null when the page offers no such order.
  ///
  /// The sort options arrive as entity commands; the page also ships
  /// the matching reload continuations in its `frameworkUpdates`.
  /// The command key names the order in plain text
  /// (`music_sort_option_command_entity_key_VLLM_NEWEST_ADDED`),
  /// which is what picks the wanted one out of the batch.
  String? _sortContinuation(dynamic res, String marker) {
    final mutations = nav(res, const [
      'frameworkUpdates',
      'entityBatchUpdate',
      'mutations',
    ]);
    if (mutations is! List) return null;
    for (final mutation in mutations) {
      final key = str(nav(mutation, const ['entityKey']));
      if (key == null || !_entityKeyNames(key, marker)) continue;
      final token = str(
        nav(mutation, const [
          'payload',
          'commandEntity',
          'command',
          'browseSectionListReloadEndpoint',
          'continuation',
          'reloadContinuationData',
          'continuation',
        ]),
      );
      if (token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  /// True when an entity command key names [marker]. The key is a
  /// base64 blob that carries the command name in plain text.
  static bool _entityKeyNames(String key, String marker) {
    try {
      final decoded = base64.decode(Uri.decodeComponent(key));
      return String.fromCharCodes(decoded).contains(marker);
    } catch (_) {
      return false;
    }
  }

  /// The continuation token that continues the rows of [res], or null
  /// when they are complete.
  ///
  /// Scoping matters: a page carries several tokens, and the one on the
  /// section list itself loads *other* shelves (recommended albums and
  /// the like), not more rows of this one. Only a token that continues
  /// the row list may be followed, so a short playlist stops at its own
  /// last track instead of bleeding into the rest of the page.
  String? _continuationToken(dynamic res) {
    // A continued page arrives as appended items, the row list and its
    // trailing continuation row in one place.
    final actions = nav(res, const ['onResponseReceivedActions']);
    if (actions is List) {
      for (final action in actions) {
        final items = nav(action, const [
          'appendContinuationItemsAction',
          'continuationItems',
        ]);
        if (items is List) {
          final token = _tokenInRows(items);
          if (token != null) return token;
        }
      }
    }
    // A shelf page carries its rows plus the token for the next page.
    String? found;
    void walk(dynamic node) {
      if (found != null) return;
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key;
          if (key is String &&
              (key.endsWith('ShelfRenderer') ||
                  key.endsWith('ShelfContinuation'))) {
            final shelf = entry.value;
            final contents = nav(shelf, const ['contents']);
            if (contents is List) {
              final token = _tokenInRows(contents);
              if (token != null) {
                found = token;
                return;
              }
            }
            // Some shelves (the liked-songs list) carry their token in
            // a `continuations` block next to the rows.
            final continuations = nav(shelf, const ['continuations']);
            if (continuations is List) {
              for (final c in continuations) {
                final next = nav(c, const [
                  'nextContinuationData',
                  'continuation',
                ]);
                if (next is String && next.isNotEmpty) {
                  found = next;
                  return;
                }
              }
            }
          }
          walk(entry.value);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
          if (found != null) return;
        }
      }
    }

    walk(res);
    return found;
  }

  /// The continuation token carried by a row list: the trailing
  /// `continuationItemRenderer` row, or a `nextContinuationData` block.
  String? _tokenInRows(List<Object?> rows) {
    for (final row in rows) {
      final token = nav(row, const [
        'continuationItemRenderer',
        'continuationEndpoint',
        'continuationCommand',
        'token',
      ]);
      if (token is String && token.isNotEmpty) return token;
    }
    for (final row in rows) {
      if (row is! Map) continue;
      final next = nav(row, const ['nextContinuationData', 'continuation']);
      if (next is String && next.isNotEmpty) return next;
    }
    return null;
  }

  /// Account playlists from the library's "liked playlists" page.
  ///
  /// The page lists the account's own playlists (`VL…` browse ids)
  /// plus the special rows YouTube mixes in (liked music, radio
  /// mixes, the episode queue). Only real playlists are returned, with
  /// their `PL…` id so edits and opens address the same playlist.
  Future<List<AccountPlaylist>> libraryPlaylists() async {
    if (auth == const AuthSession.anonymous()) return const [];
    try {
      final res = await post(
        'browse',
        _bodyWith({'browseId': 'FEmusic_liked_playlists'}),
      );
      if (_isErrorResponse(res)) return const [];
      final out = <AccountPlaylist>[];
      for (final node in findAll(res, 'musicTwoRowItemRenderer')) {
        final title = runsText(nav(node, const ['title', 'runs']));
        if (title.isEmpty || title == 'New playlist') continue;
        final browseId =
            str(
              nav(node, const [
                'navigationEndpoint',
                'browseEndpoint',
                'browseId',
              ]),
            ) ??
            '';
        // Only the account's own playlists (`VL` + `PL…`) are
        // editable; the rest are YouTube's own rows.
        if (!browseId.startsWith('VLPL')) continue;
        final id = browseId.substring(2);
        var count = 0;
        final subtitle = runsText(nav(node, const ['subtitle', 'runs']));
        final m = RegExp(r'(\d+)\s+(?:track|song)s?').firstMatch(subtitle);
        if (m != null) count = int.tryParse(m.group(1)!) ?? 0;
        String? art;
        final thumbs = nav(node, const [
          'thumbnailRenderer',
          'musicThumbnailRenderer',
          'thumbnail',
          'thumbnails',
        ]);
        if (thumbs is List && thumbs.isNotEmpty) {
          art = str((thumbs.last as Map?)?['url']);
        }
        // The owner is the first subtitle run, which links to the
        // owner's channel.
        var owner = '';
        var ownerId = '';
        final runs = nav(node, const ['subtitle', 'runs']);
        if (runs is List && runs.isNotEmpty) {
          final first = runs.first;
          owner = str(nav(first, const ['text'])) ?? '';
          ownerId =
              str(
                nav(first, const [
                  'navigationEndpoint',
                  'browseEndpoint',
                  'browseId',
                ]),
              ) ??
              '';
        }
        out.add(
          AccountPlaylist(
            id: id,
            title: title,
            itemCount: count,
            art: art,
            arts: art == null ? const [] : [art],
            owner: owner,
            ownerId: ownerId,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Followed artists (channels the account subscribes to) from the
  /// library's artist corpus.
  Future<List<BrowseItem>> libraryArtists({int max = 50}) async {
    if (auth == const AuthSession.anonymous()) return const [];
    try {
      final res = await post(
        'browse',
        _bodyWith({'browseId': 'FEmusic_library_corpus_artists'}),
      );
      if (_isErrorResponse(res)) return const [];
      final out = <BrowseItem>[];
      for (final li in findAll(res, 'musicResponsiveListItemRenderer')) {
        final item = parseBrowseItem(li);
        if (item == null) continue;
        out.add(item);
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Tracks of one account playlist, in playlist order.
  ///
  /// The playlist page is browsed by its `VL` browse id and the rows
  /// are parsed like any other list. Only the first page is read:
  /// a playlist of thousands is not worth a multi-page crawl for the
  /// library view.
  Future<List<Track>> playlistTracks(
    String playlistId, {
    int max = 5000,
  }) async {
    if (playlistId.trim().isEmpty) return const [];
    try {
      final out = <Track>[];
      var res = await post('browse', _bodyWith({'browseId': 'VL$playlistId'}));
      if (_isErrorResponse(res)) return const [];
      for (var page = 0; page < _maxBrowsePages; page++) {
        for (final li in findAll(res, 'musicResponsiveListItemRenderer')) {
          final t = parseListItem(li);
          if (t == null) continue;
          // Playlist rows keep the running time in the fixed columns.
          final duration = parseRowDuration(li);
          out.add(duration > 0 ? t.copyWith(durationSec: duration) : t);
          if (out.length >= max) return out;
        }
        final token = _continuationToken(res);
        if (token == null) break;
        res = await post('browse', _bodyWith({'continuation': token}));
        if (_isErrorResponse(res)) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// The `setVideoId` of a track inside an account playlist, or null
  /// when the playlist does not contain it. The id is what the
  /// playlist-edit endpoint needs to remove the row.
  Future<String?> playlistItemId(String playlistId, String videoId) async {
    if (playlistId.trim().isEmpty || videoId.trim().isEmpty) return null;
    try {
      var res = await post('browse', _bodyWith({'browseId': 'VL$playlistId'}));
      if (_isErrorResponse(res)) return null;
      for (var page = 0; page < _maxBrowsePages; page++) {
        for (final node in findAll(res, 'playlistEditEndpoint')) {
          final bid = str(nav(node, const ['playlistId']));
          if (bid != null && bid != playlistId) continue;
          final actions = nav(node, const ['actions']);
          if (actions is! List) continue;
          for (final a in actions) {
            if (str(nav(a, const ['action'])) != 'ACTION_REMOVE_VIDEO') {
              continue;
            }
            if (str(nav(a, const ['removedVideoId'])) != videoId) continue;
            return str(nav(a, const ['setVideoId']));
          }
        }
        final token = _continuationToken(res);
        if (token == null) break;
        res = await post('browse', _bodyWith({'continuation': token}));
        if (_isErrorResponse(res)) break;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Creates a playlist and returns its `PL…` id, or null on failure.
  Future<String?> createPlaylist(String title) async {
    try {
      final res = await post(
        'playlist/create',
        _bodyWith({'title': title, 'privacyStatus': 'PRIVATE'}),
      );
      if (_isErrorResponse(res)) return null;
      final id = str(nav(res, const ['playlistId']));
      return (id != null && id.isNotEmpty) ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Renames a playlist. Returns true when YouTube confirms the edit.
  Future<bool> renamePlaylist(String playlistId, String title) async {
    if (playlistId.trim().isEmpty) return false;
    try {
      final res = await post('browse/edit_playlist', {
        ..._bodyWith({}),
        'playlistId': playlistId,
        'actions': [
          {'action': 'ACTION_SET_PLAYLIST_NAME', 'playlistName': title},
        ],
      });
      return str(nav(res, const ['status'])) == 'STATUS_SUCCEEDED';
    } catch (_) {
      return false;
    }
  }

  /// Deletes a playlist. Returns true when YouTube confirms the delete.
  Future<bool> deletePlaylist(String playlistId) async {
    if (playlistId.trim().isEmpty) return false;
    try {
      final res = await post(
        'playlist/delete',
        _bodyWith({'playlistId': playlistId}),
      );
      return !_isErrorResponse(res);
    } catch (_) {
      return false;
    }
  }

  /// Adds a track to a playlist.
  Future<bool> addToPlaylist(String playlistId, String videoId) async {
    if (playlistId.trim().isEmpty || videoId.trim().isEmpty) return false;
    try {
      final res = await post('browse/edit_playlist', {
        ..._bodyWith({}),
        'playlistId': playlistId,
        'actions': [
          {'action': 'ACTION_ADD_VIDEO', 'addedVideoId': videoId},
        ],
      });
      return str(nav(res, const ['status'])) == 'STATUS_SUCCEEDED';
    } catch (_) {
      return false;
    }
  }

  /// Removes a track from a playlist. [setVideoId] comes from
  /// [playlistItemId]; without it the row cannot be addressed.
  Future<bool> removeFromPlaylist(
    String playlistId,
    String videoId,
    String setVideoId,
  ) async {
    if (playlistId.trim().isEmpty || setVideoId.trim().isEmpty) return false;
    try {
      final res = await post('browse/edit_playlist', {
        ..._bodyWith({}),
        'playlistId': playlistId,
        'actions': [
          {
            'setVideoId': setVideoId,
            'action': 'ACTION_REMOVE_VIDEO',
            'removedVideoId': videoId,
          },
        ],
      });
      return str(nav(res, const ['status'])) == 'STATUS_SUCCEEDED';
    } catch (_) {
      return false;
    }
  }

  /// Subscribes to a channel. Returns true when YouTube confirms it.
  Future<bool> subscribeTo(String channelId) async {
    if (channelId.trim().isEmpty) return false;
    try {
      final res = await post(
        'subscription/subscribe',
        _bodyWith({
          'channelIds': [channelId],
        }),
      );
      return !_isErrorResponse(res);
    } catch (_) {
      return false;
    }
  }

  /// Unsubscribes from a channel.
  Future<bool> unsubscribeFrom(String channelId) async {
    if (channelId.trim().isEmpty) return false;
    try {
      final res = await post(
        'subscription/unsubscribe',
        _bodyWith({
          'channelIds': [channelId],
        }),
      );
      return !_isErrorResponse(res);
    } catch (_) {
      return false;
    }
  }

  /// Whether the account currently subscribes to [channelId], read
  /// from the channel page's subscribe button.
  Future<bool> isSubscribed(String channelId) async {
    if (channelId.trim().isEmpty) return false;
    try {
      final res = await post('browse', _bodyWith({'browseId': channelId}));
      if (_isErrorResponse(res)) return false;
      for (final node in findAll(res, 'subscribeButtonRenderer')) {
        final subscribed = nav(node, const ['subscribed']);
        if (subscribed == true) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// The signed-in channel's own id, read from the account menu's
  /// "Your channel" entry.
  Future<String?> ownChannelId() async {
    try {
      final res = await post('account/account_menu', _bodyWith({}));
      if (_isErrorResponse(res)) return null;
      for (final node in findAll(res, 'compactLinkRenderer')) {
        final title = runsText(nav(node, const ['title', 'runs']));
        if (title != 'Your channel') continue;
        final id = str(
          nav(node, const ['navigationEndpoint', 'browseEndpoint', 'browseId']),
        );
        if (id != null && id.isNotEmpty) return id;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The signed-in account's own channel avatar (square profile pic).
  Future<String?> accountAvatar() async {
    try {
      final res = await post('account/account_menu', _bodyWith({}));
      if (_isErrorResponse(res)) return null;
      for (final node in findAll(res, 'accountPhoto')) {
        final thumbs = nav(node, const ['thumbnails']);
        if (thumbs is List && thumbs.isNotEmpty) {
          return str((thumbs.last as Map?)?['url']);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Square avatar of one channel, read from the channel's own page.
  ///
  /// Channel pages only render under the WEB client (the music client
  /// answers them empty), so this request uses that client context.
  Future<String?> channelAvatar(String channelId) async {
    if (channelId.trim().isEmpty) return null;
    try {
      final res = await post('browse', {
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': webClientVersion,
            'hl': 'en',
          },
          'user': <String, dynamic>{},
        },
        'browseId': channelId,
      });
      if (_isErrorResponse(res)) return null;
      for (final node in findAll(res, 'decoratedAvatarViewModel')) {
        final sources =
            nav(node, const [
              'avatar',
              'avatarViewModel',
              'image',
              'sources',
            ]) ??
            nav(node, const ['avatarViewModel', 'image', 'sources']);
        if (sources is! List || sources.isEmpty) continue;
        var best = '';
        var bestWidth = -1;
        for (final s in sources) {
          final w = intOrNull(nav(s, const ['width'])) ?? 0;
          if (w > bestWidth) {
            bestWidth = w;
            best = str(nav(s, const ['url'])) ?? '';
          }
        }
        if (best.isNotEmpty) return best;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Avatars of several channels, keyed by channel id. Channels whose
  /// avatar cannot be read are absent from the map.
  Future<Map<String, String>> channelAvatars(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final out = <String, String>{};
    final results = await Future.wait(
      ids.map((id) async => (id, await channelAvatar(id))),
    );
    for (final (id, url) in results) {
      if (url != null && url.isNotEmpty) out[id] = url;
    }
    return out;
  }

  /// Public like count of a video, read from the watch-next response.
  ///
  /// The response carries one count per possible like state; the one
  /// matching the viewer's current state is the real count.
  Future<int?> videoLikeCount(String videoId) async {
    if (videoId.trim().isEmpty) return null;
    try {
      final res = await post(
        'next',
        _bodyWith({'videoId': videoId, 'queueContext': ''}),
      );
      if (_isErrorResponse(res)) return null;
      final entity = findFirst(res, 'likeCountEntity');
      if (entity is! Map) return null;
      final status = str(nav(res, const ['likeStatus']));
      final key = switch (status) {
        'LIKE' => 'likeCountIfLikedNumber',
        'DISLIKE' => 'likeCountIfDislikedNumber',
        _ => 'likeCountIfIndifferentNumber',
      };
      final raw =
          str(nav(entity, [key])) ??
          str(nav(entity, const ['likeCountIfIndifferentNumber']));
      return int.tryParse(raw ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Reads the YTM watch-history page (`FEmusic_history`): per-video
  /// play counts plus the parsed tracks (most recent first) so heavy
  /// rotation from other sessions can join the quick-picks pool on
  /// this device. History lists every play, so repeats count like
  /// the local play-count map does. Empty when signed out or on any
  /// failure — callers keep existing counts then. One page only
  /// (a few hundred entries); no continuation chasing.
  Future<({Map<String, int> counts, List<Track> tracks})> historySnapshot({
    int maxItems = 500,
  }) async {
    if (auth == const AuthSession.anonymous()) {
      return (counts: <String, int>{}, tracks: const <Track>[]);
    }
    try {
      final res = await post(
        'browse',
        _bodyWith({'browseId': 'FEmusic_history'}),
      );
      if (_isErrorResponse(res)) {
        return (counts: <String, int>{}, tracks: <Track>[]);
      }
      return (
        counts: parseHistoryCounts(res, maxItems: maxItems),
        tracks: parseHistoryTracks(res, maxItems: maxItems),
      );
    } catch (_) {
      return (counts: <String, int>{}, tracks: <Track>[]);
    }
  }

  /// Resolves full metadata (artists/album/artwork/like-state) for one
  /// track without playing it: one watch-next call carries the canonical
  /// panel data plus the like state, then the album page fills kind/year.
  Future<Track> enrichTrack(Track track) async {
    var result = track;
    dynamic res;
    try {
      res = await _nextResponse(track.videoId);
    } catch (_) {
      res = null;
    }
    if (res != null && result.rating == RatingStatus.unknown) {
      final overlay = str(
        nav(res, const [
          'playerOverlays',
          'playerOverlayRenderer',
          'actions',
          0,
          'likeButtonRenderer',
          'likeStatus',
        ]),
      );
      final overlayRating = overlay == null
          ? RatingStatus.unknown
          : RatingStatus.fromValue(overlay);
      var panelRating = RatingStatus.unknown;
      for (final p in panelsOf(res)) {
        if (p.videoId == track.videoId) {
          panelRating = p.rating;
          break;
        }
      }
      final fetched = overlayRating != RatingStatus.unknown
          ? overlayRating
          : panelRating;
      if (fetched != RatingStatus.unknown) {
        result = result.copyWith(rating: fetched);
      }
    }
    Track? panel;
    if (res != null) {
      for (final p in panelsOf(res)) {
        if (p.videoId == track.videoId) {
          panel = p;
          break;
        }
      }
    }
    if (panel != null) {
      final p = panel;
      final replaceGenericArtist =
          result.artists.isEmpty ||
          result.artistNames().trim().toLowerCase() == 'release';
      final existingKeys = result.artists
          .map((a) => canonicalMetadata(a.name))
          .toSet();
      final panelAddsArtist = p.artists.any(
        (a) => !existingKeys.contains(canonicalMetadata(a.name)),
      );
      final panelAddsIdentity = p.artists.any((incoming) {
        final key = canonicalMetadata(incoming.name);
        return result.artists.any(
          (existing) =>
              canonicalMetadata(existing.name) == key &&
              (existing.browseId == null || existing.browseId!.isEmpty) &&
              incoming.browseId != null &&
              incoming.browseId!.isNotEmpty,
        );
      });
      final panelHasMoreArtists = p.artists.length > result.artists.length;
      final currentAlbum = result.album;
      final panelAlbum = p.album;
      final knownArtists = [...result.artists, ...p.artists];
      final currentAlbumIsUnlinkedArtist =
          currentAlbum != null &&
          (currentAlbum.browseId == null || currentAlbum.browseId!.isEmpty) &&
          currentAlbum.kind == null &&
          knownArtists.any(
            (a) =>
                canonicalMetadata(a.name) ==
                canonicalMetadata(currentAlbum.name),
          );
      AlbumRef? preferredAlbum;
      if (currentAlbumIsUnlinkedArtist && panelAlbum == null) {
        preferredAlbum = null;
      } else if (panelAlbum == null) {
        preferredAlbum = currentAlbum;
      } else if (currentAlbum == null) {
        preferredAlbum = panelAlbum;
      } else if (currentAlbum.name.trim().toLowerCase() == 'release') {
        preferredAlbum = panelAlbum;
      } else if (currentAlbumIsUnlinkedArtist) {
        preferredAlbum = panelAlbum;
      } else if ((currentAlbum.browseId == null ||
              currentAlbum.browseId!.isEmpty) &&
          panelAlbum.browseId != null &&
          panelAlbum.browseId!.isNotEmpty) {
        preferredAlbum = panelAlbum;
      } else if (currentAlbum.kind == null && panelAlbum.kind != null) {
        preferredAlbum = panelAlbum;
      } else {
        preferredAlbum = currentAlbum;
      }
      final panelAddsValue =
          replaceGenericArtist ||
          panelHasMoreArtists ||
          panelAddsArtist ||
          panelAddsIdentity;
      final seenUrls = <String>{};
      final thumbs = <Thumbnail>[];
      for (final t in [...result.thumbnails, ...p.thumbnails]) {
        if (seenUrls.add(t.url)) thumbs.add(t);
      }
      result = result.copyWith(
        title: preferredTrackTitle(result.title, p.title),
        artists: (p.artists.isNotEmpty && panelAddsValue)
            ? p.artists
            : result.artists,
        album: preferredAlbum,
        thumbnails: thumbs,
        // Panel badge/duration fill what's missing: list sources often
        // lack both (search rows carry no length, no badges).
        // OR, never overwrite — a missing badge means "not marked",
        // not "clean", and catalog durations beat panel ones.
        explicit: result.explicit || p.explicit,
        durationSec: result.durationSec > 0
            ? result.durationSec
            : p.durationSec,
      );
      // Remember the resolved square cover so lists can show it too.
      final sqCover = _largestSquareThumb(result.thumbnails);
      if (sqCover != null) noteSquareCover(result.videoId, sqCover);
    }
    final ref = result.album;
    final refId = ref?.browseId;
    if (ref != null &&
        refId != null &&
        (ref.kind == null || ref.year.isEmpty)) {
      AlbumDetail? detail = _albumDetailsCache[refId];
      detail ??= await album(refId).catchError((_) => null);
      if (detail != null) {
        _albumDetailsCache[refId] = detail;
        result = result.copyWith(
          album: AlbumRef(
            detail.title.isEmpty ? ref.name : detail.title,
            browseId: refId,
            kind: detail.kind ?? ref.kind,
            year: detail.year.isNotEmpty ? detail.year : ref.year,
          ),
        );
      }
    }
    return result;
  }

  /// Enriches many tracks concurrently while preserving order; failures
  /// keep the input.
  Future<List<Track>> enrichTracks(
    List<Track> tracks, {
    int concurrency = 8,
  }) async {
    if (tracks.isEmpty) return tracks;
    final c = concurrency < 1 ? 1 : concurrency;
    final enriched = <String, Track>{};
    for (var i = 0; i < tracks.length; i += c) {
      final end = (i + c < tracks.length) ? i + c : tracks.length;
      final results = await Future.wait(
        tracks.sublist(i, end).map((t) async {
          try {
            return MapEntry(t.videoId, await enrichTrack(t));
          } catch (_) {
            return MapEntry(t.videoId, t);
          }
        }),
      );
      for (final e in results) {
        enriched[e.key] = e.value;
      }
    }
    return tracks.map((t) => enriched[t.videoId] ?? t).toList();
  }

  /// One watch-next read for [videoId]: its like state plus the lengths of
  /// every queue row the response carries.
  ///
  /// The signed-in queue pass already makes this call per row to read like
  /// states, and those responses carry the queue's `lengthText` values
  /// (always for the row itself, and for album/playlist/radio plays for
  /// the whole context) — so queue durations cost no extra request.
  ///
  /// Returns null when the request itself failed; a result with an unknown
  /// rating and no entry for [videoId] means the response carried no
  /// length for that row.
  Future<({RatingStatus rating, Map<String, int> durations})?> watchInfo(
    String videoId,
  ) async {
    if (videoId.trim().isEmpty) return null;
    dynamic res;
    try {
      res = await post(
        'next',
        _bodyWith({'videoId': videoId, 'queueContext': ''}),
      );
    } catch (_) {
      return null;
    }
    if (res == null || _isErrorResponse(res)) return null;
    final durations = <String, int>{};
    var rating = RatingStatus.unknown;
    for (final panel in findAll(res, 'playlistPanelVideoRenderer')) {
      final t = parsePanelVideo(panel);
      if (t == null) continue;
      if (t.durationSec > 0) durations[t.videoId] = t.durationSec;
      if (t.videoId == videoId) rating = t.rating;
    }
    final overlay = str(
      nav(res, const [
        'playerOverlays',
        'playerOverlayRenderer',
        'actions',
        0,
        'likeButtonRenderer',
        'likeStatus',
      ]),
    );
    if (overlay != null && overlay.trim().isNotEmpty) {
      rating = RatingStatus.fromValue(overlay);
    }
    return (rating: rating, durations: durations);
  }

  /// Batch [watchInfo] reads with bounded concurrency, keyed by the
  /// requested id. Failed reads are absent from the map, so callers keep
  /// their current state instead of caching a gap.
  Future<Map<String, ({RatingStatus rating, Map<String, int> durations})>>
  watchInfos(List<String> videoIds, {int concurrency = 8}) async {
    final seen = <String>{};
    final ids = <String>[];
    for (final id in videoIds.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      if (seen.add(id)) ids.add(id);
    }
    final out = <String, ({RatingStatus rating, Map<String, int> durations})>{};
    if (ids.isEmpty) return out;
    final c = concurrency < 1 ? 1 : concurrency;
    for (var i = 0; i < ids.length; i += c) {
      final end = (i + c < ids.length) ? i + c : ids.length;
      final values = await Future.wait(
        ids
            .sublist(i, end)
            .map((id) async => MapEntry(id, await watchInfo(id))),
      );
      for (final e in values) {
        final info = e.value;
        if (info != null) out[e.key] = info;
      }
    }
    return out;
  }

  /// Reads the like state of a video from the player overlay or queue panel.
  Future<RatingStatus> rating(String videoId) async =>
      (await watchInfo(videoId))?.rating ?? RatingStatus.unknown;

  /// Reads like states for many videos concurrently, skipping unknown ones.
  Future<Map<String, RatingStatus>> ratings(
    List<String> videoIds, {
    int concurrency = 8,
  }) async {
    final seen = <String>{};
    final ids = <String>[];
    for (final id in videoIds.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      if (seen.add(id)) ids.add(id);
    }
    if (ids.isEmpty) return {};
    final out = <String, RatingStatus>{};
    final c = concurrency < 1 ? 1 : concurrency;
    for (var i = 0; i < ids.length; i += c) {
      final end = (i + c < ids.length) ? i + c : ids.length;
      final values = await Future.wait(
        ids.sublist(i, end).map((id) async => MapEntry(id, await rating(id))),
      );
      for (final e in values) {
        if (e.value != RatingStatus.unknown) out[e.key] = e.value;
      }
    }
    return out;
  }

  /// Sets the like state of a video. Dislikes work here.
  Future<bool> rate(String videoId, RatingStatus rating) async {
    if (videoId.trim().isEmpty || rating == RatingStatus.unknown) {
      return false;
    }
    final endpoint = switch (rating) {
      RatingStatus.like => 'like/like',
      RatingStatus.dislike => 'like/dislike',
      RatingStatus.indifferent => 'like/removelike',
      RatingStatus.unknown => null,
    };
    if (endpoint == null) return false;
    try {
      final res = await post(endpoint, {
        'context': _contextBlock()['context'],
        'target': {'videoId': videoId},
      });
      return !_isErrorResponse(res);
    } catch (_) {
      return false;
    }
  }

  /// Reports a player event to YouTube's feedback pipeline.
  Future<bool> feedback(
    String videoId,
    String type,
    int currentTimeMs, {
    String cpn = '',
  }) async {
    if (videoId.trim().isEmpty) return false;
    try {
      final event = {
        'videoId': videoId,
        'currentTime': currentTimeMs,
        'type': type,
        if (cpn.isNotEmpty) 'cpn': cpn,
      };
      final res = await post('feedback', {
        'context': _contextBlock()['context'],
        'actions': [
          {'action': 'playerEvent', 'playerEvent': event},
        ],
      });
      return !_isErrorResponse(res);
    } catch (_) {
      return false;
    }
  }

  /// Fetches fresh watchtime session tokens for [videoId] via the player
  /// endpoint. Needs `racyCheckOk`/`contentCheckOk` or the endpoint
  /// answers 400.
  Future<WatchtimeContext?> watchtimeContext(String videoId) async {
    if (videoId.trim().isEmpty) return null;
    try {
      final res = await post('player', {
        'context': _contextBlock()['context'],
        'videoId': videoId,
        'playbackContext': {
          'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
        },
        'racyCheckOk': true,
        'contentCheckOk': true,
      });
      if (res is Map && res.containsKey('error')) return null;
      final base =
          str(
            nav(res, const [
              'playbackTracking',
              'videostatsWatchtimeUrl',
              'baseUrl',
            ]),
          ) ??
          '';
      final query = <String, String>{};
      final queryString = base.contains('?')
          ? base.split('?').sublist(1).join('?')
          : '';
      for (final part in queryString.split('&')) {
        final i = part.indexOf('=');
        if (i < 0) continue;
        query[part.substring(0, i)] = part.substring(i + 1);
      }
      final ei = query['ei'] ?? '';
      final plid = query['plid'] ?? '';
      if (ei.isEmpty || plid.isEmpty) return null;
      final lenStr = str(nav(res, const ['videoDetails', 'lengthSeconds']));
      final len =
          double.tryParse(lenStr ?? '') ??
          double.tryParse(query['len'] ?? '') ??
          0.0;
      return WatchtimeContext(
        ei: ei,
        plid: plid,
        of: query['of'] ?? '',
        vm: query['vm'] ?? '',
        lenSec: len,
        ptrackingUrl: str(
          nav(res, const ['playbackTracking', 'ptrackingUrl', 'baseUrl']),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Reports playback to YouTube's watchtime endpoints so
  /// history/recaps record the listen.
  ///
  /// Mirrors the real YTM web client (captured 2026-09-27): for new tracks
  /// (`startSec == 0.0`) fires the `ptracking` pixel, then a
  /// `stats/playback` POST to create the watch record, then
  /// `stats/watchtime` POST heartbeats; every stats POST carries
  /// `{"session_token": <XSRF_TOKEN>}` as a JSON body plus the
  /// player-minted `ei`/`plid`/`of`/`vm` session params. A `feedback` POST
  /// with a playerEvent is also sent, it returns structured JSON, giving
  /// a real success/failure signal, since the beacons answer HTTP 204
  /// (blind ack) for all well-formed requests.
  ///
  /// End-to-end verified: this sequence lands in `FEmusic_history` within
  /// ~2 minutes; the previous hand-built URLs (form-encoded token, no
  /// session params) never did.
  Future<bool> reportWatchtime(
    String videoId,
    String cpn,
    double startSec,
    double currentSec,
    String state,
    double durationSec, [
    String? playlistId,
  ]) async {
    if (videoId.trim().isEmpty || cpn.trim().isEmpty) return false;
    // The XSRF token is the auth that makes beacons record history.
    // Refresh it lazily on first use after launch/login.
    var token = auth.sessionToken;
    if (token == null || token.isEmpty) {
      try {
        token = await fetchSessionToken();
      } catch (_) {
        token = null;
      }
      if (token != null && token.isNotEmpty) {
        final s = auth;
        auth = AuthSession(
          cookie: s.cookie,
          sapisidHash: s.sapisidHash,
          accessToken: s.accessToken,
          sessionToken: token,
        );
      }
    }
    final referer = 'https://music.youtube.com/watch?v=$videoId';
    // Per-playback session tokens: fetched once per cpn, reused for the
    // track's heartbeats. A later heartbeat retries the fetch when the
    // first attempt failed transiently.
    var ctx = _watchtimeContexts[cpn];
    if (ctx == null) {
      try {
        ctx = await watchtimeContext(videoId);
      } catch (_) {
        ctx = null;
      }
      if (ctx != null) {
        if (_watchtimeContexts.length > _watchtimeContextCacheSize) {
          final old = _watchtimeContexts.keys.isNotEmpty
              ? _watchtimeContexts.keys.first
              : null;
          if (old != null) {
            _watchtimeContexts.remove(old);
            _watchtimeStartMs.remove(old);
            _watchtimeLastRtn.remove(old);
          }
        }
        _watchtimeContexts[cpn] = ctx;
      }
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startMs = _watchtimeStartMs.putIfAbsent(cpn, () => nowMs);
    var lactMs = nowMs - startMs;
    if (lactMs < 0) lactMs = 0;
    final rtn =
        (_watchtimeLastRtn[cpn] ?? _watchtimeInitialRtn) + _watchtimeRtnStep;
    final rti = rtn - 10;
    _watchtimeLastRtn[cpn] = rtn;
    // stats/playback creates the watch record that stats/watchtime
    // then updates. Fires only for new tracks (startSec == 0.0) so we
    // don't spam playback-record creation on every heartbeat.
    if (state == 'playing' && startSec == 0.0 && ctx != null) {
      final ptracking = ctx.ptrackingUrl;
      if (ptracking != null && ptracking.isNotEmpty) {
        try {
          await getBeacon(ptracking, referer);
        } catch (_) {}
      }
      try {
        await postBeacon(
          _playbackUrl(
            ctx,
            videoId,
            cpn,
            currentSec,
            durationSec,
            playlistId,
            lactMs,
          ),
          referer,
          token,
        );
      } catch (_) {}
    }
    var beaconOk = false;
    if (ctx != null) {
      try {
        final code = await postBeacon(
          _watchtimeUrl(
            ctx,
            videoId,
            cpn,
            startSec,
            currentSec,
            state,
            durationSec,
            playlistId,
            lactMs,
            rtn,
            rti,
            state == 'paused',
          ),
          referer,
          token,
        );
        beaconOk = code >= 200 && code < 300;
      } catch (_) {}
    }
    // The stats/watchtime beacon returns 204 (blind ack) for all
    // well-formed requests, so always also fire a feedback playerEvent:
    // the InnerTube POST returns a structured response, giving us a
    // real success/failure signal.
    final eventType = state == 'playing' && startSec == 0.0
        ? 'playerPlay'
        : state == 'paused'
        ? 'playerPause'
        : 'progressHeartbeat';
    var fb = false;
    try {
      fb = await feedback(
        videoId,
        eventType,
        (currentSec * 1000).toInt(),
        cpn: cpn,
      );
    } catch (_) {}
    return beaconOk || fb;
  }

  /// Formats seconds for beacon params, clamping negatives to zero.
  String _fmtSec(double v) => (v < 0 ? 0.0 : v).toStringAsFixed(3);

  /// Builds a `stats/playback` URL in the real web client's shape.
  String _playbackUrl(
    WatchtimeContext ctx,
    String videoId,
    String cpn,
    double currentSec,
    double durationSec,
    String? playlistId,
    int lactMs,
  ) {
    final len = durationSec > 0.0 ? durationSec : ctx.lenSec;
    final out = StringBuffer()
      ..write('https://music.youtube.com/api/stats/playback')
      ..write('?ns=yt&el=detailpage&cpn=$cpn')
      ..write('&ver=2&cmt=${_fmtSec(currentSec)}')
      ..write('&fmt=0&fs=0&rt=${_fmtSec(currentSec + _beaconRtOffsetSec)}')
      ..write('&euri&lact=$lactMs')
      ..write('&cl=$_beaconClientId')
      ..write('&mos=0&volume=100')
      ..write('&cbr=Chrome&cbrver=$_beaconCbrVer')
      ..write('&c=WEB_REMIX&cver=${clientVersion()}')
      ..write('&cplayer=UNIPLAYER&cos=X11&cplatform=DESKTOP')
      ..write('&hl=en_US&cr=US&uga=m18')
      ..write('&len=${_fmtSec(len)}');
    _appendBeaconTail(out, ctx, videoId, playlistId);
    return out.toString();
  }

  /// Builds a `stats/watchtime` URL in the real web client's shape.
  String _watchtimeUrl(
    WatchtimeContext ctx,
    String videoId,
    String cpn,
    double startSec,
    double currentSec,
    String state,
    double durationSec,
    String? playlistId,
    int lactMs,
    int rtn,
    int rti,
    bool finalBeacon,
  ) {
    final len = durationSec > 0.0 ? durationSec : ctx.lenSec;
    final out = StringBuffer()
      ..write('https://music.youtube.com/api/stats/watchtime')
      ..write('?ns=yt&el=detailpage&cpn=$cpn')
      ..write('&ver=2&cmt=${_fmtSec(currentSec)}')
      ..write('&fmt=0&fs=0&rt=${_fmtSec(currentSec + _beaconRtOffsetSec)}')
      ..write('&euri&lact=$lactMs')
      ..write('&cl=$_beaconClientId')
      ..write('&state=$state')
      ..write('&volume=100')
      ..write('&cbr=Chrome&cbrver=$_beaconCbrVer')
      ..write('&c=WEB_REMIX&cver=${clientVersion()}')
      ..write('&cplayer=UNIPLAYER&cos=X11&cplatform=DESKTOP')
      ..write('&hl=en_US&cr=US&uga=m18')
      ..write('&len=${_fmtSec(len)}')
      ..write('&rtn=$rtn&afmt=251&idpj=-8&ldpj=-16&rti=$rti')
      ..write('&st=${_fmtSec(startSec)}&et=${_fmtSec(currentSec)}')
      ..write('&muted=0&vis=10');
    _appendBeaconTail(out, ctx, videoId, playlistId);
    // final=1 on pause signals end-of-session so YT finalises the watch record.
    if (finalBeacon) out.write('&final=1');
    return out.toString();
  }

  /// Appends the identity/session tail (`docid`, `ei`, `plid`, `referrer`,
  /// `of`, `vm`).
  void _appendBeaconTail(
    StringBuffer out,
    WatchtimeContext ctx,
    String videoId,
    String? playlistId,
  ) {
    out.write('&docid=$videoId');
    out.write('&ei=${ctx.ei}');
    out.write('&plid=${ctx.plid}');
    if (playlistId != null && playlistId.isNotEmpty) {
      out.write(
        '&referrer=${Uri.encodeComponent('https://music.youtube.com/playlist?list=$playlistId')}',
      );
      out.write('&list=$playlistId');
    } else {
      out.write(
        '&referrer=${Uri.encodeComponent('https://music.youtube.com/watch?v=$videoId')}',
      );
    }
    out.write('&of=${ctx.of}');
    out.write('&vm=${ctx.vm}');
  }

  /// Authenticated beacons for stats/* endpoints. The YTM web client sends
  /// stats/playback and stats/watchtime as POST with JSON
  /// `{"session_token": <value>}` in the body, that, together with the
  /// player-minted ei/plid/of/vm session params, is what causes plays to
  /// be recorded in listening history.
  ///
  /// stats/* beacons return 204 as a *blind ack* for ALL well-formed
  /// requests, even anonymous ones. The server does not tell us whether
  /// the watch record was actually created. We MUST try every available
  /// auth candidate, not short-circuit on the first 204.
  Future<int> postBeacon(
    String url,
    String referer,
    String? sessionToken,
  ) async {
    AuthSession? provided;
    try {
      provided = await authProvider?.call();
    } catch (_) {
      provided = null;
    }
    final session = provided ?? auth;
    final cookieAuth = auth;
    final bearerAuth = session;

    final candidates = <AuthSession>[];
    // 1. Cookie + SAPISIDHASH (primary: web-client auth pattern).
    if ((cookieAuth.cookie ?? '').isNotEmpty) {
      candidates.add(cookieAuth);
    }
    // 2. Combined: Cookie + Bearer (no SAPISIDHASH, let server choose).
    if (!identical(cookieAuth, bearerAuth) &&
        (cookieAuth.cookie ?? '').isNotEmpty &&
        (bearerAuth.accessToken ?? '').isNotEmpty) {
      candidates.add(
        AuthSession(
          cookie: cookieAuth.cookie,
          accessToken: bearerAuth.accessToken,
        ),
      );
    }
    // 3. Bearer only (fallback for token-only sessions).
    if (!identical(cookieAuth, bearerAuth) &&
        (bearerAuth.cookie ?? '').isEmpty &&
        (bearerAuth.accessToken ?? '').isNotEmpty) {
      candidates.add(bearerAuth);
    }

    var lastStatus = -1;
    for (final candidate in candidates) {
      try {
        final int status;
        if (sessionToken != null && sessionToken.isNotEmpty) {
          final safeToken = sessionToken
              .replaceAll('\\', '\\\\')
              .replaceAll('"', '\\"');
          final headers = <String, String>{
            'User-Agent': _beaconUa,
            'Origin': _origin,
            'Referer': referer,
            'Content-Type': 'application/json',
          };
          final cookie = candidate.cookie;
          if (cookie != null && cookie.isNotEmpty) {
            headers['Cookie'] = cookie;
          }
          final sapisid = candidate.sapisidHash;
          final bearer = candidate.accessToken;
          if (sapisid != null && sapisid.isNotEmpty) {
            headers['Authorization'] = 'SAPISIDHASH $sapisid';
          } else if (bearer != null && bearer.isNotEmpty) {
            headers['Authorization'] = 'Bearer $bearer';
          }
          final res = await _dio
              .postUri<String>(
                Uri.parse(url),
                data: '{"session_token":"$safeToken"}',
                options: Options(headers: headers),
              )
              .timeout(const Duration(seconds: 30));
          status = res.statusCode ?? -1;
        } else {
          status = await _getBeaconStatus(url, referer, candidate);
        }
        if (status >= 200 && status < 300) lastStatus = status;
        // DO NOT return on first 204, it's a blind ack. Try ALL
        // candidates so a valid cookie session is always exercised even
        // when Bearer succeeds first.
      } catch (_) {}
    }
    return lastStatus;
  }

  /// Fallback GET beacon with SAPISIDHASH/Bearer header (204s but may not
  /// record history without session_token). Shared with [postBeacon].
  Future<int> _getBeaconStatus(
    String url,
    String referer,
    AuthSession candidate,
  ) async {
    final headers = <String, String>{
      'User-Agent': _beaconUa,
      'Origin': _origin,
      'Referer': referer,
    };
    final cookie = candidate.cookie;
    if (cookie != null && cookie.isNotEmpty) headers['Cookie'] = cookie;
    final sapisid = candidate.sapisidHash;
    final bearer = candidate.accessToken;
    if (sapisid != null && sapisid.isNotEmpty) {
      headers['Authorization'] = 'SAPISIDHASH $sapisid';
    } else if (bearer != null && bearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearer';
    }
    final res = await _dio
        .getUri<String>(Uri.parse(url), options: Options(headers: headers))
        .timeout(const Duration(seconds: 30));
    return res.statusCode ?? -1;
  }

  /// Authenticated GET pixel (ptracking). Best-effort: ignores status.
  Future<void> getBeacon(String url, String referer) async {
    AuthSession? provided;
    try {
      provided = await authProvider?.call();
    } catch (_) {
      provided = null;
    }
    final session = provided ?? auth;
    final candidates = <AuthSession>[];
    for (final candidate in [auth, session]) {
      if ((candidate.cookie ?? '').isEmpty &&
          (candidate.accessToken ?? '').isEmpty) {
        continue;
      }
      if (candidates.any(
        (c) =>
            c.cookie == candidate.cookie &&
            c.sapisidHash == candidate.sapisidHash &&
            c.accessToken == candidate.accessToken,
      )) {
        continue;
      }
      candidates.add(candidate);
    }
    for (final candidate in candidates) {
      try {
        final headers = <String, String>{
          'User-Agent': _beaconUa,
          'Origin': _origin,
          'Referer': referer,
        };
        final cookie = candidate.cookie;
        if (cookie != null && cookie.isNotEmpty) {
          headers['Cookie'] = cookie;
        }
        final sapisid = candidate.sapisidHash;
        final bearer = candidate.accessToken;
        if (sapisid != null && sapisid.isNotEmpty) {
          headers['Authorization'] = 'SAPISIDHASH $sapisid';
        } else if (bearer != null && bearer.isNotEmpty) {
          headers['Authorization'] = 'Bearer $bearer';
        }
        await _dio
            .getUri<String>(Uri.parse(url), options: Options(headers: headers))
            .timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
  }

  /// Fetches the `XSRF-TOKEN` session token from the YTM page HTML so stats
  /// beacons record listening history.
  Future<String?> fetchSessionToken() async {
    final cookie = auth.cookie;
    if (cookie == null) return null;
    try {
      final res = await _dio
          .getUri<String>(
            Uri.parse(_origin),
            options: Options(
              headers: {
                'User-Agent': _userAgent,
                'Cookie': cookie,
                'Accept-Language': 'en-US,en;q=0.5',
              },
            ),
          )
          .timeout(const Duration(seconds: 30));
      final m = RegExp(r'''["']XSRF_TOKEN["'\s]*:\s*["']([^"']+)["']''')
          .firstMatch(res.data ?? '');
      final token = m?.group(1);
      if (token == null || token.trim().isEmpty) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// True when the current session can actually read the library
  /// (stronger than account_menu, which is finicky about auth shape).
  /// Logs diagnostics to /tmp/nixietube-auth-debug.log, mirroring
  /// Kotlin `AuthDebug`.
  Future<bool> verifyLogin() async {
    try {
      final res = await post(
        'browse',
        _bodyWith({'browseId': 'FEmusic_library_landing'}),
      );
      if (res is Map && res.containsKey('error')) {
        _authDebugLog(
          'library: top-level error: '
          '${_clip(res.toString(), 200)}',
        );
        return false;
      }
      final blocks =
          findAll(res, 'musicShelfRenderer').length +
          findAll(res, 'musicCarouselShelfRenderer').length +
          findAll(res, 'gridRenderer').length;
      _authDebugLog('library: content blocks=$blocks');
      return blocks > 0;
    } catch (e) {
      _authDebugLog('library: exception ${_clip(e.toString(), 200)}');
      return false;
    }
  }

  /// Appends a timestamped line to the auth debug log.
  void _authDebugLog(String line) {
    try {
      File('/tmp/nixietube-auth-debug.log').writeAsStringSync(
        '${DateTime.now().toUtc().toIso8601String()} $line\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// First [n] characters of [s], for debug logging.
  static String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

  /// Returns the signed-in account name, or null when anonymous/failing.
  Future<String?> accountName() async {
    if (auth == const AuthSession.anonymous()) return null;
    try {
      final res = await post('account/account_menu', _contextBlock());
      for (final node in findAll(res, 'accountName')) {
        final text = runsText(nav(node, const ['runs']));
        if (text.trim().isNotEmpty) return text;
      }
      for (final node in findAll(res, 'accountName')) {
        final text = str(nav(node, const ['simpleText']));
        if (text != null && text.trim().isNotEmpty) return text;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
