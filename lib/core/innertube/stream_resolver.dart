// Stream URL resolution via the InnerTube player endpoint.
//
// The anonymous VISIONOS client comes first: its audio URLs need no
// deciphering and serve arbitrary byte ranges, so a normal track plays
// straight from the URL. When VISIONOS answers with a login or
// age-restriction status, the signed-in WEB_REMIX client is asked instead
// and its signatureCipher formats are solved with the JS challenge solver
// (see js_challenge_solver.dart); a format is never handed to the player
// while it is still encrypted. TVHTML5 and Android VR are the last
// resorts for restricted tracks the solver cannot read.
//
// Solving means satisfying challenges the player script defines, and the
// expensive half of that — parsing the 2.6 MB script — depends only on the
// player version. So the solver prefers the pre-solved script published
// for that version (player_presolver.dart, produced by
// tool/ejs_presolve.js) and downloads the raw script only when no
// pre-solved one is available.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';

import '../../sys/http_client.dart';
import '../../sys/log.dart';
import '../player/stream_proxy.dart';
import 'auth_session.dart';
import 'desktop_botguard.dart';
import 'js_challenge_solver.dart';
import 'json.dart';
import 'player_presolver.dart';
import 'po_token.dart';

/// Stream resolution diagnostics.
const _log = TaggedLog('stream');

const _visionosUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const _ytOrigin = 'https://www.youtube.com';
const _ytPlayer = 'https://www.youtube.com/youtubei/v1/player?alt=json';
const _musicPlayer = 'https://music.youtube.com/youtubei/v1/player?alt=json';

const _gateStatuses = {
  'LOGIN_REQUIRED',
  'AGE_VERIFICATION_REQUIRED',
  'AGE_CHECK_REQUIRED',
  'CONTENT_CHECK_REQUIRED',
};

class _PlayerClient {
  const _PlayerClient({
    required this.name,
    required this.id,
    required this.version,
    required this.userAgent,
    this.useMusicEndpoint = false,
    this.includeUserAgentInContext = false,
    this.osName,
    this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
    this.authenticated = false,
    this.useSignatureTimestamp = false,
    this.useCipherFallback = false,
    this.rangeLimited = false,
  });

  final String name;
  final String id;
  final String version;
  final String userAgent;
  final bool useMusicEndpoint;
  final bool includeUserAgentInContext;
  final String? osName;
  final String? osVersion;
  final String? deviceMake;
  final String? deviceModel;
  final String? androidSdkVersion;
  final bool authenticated;

  /// Whether the player response needs a `signatureTimestamp` from the
  /// watch page. Only the WEB clients do; sending one to a native client
  /// makes the request fail with an invalid-argument error.
  final bool useSignatureTimestamp;

  /// Whether formats that only carry a `signatureCipher` may be solved
  /// with the JS challenge solver instead of being skipped.
  final bool useCipherFallback;

  /// Whether this client's URLs refuse open-ended ranges and stop serving
  /// after about a megabyte, so they need the loopback proxy.
  final bool rangeLimited;
}

const _visionos = _PlayerClient(
  name: 'VISIONOS',
  id: '101',
  version: '1.02',
  userAgent: _visionosUserAgent,
  useMusicEndpoint: true,
  osName: 'visionOS',
  osVersion: '26.5.23O471',
  deviceMake: 'Apple',
  deviceModel: 'RealityDevice17,1',
);

const _androidVr165 = _PlayerClient(
  name: 'ANDROID_VR',
  id: '28',
  version: '1.65.10',
  userAgent:
      'com.google.android.apps.youtube.vr.oculus/1.65.10 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
  // The Android VR client is a YouTube client, not a Music one: the
  // music endpoint rejects it with HTTP 400, while youtube.com answers
  // with direct URLs (including age-restricted tracks).
  useMusicEndpoint: false,
  includeUserAgentInContext: true,
  osName: 'Android',
  osVersion: '12L',
  deviceMake: 'Oculus',
  deviceModel: 'Quest 3',
  androidSdkVersion: '32',
  // Carries the cookie session when one exists. A fallback for tracks
  // the solver cannot read: its direct URLs need no deciphering, but the
  // edge stops serving them after about a megabyte.
  authenticated: true,
  rangeLimited: true,
);

const _androidVr161 = _PlayerClient(
  name: 'ANDROID_VR',
  id: '28',
  version: '1.61.48',
  userAgent:
      'com.google.android.apps.youtube.vr.oculus/1.61.48 '
      '(Linux; U; Android 12; en_US; Quest 3; '
      'Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)',
  useMusicEndpoint: false,
  includeUserAgentInContext: true,
  osName: 'Android',
  osVersion: '12',
  deviceMake: 'Oculus',
  deviceModel: 'Quest 3',
  androidSdkVersion: '32',
  authenticated: true,
  rangeLimited: true,
);

/// The browser the WEB_REMIX player request and the PO-token watch page
/// present. The phone's solver WebView is set to it too, so the BotGuard
/// snapshot and the HTTP requests describe the same browser.
const webRemixUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
    'Gecko/20100101 Firefox/140.0';

const _webRemix = _PlayerClient(
  name: 'WEB_REMIX',
  id: '67',
  version: '1.20260707.12.00',
  userAgent: webRemixUserAgent,
  useMusicEndpoint: true,
  authenticated: true,
  useSignatureTimestamp: true,
  useCipherFallback: true,
  rangeLimited: true,
);

const _tvHtml5Downgraded = _PlayerClient(
  name: 'TVHTML5',
  id: '7',
  version: '5.20260707',
  userAgent: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
  includeUserAgentInContext: true,
  // A fallback for restricted tracks: TVHTML5 answers an open-ended
  // range with the rest of the track, so its URLs play in full.
  authenticated: true,
);

/// Direct audio stream URL plus metadata.
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.bitrate,
    this.codec,
    this.likes = -1,
    this.dislikes = -1,
    this.durationSec = 0,
    this.cacheable = true,
    this.rangeLimited = false,
  });

  final String url;
  final int bitrate;
  final String? codec;

  /// Whether this URL may be reused from cache. False for URLs minted by
  /// deciphering a `signatureCipher`: the signature/URL family is
  /// short-lived and replaying it minutes later is refused by the edge.
  final bool cacheable;

  /// Whether the edge refuses open-ended ranges on this URL and stops
  /// serving it after about a megabyte. Only those URLs need the loopback
  /// proxy; the VISIONOS URLs serve arbitrary ranges and play directly.
  final bool rangeLimited;

  /// Public like count, or -1 when unknown.
  final int likes;
  final int dislikes;

  /// Track length from the same player response, or 0 when absent. The
  /// player's `videoDetails` carries it, so a resolved track's queue row
  /// gets its length for free; that is the only source signed-out
  /// sessions have (list rows themselves never carry one).
  final int durationSec;
}

String? _codecOf(String mime) {
  final idx = mime.indexOf('codecs=');
  if (idx < 0) return null;
  var codecs = mime.substring(idx + 'codecs='.length).trim();
  codecs = codecs.replaceAll('"', '');
  final first = codecs.split(RegExp(r'[, ]')).firstOrNull;
  if (first == null || first.trim().isEmpty) return null;
  return first.trim();
}

/// A resolved stream plus the moment it expires from the cache.
class _CacheEntry {
  const _CacheEntry(this.stream, this.expiry);

  final ResolvedStream stream;
  final DateTime expiry;
}

/// Resolves direct audio stream URLs through the InnerTube player endpoint.
class StreamResolver {
  StreamResolver({
    Dio? dio,
    AuthSession auth = const AuthSession.anonymous(),
    String? cookie,
    this._authProvider,
    this.challengeSolver,
    this.presolvedPlayers,
  }) : _dio = dio ?? newHttpClient(),
       _auth = cookie == null
           ? auth
           : AuthSession(
               cookie: cookie,
               sapisidHash: auth.sapisidHash,
               accessToken: auth.accessToken,
               sessionToken: auth.sessionToken,
             );

  Dio _dio;

  AuthSession _auth;
  final AuthSession Function()? _authProvider;

  /// Solves signatureCipher / throttling challenges. Injectable for
  /// tests; defaults to the platform WebView solver.
  final ChallengeSolver? challengeSolver;
  ChallengeSolver? _jsSolver;

  /// The pre-solved player scripts this resolver fetches. Injectable for
  /// tests; defaults to the published branch, read through [_dio].
  final PresolvedPlayers? presolvedPlayers;
  PresolvedPlayers? _presolved;

  /// Mints the PO tokens that let a deciphered URL serve a whole track.
  PoTokenMinter? _poMinter;
  DesktopBotGuardRuntime? _botGuard;
  String? _poUserAgent;

  /// Updates the complete auth session used by authenticated player clients.
  set auth(AuthSession value) => _auth = value;

  /// Backwards-compatible cookie setter.
  set cookie(String? value) => _auth = AuthSession(
    cookie: value,
    sapisidHash: _auth.sapisidHash,
    accessToken: _auth.accessToken,
    sessionToken: _auth.sessionToken,
  );

  String? _visitor;

  /// The watch page's player bootstrap: the signature timestamp WEB_REMIX
  /// needs, the player version, and where its script lives. The script
  /// itself is only fetched when no pre-solved copy covers that version.
  String? _bootstrapPlayerId;
  String? _bootstrapJsPath;
  String? _bootstrapJs;
  int? _bootstrapSts;
  DateTime? _bootstrapAt;
  static const _bootstrapTtl = Duration(minutes: 30);

  /// When the cached visitor id was fetched. Visitor-bound stream URLs can
  /// die server-side well before their `expire` timestamp (the edge has
  /// returned 403 on minutes-old, IP-correct URLs), so the id is treated
  /// as perishable and re-fetched when older than [_visitorTtl].
  DateTime? _visitorAt;

  /// Maximum age of a cached visitor id before it is re-fetched.
  static const visitorTtl = Duration(minutes: 30);

  /// How long a resolved stream URL is reused before being re-resolved.
  /// Stream URLs can die server-side well before their `expire` timestamp,
  /// so the TTL is deliberately short.
  static const cacheTtl = Duration(minutes: 5);

  /// Cached resolved streams keyed by video id. Only successful resolves
  /// are stored; a track that currently resolves to null is retried fresh
  /// each time in case it becomes playable later.
  final Map<String, _CacheEntry> _cache = {};

  /// Releases the HTTP client. Call once at shutdown; in-flight
  /// requests fail fast instead of hanging on dispose.
  void close() {
    _dio.close();
    _poMinter?.close();
    _poMinter = null;
    unawaited(_botGuard?.close());
    _botGuard = null;
  }

  /// Drops all HTTP-side stream state the way an app restart would:
  /// pooled keepalive connections plus the cached visitor id. The next
  /// resolve refetches everything. Called when a stream-URL family
  /// keeps dying (edge 403s on fresh URLs), before surfacing an error.
  Future<void> reset() async {
    _visitor = null;
    _visitorAt = null;
    _cache.clear();
    _poMinter?.invalidate();
    // The pre-solver reads through this client, so it has to be replaced
    // together with it.
    _presolved = null;
    try {
      _dio.close();
    } catch (_) {}
    _dio = newHttpClient();
  }

  /// Forces the next resolve to mint URLs under a fresh visitor id.
  /// Called on every stream retry: retries that re-resolve under the same
  /// poisoned visitor just mint another dead URL family.
  Future<void> refreshVisitor() async {
    await _visitorData(true);
  }

  /// Fetches the cached visitor id ahead of the first resolve, so the
  /// first play does not wait on the YouTube homepage read that mints
  /// it. Fire-and-forget: failures are retried by the resolve path.
  void warmUp() {
    if (_visitor == null || _visitorAt == null) {
      unawaited(_visitorData(false));
    }
    // Warm the JS challenge solver too: its first desktop window takes
    // seconds to create, and the first age-restricted play should not pay
    // for that.
    final solver = _jsSolver ??= JsChallengeSolver();
    unawaited(solver.warmUp());
  }

  /// Cached visitor id, fetched from the YouTube homepage once. Stream URLs
  /// are bound to it; [refresh] re-fetches after a rejection (visitor ids
  /// rotate server-side).
  Future<String?> _visitorData(bool refresh) async {
    if (!refresh &&
        _visitor != null &&
        _visitorAt != null &&
        DateTime.now().difference(_visitorAt!) < visitorTtl) {
      return _visitor;
    }
    try {
      final res = await _dio
          .getUri<String>(
            Uri.parse(_ytOrigin),
            options: Options(headers: {'User-Agent': _visionosUserAgent}),
          )
          .timeout(const Duration(seconds: 30));
      final m = RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(res.data ?? '');
      final visitor = m?.group(1);
      if (visitor == null || visitor.isEmpty) return _visitor;
      _visitor = visitor;
      _visitorAt = DateTime.now();
      return visitor;
    } catch (_) {
      return _visitor;
    }
  }

  Future<dynamic> _playerRequest(
    String videoId,
    _PlayerClient client,
    String? visitor, {
    int? signatureTimestamp,
    String? poToken,
    String? userAgent,
  }) async {
    final clientContext = <String, dynamic>{
      'clientName': client.name,
      'clientVersion': client.version,
      'hl': 'en',
      'gl': 'US',
    };
    if (visitor != null && visitor.isNotEmpty) {
      clientContext['visitorData'] = visitor;
    }
    if (client.includeUserAgentInContext) {
      clientContext['userAgent'] = client.userAgent;
    }
    if (client.osName != null) clientContext['osName'] = client.osName;
    if (client.osVersion != null) clientContext['osVersion'] = client.osVersion;
    if (client.deviceMake != null) {
      clientContext['deviceMake'] = client.deviceMake;
    }
    if (client.deviceModel != null) {
      clientContext['deviceModel'] = client.deviceModel;
    }
    if (client.androidSdkVersion != null) {
      clientContext['androidSdkVersion'] = client.androidSdkVersion;
    }
    final body = <String, dynamic>{
      'context': {
        'client': clientContext,
        'user': client.authenticated && !_auth.isAnonymous
            ? const {'isSignedIn': true}
            : const <String, dynamic>{},
      },
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
      if (client.useSignatureTimestamp && signatureTimestamp != null)
        'playbackContext': {
          'contentPlaybackContext': {'signatureTimestamp': signatureTimestamp},
        },
      if (poToken != null && poToken.isNotEmpty)
        'serviceIntegrityDimensions': {'poToken': poToken},
      if (!client.useMusicEndpoint) 'videoCheckOk': true,
    };

    final origin = client.useMusicEndpoint
        ? 'https://music.youtube.com'
        : _ytOrigin;
    final endpoint = client.useMusicEndpoint ? _musicPlayer : _ytPlayer;
    final headers = <String, String>{
      'User-Agent': userAgent ?? client.userAgent,
      'X-YouTube-Client-Name': client.id,
      'X-YouTube-Client-Version': client.version,
      'X-Goog-Api-Format-Version': '1',
      'Origin': origin,
      'X-Origin': origin,
      'Referer': '$origin/',
      'Accept-Language': 'en-US,en;q=0.9',
      'Content-Type': 'application/json',
    };
    if (visitor != null && visitor.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = visitor;
    }
    if (client.authenticated) {
      if (_auth.cookie != null && _auth.cookie!.isNotEmpty) {
        headers['Cookie'] = _auth.cookie!;
      }
      headers['X-Goog-AuthUser'] = '0';
      if (_auth.sapisidHash != null && _auth.sapisidHash!.isNotEmpty) {
        headers['Authorization'] = 'SAPISIDHASH ${_auth.sapisidHash}';
      }
    }

    final res = await _dio
        .postUri<String>(
          Uri.parse(endpoint),
          data: jsonEncode(body),
          options: Options(headers: headers),
        )
        .timeout(const Duration(seconds: 30));
    final data = res.data ?? '';
    _log.d(
      'Player HTTP $videoId via ${client.name}/${client.version}: '
      'status=${res.statusCode} bytes=${data.length}',
    );
    return decodeJsonResponse(data);
  }

  Future<_PlayerBootstrap> _watchBootstrap(
    String videoId, {
    required bool authenticated,
  }) async {
    final headers = <String, String>{
      'User-Agent': _webRemix.userAgent,
      'Accept-Language': 'en-US,en;q=0.9',
    };
    if (authenticated && _auth.cookie != null && _auth.cookie!.isNotEmpty) {
      headers['Cookie'] = _auth.cookie!;
    }
    final cached = _bootstrapPlayerId;
    if (cached != null &&
        _bootstrapAt != null &&
        DateTime.now().difference(_bootstrapAt!) < _bootstrapTtl) {
      return _PlayerBootstrap(
        signatureTimestamp: _bootstrapSts,
        playerId: cached,
      );
    }
    try {
      final res = await _dio
          .getUri<String>(
            Uri.parse(
              '$_ytOrigin/watch'
              '?v=$videoId&bpctr=9999999999&has_verified=1',
            ),
            options: Options(headers: headers),
          )
          .timeout(const Duration(seconds: 30));
      final data = res.data ?? '';
      _log.d(
        'Watch bootstrap for $videoId: HTTP ${res.statusCode}, '
        '${data.length} bytes, authenticated=$authenticated',
      );
      int? timestamp = int.tryParse(
        RegExp(r'"signatureTimestamp"\s*:\s*(\d+)')
                .firstMatch(data)
                ?.group(1) ??
            '',
      );
      timestamp ??= int.tryParse(
        RegExp(r'\bsts\s*[:=]\s*(\d+)').firstMatch(data)?.group(1) ?? '',
      );
      // The page names the player script the whole site runs: one
      // version, whose challenges the solver can answer for every track.
      final jsPath = RegExp(r'/s/player/([^/\s"<>]+)/[^\s"<>]*base[.]js')
          .firstMatch(data);
      final playerId = jsPath?.group(1);
      final path = jsPath?.group(0);
      if (path != null && path.isNotEmpty) {
        // A rotated player invalidates the script kept for the old one:
        // challenges are per version, so a stale script would be wrong.
        if (playerId != null && playerId != _bootstrapPlayerId) {
          _bootstrapJs = null;
        }
        _bootstrapPlayerId = playerId;
        _bootstrapJsPath = path;
        _bootstrapAt = DateTime.now();
      } else if (timestamp == null) {
        _log.w('Watch bootstrap has no signatureTimestamp or player JS');
      }
      if (timestamp == null && path != null && path.isNotEmpty) {
        // The page carried no timestamp, so it lives in the script's own
        // bootstrap; reading it there leaves the script cached for the
        // solve that may follow.
        timestamp = await _signatureTimestampFromScript(
          authenticated: authenticated,
        );
      }
      if (timestamp != null) _bootstrapSts = timestamp;
      return _PlayerBootstrap(
        signatureTimestamp: timestamp ?? _bootstrapSts,
        playerId: playerId,
      );
    } catch (error) {
      _log.w('Watch bootstrap failed for $videoId: $error');
      return _PlayerBootstrap(
        signatureTimestamp: _bootstrapSts,
        playerId: _bootstrapPlayerId,
      );
    }
  }

  /// Reads `signatureTimestamp` out of the player script. Only used when
  /// the watch page did not carry one; the script stays cached for the
  /// solve that may follow.
  Future<int?> _signatureTimestampFromScript({
    required bool authenticated,
  }) async {
    final js = await _playerScript(authenticated: authenticated);
    if (js == null || js.isEmpty) return null;
    final match = RegExp(r'signatureTimestamp\s*[:=]\s*(\d+)').firstMatch(js);
    return int.tryParse(match?.group(1) ?? '');
  }

  /// The raw player script, downloaded on first need and kept for
  /// [_bootstrapTtl] like the rest of the bootstrap. Only the local solve
  /// path asks for it: a version with a published pre-solved script never
  /// pays for the 2.6 MB download.
  Future<String?> _playerScript({required bool authenticated}) async {
    final cached = _bootstrapJs;
    if (cached != null && cached.isNotEmpty) return cached;
    final path = _bootstrapJsPath;
    if (path == null || path.isEmpty) return null;
    final headers = <String, String>{
      'User-Agent': _webRemix.userAgent,
      'Accept-Language': 'en-US,en;q=0.9',
    };
    if (authenticated && _auth.cookie != null && _auth.cookie!.isNotEmpty) {
      headers['Cookie'] = _auth.cookie!;
    }
    try {
      final res = await _dio
          .getUri<String>(
            Uri.parse('$_ytOrigin$path'),
            options: Options(headers: headers),
          )
          .timeout(const Duration(seconds: 30));
      final js = res.data ?? '';
      _log.d('Player script ${res.statusCode}: ${js.length} bytes');
      if (js.isEmpty) return null;
      _bootstrapJs = js;
      return js;
    } catch (error) {
      _log.w('Player script download failed: $error');
      return null;
    }
  }

  /// The pre-solved script published for [playerId], or null when none is.
  Future<String?> _presolvedFor(String? playerId) async {
    if (playerId == null || playerId.isEmpty) return null;
    try {
      final presolved = _presolved ??=
          presolvedPlayers ?? PresolvedPlayers(dio: _dio);
      return await presolved.fetch(playerId);
    } catch (error) {
      _log.d('pre-solved player lookup failed: $error');
      return null;
    }
  }

  /// What the solver should run for [bootstrap]: the published pre-solved
  /// script when there is one, else the raw script. Null when neither is
  /// available, which leaves the formats that need a challenge unplayable.
  Future<_ChallengeSource?> _challenges(
    _PlayerBootstrap bootstrap, {
    required bool authenticated,
  }) async {
    final presolved = await _presolvedFor(bootstrap.playerId);
    if (presolved != null && presolved.isNotEmpty) {
      return _ChallengeSource(
        preprocessed: presolved,
        playerId: bootstrap.playerId,
      );
    }
    final js = await _playerScript(authenticated: authenticated);
    if (js == null || js.isEmpty) return null;
    return _ChallengeSource(playerJs: js, playerId: bootstrap.playerId);
  }

  /// Resolves the highest-bitrate direct audio URL for [videoId], or null
  /// when nothing playable is offered.
  ///
  /// The anonymous VISIONOS client comes first, signed in or not: its
  /// audio URLs need no deciphering and serve arbitrary byte ranges, so a
  /// normal track plays straight from the URL. Only when VISIONOS answers
  /// with a login or age-restriction status does the resolver take the
  /// authenticated WEB_REMIX route and solve that client's signature and
  /// throttling challenges with the JS solver.
  ///
  /// [proxy] wraps range-limited URLs in the loopback proxy (the default).
  /// [force] bypasses the cache; the proxy uses it when it needs a fresh
  /// raw URL after the edge's per-URL budget runs out.
  Future<ResolvedStream?> resolve(
    String videoId, {
    bool proxy = true,
    bool force = false,
  }) async {
    final entry = _cache[videoId];
    if (!force &&
        entry != null &&
        entry.stream.cacheable &&
        DateTime.now().isBefore(entry.expiry)) {
      // The cache keeps the URL the player request minted, not the loopback
      // one the engine plays: finishing it here is what makes a cached
      // stream as playable as a freshly resolved one. Handing the raw URL
      // back instead skips the proxy, and a range-limited URL opens, plays
      // a fraction of a second and then stalls — every skip served from
      // this cache played the wrong thing or nothing at all.
      return await _finish(videoId, entry.stream, proxy);
    }

    final provider = _authProvider;
    if (provider != null) {
      _auth = provider();
    }
    _log.d(
      'Resolve auth for $videoId: '
      'cookie=${_auth.cookie != null && _auth.cookie!.isNotEmpty} '
      'sapisidHash=${_auth.sapisidHash != null && _auth.sapisidHash!.isNotEmpty} '
      'bearer=${_auth.accessToken != null && _auth.accessToken!.isNotEmpty}',
    );

    final visitor = await _visitorData(false);
    final anonymous = await _resolveClient(videoId, _visionos, visitor);
    if (anonymous != null) {
      _rememberStream(videoId, anonymous);
      return await _finish(videoId, anonymous, proxy);
    }
    final hasCookie = _auth.cookie != null && _auth.cookie!.isNotEmpty;
    if (hasCookie) {
      // Age-restricted music: WEB_REMIX answers with signatureCipher
      // only. Solving it needs the watch page's player version and
      // signature timestamp; both are cached across tracks. The PO
      // tokens are what let the deciphered URL serve the whole track.
      final bootstrap = await _watchBootstrap(videoId, authenticated: true);
      final tokens = await _mintPoTokens(videoId, visitor);
      final solved = await _resolveClient(
        videoId,
        _webRemix,
        visitor,
        signatureTimestamp: bootstrap.signatureTimestamp,
        challenges: () => _challenges(bootstrap, authenticated: true),
        poToken: tokens?.playerRequest,
        streamToken: tokens?.streamingData,
        userAgent: tokens == null ? null : _poUserAgent,
      );
      if (solved != null) {
        _rememberStream(videoId, solved);
        return await _finish(videoId, solved, proxy);
      }
      // The cookie session's other clients, for tracks WEB_REMIX refuses
      // or the solver cannot read. Their URLs are range-limited too.
      for (final client in const [
        _tvHtml5Downgraded,
        _androidVr165,
        _androidVr161,
      ]) {
        final stream = await _resolveClient(videoId, client, visitor);
        if (stream != null) {
          _rememberStream(videoId, stream);
          return await _finish(videoId, stream, proxy);
        }
      }
    } else {
      // Signed out there is no session to solve ciphers with; the Android
      // VR clients still serve part of the public catalogue directly.
      for (final client in const [_androidVr165, _androidVr161]) {
        final stream = await _resolveClient(videoId, client, visitor);
        if (stream != null) {
          _rememberStream(videoId, stream);
          return await _finish(videoId, stream, proxy);
        }
      }
    }
    _log.w('No playable stream for $videoId');
    return null;
  }

  void _logFormatShape(
    String videoId,
    _PlayerClient client,
    Map<dynamic, dynamic> res,
  ) {
    final streaming = res['streamingData'];
    if (streaming is! Map) {
      final error = res['error'];
      if (error is Map) {
        _log.w(
          'Player error for $videoId via ${client.name}/${client.version}: '
          '${error['code'] ?? '(no code)'} ${error['message'] ?? ''}',
        );
      } else {
        _log.w(
          'Player response for $videoId via ${client.name}/${client.version} '
          'has no streamingData',
        );
      }
      return;
    }

    var direct = 0;
    var cipher = 0;
    var audio = 0;
    for (final key in const ['adaptiveFormats', 'formats']) {
      final formats = streaming[key];
      if (formats is! List) continue;
      for (final format in formats) {
        if (format is! Map) continue;
        final mime = str(format['mimeType']) ?? '';
        if (!mime.startsWith('audio/')) continue;
        audio++;
        if (format['url'] is String && (format['url'] as String).isNotEmpty) {
          direct++;
        }
        if (format['signatureCipher'] is String) cipher++;
      }
    }
    final hls =
        streaming['hlsManifestUrl'] is String &&
        (streaming['hlsManifestUrl'] as String).isNotEmpty;
    final sabr =
        streaming['serverAbrStreamingUrl'] is String &&
        (streaming['serverAbrStreamingUrl'] as String).isNotEmpty;
    _log.d(
      'Stream shape for $videoId via ${client.name}/${client.version}: '
      'audio=$audio direct=$direct cipher=$cipher hls=$hls sabr=$sabr',
    );
  }

  /// Mints the PO tokens the WEB_REMIX route needs, or null when the
  /// BotGuard engine is unavailable. Best-effort: without a token the
  /// deciphered URL still plays its first megabyte.
  Future<PoTokenPair?> _mintPoTokens(String videoId, String? visitor) async {
    if (visitor == null || visitor.isEmpty) return null;
    try {
      final userAgent = await _botGuardUserAgent();
      final minter = _poMinter ??= PoTokenMinter(
        evaluate: _botGuardEval,
        userAgent: userAgent,
      );
      return await minter.mint(
        videoId: videoId,
        visitorData: visitor,
        cookie: _auth.cookie,
      );
    } catch (error) {
      _log.w('PO token unavailable for $videoId: $error');
      return null;
    }
  }

  /// The browser the BotGuard document reports. Its snapshot describes
  /// that browser, so the watch page and the player request must present
  /// the same one. Phones run the solver WebView with [webRemixUserAgent].
  Future<String> _botGuardUserAgent() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return _poUserAgent = webRemixUserAgent;
    }
    final cached = _poUserAgent;
    if (cached != null) return cached;
    final reported = await _botGuardEval('navigator.userAgent');
    final trimmed = reported.replaceAll('"', '').trim();
    return _poUserAgent = trimmed.isEmpty ? webRemixUserAgent : trimmed;
  }

  Future<String> _botGuardEval(String script) {
    if (Platform.isAndroid || Platform.isIOS) {
      final hook = webviewSolveHook;
      if (hook == null) {
        throw const PoTokenException('solver WebView is not ready');
      }
      return hook(script);
    }
    return (_botGuard ??= DesktopBotGuardRuntime()).evaluate(script);
  }

  Future<ResolvedStream?> _resolveClient(
    String videoId,
    _PlayerClient client,
    String? visitor, {
    int? signatureTimestamp,
    Future<_ChallengeSource?> Function()? challenges,
    String? poToken,
    String? streamToken,
    String? userAgent,
  }) async {
    dynamic res;
    for (final refresh in [false, true]) {
      final requestVisitor = await _visitorData(refresh);
      try {
        res = await _playerRequest(
          videoId,
          client,
          requestVisitor,
          signatureTimestamp: signatureTimestamp,
          poToken: poToken,
          userAgent: userAgent,
        );
      } catch (error) {
        _log.w(
          'Player request failed for $videoId via '
          '${client.name}/${client.version}: $error',
        );
        res = null;
      }
      final status = str(nav(res, const ['playabilityStatus', 'status']));
      if (status != null) {
        final reason =
            str(nav(res, const ['playabilityStatus', 'reason'])) ?? '';
        _log.d(
          'Player response for $videoId via ${client.name}/${client.version}: '
          'status=$status reason=${reason.isEmpty ? '(none)' : reason}',
        );
      }
      if (res is Map) {
        _logFormatShape(videoId, client, res);
      }
      if (status == 'OK') break;
      res = null;
      if (refresh || _gateStatuses.contains(status)) break;
    }
    if (res == null) return null;
    final stream = client.useCipherFallback
        ? await _streamFromWithCiphers(res, challenges)
        : _streamFrom(res);
    if (stream == null) return null;
    _log.i(
      'Resolved stream for $videoId via ${client.name} '
      '${client.version}: ${stream.bitrate} bps',
    );
    // A PO token lifts the edge's megabyte ceiling: the URL answers an
    // open-ended range with the whole track. It is still range-limited as
    // far as the player goes, because the tokenized URL is a deciphered
    // one: handing that to a platform engine is what 403s on the first
    // request, while the same URL answers the proxy's own request.
    final tokenized = streamToken != null && streamToken.isNotEmpty;
    if (tokenized && stream.codec != 'hls') {
      return ResolvedStream(
        url: _appendQuery(stream.url, 'pot', streamToken),
        bitrate: stream.bitrate,
        codec: stream.codec,
        likes: stream.likes,
        dislikes: stream.dislikes,
        durationSec: stream.durationSec,
        cacheable: stream.cacheable,
        rangeLimited: client.rangeLimited,
      );
    }
    if (!client.rangeLimited) return stream;
    return ResolvedStream(
      url: stream.url,
      bitrate: stream.bitrate,
      codec: stream.codec,
      likes: stream.likes,
      dislikes: stream.dislikes,
      durationSec: stream.durationSec,
      cacheable: stream.cacheable,
      rangeLimited: true,
    );
  }

  /// Applies the loopback proxy to range-limited URLs (when [proxy] is
  /// set) and returns the stream to hand to the engine.
  ///
  /// While the audio cache is on, every stream goes through the proxy even
  /// when its URL serves ranges directly: the cache only sees what the
  /// proxy relays, and a loopback URL stays valid for the whole track
  /// instead of expiring with the signed one underneath it.
  Future<ResolvedStream?> _finish(
    String videoId,
    ResolvedStream? stream,
    bool proxy,
  ) async {
    if (stream == null) return null;
    final cached = StreamProxy.instance.servesCache;
    final wanted =
        proxy && stream.codec != 'hls' && (stream.rangeLimited || cached);
    if (!wanted) {
      _log.d('stream for $videoId: ${_shapeOf(stream.url)}');
      return stream;
    }
    final proxied = await _proxyStream(stream, videoId);
    if (proxied != null) {
      _log.d('stream for $videoId: ${_shapeOf(proxied.url)}');
    }
    return proxied;
  }

  /// What a resolved URL carries, for the log: the host, and whether the
  /// signature, the `n` challenge and the PO token made it onto the URL.
  ///
  /// Their values stay out of the log, but their presence is what separates
  /// a URL the edge refuses (403 on the first request) from one that never
  /// got its answers, and a `loopback` here says the proxy will absorb the
  /// refusal itself.
  static String _shapeOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'unparseable';
    if (uri.host == '127.0.0.1') return 'loopback';
    final params = uri.queryParameters;
    bool has(String name) => (params[name] ?? '').isNotEmpty;
    return 'host=${uri.host} sig=${has('sig')} n=${has('n')} pot=${has('pot')}';
  }

  /// Routes a range-limited googlevideo URL through the loopback proxy.
  /// Those URLs refuse an open-ended range, so the engines that open one
  /// (mpv, and ExoPlayer on some builds) get a 403; the proxy asks for
  /// bounded chunks instead and re-resolves when the edge's per-URL
  /// budget runs out.
  Future<ResolvedStream?> _proxyStream(
    ResolvedStream? stream,
    String videoId,
  ) async {
    if (stream == null) return null;
    final uri = Uri.tryParse(stream.url);
    if (uri == null || !uri.host.endsWith('.googlevideo.com')) return stream;
    try {
      final playable = await StreamProxy.instance.wrap(
        stream.url,
        videoId: videoId,
      );
      return ResolvedStream(
        url: playable,
        bitrate: stream.bitrate,
        codec: stream.codec,
        likes: stream.likes,
        dislikes: stream.dislikes,
        durationSec: stream.durationSec,
        cacheable: stream.cacheable,
      );
    } catch (error) {
      _log.w('stream proxy unavailable: $error');
      return stream;
    }
  }

  /// Picks the highest-bitrate direct audio URL from a player response.
  ResolvedStream? _streamFrom(dynamic res) {
    final length = _lengthOf(res);
    final direct = <ResolvedStream>[];
    for (final key in ['adaptiveFormats', 'formats']) {
      final formats = nav(res, ['streamingData', key]);
      if (formats is! List) continue;
      for (final format in formats) {
        if (format is! Map) continue;
        final mime = str(format['mimeType']) ?? '';
        if (!mime.startsWith('audio/')) continue;
        final url = str(format['url']);
        if (url == null || url.isEmpty) continue;
        final bitrate = format['bitrate'] is int ? format['bitrate'] as int : 0;
        direct.add(
          ResolvedStream(
            url: url,
            bitrate: bitrate,
            codec: _codecOf(mime),
            durationSec: length ?? 0,
          ),
        );
      }
    }
    return _bestStream(direct) ?? _hlsStream(res, length);
  }

  /// Same as [_streamFrom], but solves `signatureCipher` formats with the
  /// JS challenge solver. Direct URLs are still preferred when present.
  ///
  /// Age-restricted music is answered by WEB_REMIX with cipher-only
  /// formats: each carries `s` (the signature challenge), `sp` (the
  /// query name for the solved signature, usually `sig`) and the base
  /// `url`. The URL's `n` parameter is the throttling challenge. All
  /// challenges are solved in one solver call; the resulting URLs are
  /// ranked by bitrate. A solver failure fails closed (the formats are
  /// skipped, not handed to the player encrypted).
  ///
  /// [challenges] is only awaited when the response actually asks for a
  /// challenge: it may have to fetch the player script (or the pre-solved
  /// copy of it), and a response that needs neither must not pay for it.
  Future<ResolvedStream?> _streamFromWithCiphers(
    dynamic res,
    Future<_ChallengeSource?> Function()? challenges,
  ) async {
    final length = _lengthOf(res);
    final direct = <ResolvedStream>[];
    final ciphered = <_CipherFormat>[];
    for (final key in ['adaptiveFormats', 'formats']) {
      final formats = nav(res, ['streamingData', key]);
      if (formats is! List) continue;
      for (final format in formats) {
        if (format is! Map) continue;
        final mime = str(format['mimeType']) ?? '';
        if (!mime.startsWith('audio/')) continue;
        final bitrate = format['bitrate'] is int ? format['bitrate'] as int : 0;
        final url = str(format['url']);
        if (url != null && url.isNotEmpty) {
          direct.add(
            ResolvedStream(
              url: url,
              bitrate: bitrate,
              codec: _codecOf(mime),
              durationSec: length ?? 0,
            ),
          );
          continue;
        }
        final cipher = str(format['signatureCipher']);
        if (cipher == null || cipher.isEmpty) continue;
        final params = Uri.splitQueryString(cipher);
        final challenge = params['s'];
        final baseUrl = params['url'];
        final sp = params['sp'];
        if (challenge == null ||
            challenge.isEmpty ||
            baseUrl == null ||
            baseUrl.isEmpty) {
          continue;
        }
        ciphered.add(
          _CipherFormat(
            baseUrl: baseUrl,
            sigParam: (sp != null && sp.isNotEmpty) ? sp : 'sig',
            challenge: challenge,
            bitrate: bitrate,
            codec: _codecOf(mime),
            durationSec: length ?? 0,
          ),
        );
      }
    }

    // Throttling challenges from both the ciphered and the direct URLs:
    // the solver call is already happening, so fixing `n` is free.
    final nChallenges = <String>{};
    for (final stream in direct) {
      final n = Uri.tryParse(stream.url)?.queryParameters['n'];
      if (n != null && n.isNotEmpty) nChallenges.add(n);
    }
    for (final format in ciphered) {
      final n = Uri.tryParse(format.baseUrl)?.queryParameters['n'];
      if (n != null && n.isNotEmpty) nChallenges.add(n);
    }
    if ((ciphered.isEmpty && nChallenges.isEmpty) || challenges == null) {
      return _bestStream(direct) ?? _hlsStream(res, length);
    }

    final source = await challenges();
    if (source == null) {
      _log.w('No player script to solve this response with');
      return _bestStream(direct) ?? _hlsStream(res, length);
    }
    final solver = challengeSolver ?? (_jsSolver ??= JsChallengeSolver());
    Map<String, String> solved;
    try {
      solved = await solver.solve(
        playerId: source.playerId,
        playerJs: source.playerJs,
        preprocessedPlayer: source.preprocessed,
        sigChallenges: [for (final format in ciphered) format.challenge],
        nChallenges: nChallenges.toList(),
      );
    } catch (error) {
      _log.w('Cipher solve failed for a WEB_REMIX response: $error');
      return _bestStream(direct) ?? _hlsStream(res, length);
    }

    for (final format in ciphered) {
      final sig = solved[format.challenge];
      if (sig == null || sig.isEmpty) continue;
      final url = _appendQuery(
        _replaceQueryIfSolved(format.baseUrl, 'n', solved),
        format.sigParam,
        sig,
      );
      direct.add(
        ResolvedStream(
          url: url,
          bitrate: format.bitrate,
          codec: format.codec,
          durationSec: format.durationSec,
          // Deciphered URLs are single-use-ish: never serve them from
          // the cache, or a replay minutes later gets a 403.
          cacheable: false,
        ),
      );
    }
    for (var i = 0; i < direct.length; i++) {
      final stream = direct[i];
      final fixed = _replaceQueryIfSolved(stream.url, 'n', solved);
      if (fixed != stream.url) {
        direct[i] = ResolvedStream(
          url: fixed,
          bitrate: stream.bitrate,
          codec: stream.codec,
          durationSec: stream.durationSec,
        );
      }
    }
    return _bestStream(direct) ?? _hlsStream(res, length);
  }

  int? _lengthOf(dynamic res) => int.tryParse(
    str(nav(res, const ['videoDetails', 'lengthSeconds'])) ?? '',
  );

  /// Caches [stream] for [videoId] unless it was minted by deciphering a
  /// signatureCipher (see [ResolvedStream.cacheable]).
  void _rememberStream(String videoId, ResolvedStream stream) {
    if (!stream.cacheable) return;
    _cache[videoId] = _CacheEntry(stream, DateTime.now().add(cacheTtl));
  }

  ResolvedStream? _bestStream(List<ResolvedStream> streams) {
    ResolvedStream? best;
    for (final stream in streams) {
      if (best != null && best.bitrate >= stream.bitrate) continue;
      best = stream;
    }
    return best;
  }

  ResolvedStream? _hlsStream(dynamic res, int? length) {
    final hls = str(nav(res, const ['streamingData', 'hlsManifestUrl']));
    if (hls == null || hls.isEmpty) return null;
    return ResolvedStream(
      url: hls,
      bitrate: 0,
      codec: 'hls',
      durationSec: length ?? 0,
    );
  }

  /// Replaces the `n` query parameter when the solver answered it.
  String _replaceQueryIfSolved(
    String url,
    String name,
    Map<String, String> solved,
  ) {
    final uri = Uri.tryParse(url);
    final challenge = uri?.queryParameters[name];
    if (uri == null || challenge == null || challenge.isEmpty) return url;
    final value = solved[challenge];
    if (value == null || value.isEmpty) return url;
    final params = Map<String, String>.of(uri.queryParameters)..[name] = value;
    return uri.replace(queryParameters: params).toString();
  }

  /// Adds [name]=[value] to [url].
  String _appendQuery(String url, String name, String value) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final params = Map<String, String>.of(uri.queryParameters)..[name] = value;
    return uri.replace(queryParameters: params).toString();
  }
}

/// One audio format whose URL is only available as a signature cipher.
class _CipherFormat {
  const _CipherFormat({
    required this.baseUrl,
    required this.sigParam,
    required this.challenge,
    required this.bitrate,
    required this.codec,
    required this.durationSec,
  });

  final String baseUrl;
  final String sigParam;
  final String challenge;
  final int bitrate;
  final String? codec;
  final int durationSec;
}

/// The watch page's player bootstrap: the signature timestamp WEB_REMIX
/// needs, plus the version and path of the player script the site runs.
class _PlayerBootstrap {
  const _PlayerBootstrap({this.signatureTimestamp, this.playerId});

  final int? signatureTimestamp;

  /// The player version the watch page named, which is what the published
  /// pre-solved scripts are keyed by.
  final String? playerId;
}

/// What the challenge solver should run for one player version: the
/// pre-solved script published for it, or the raw script as a fallback.
class _ChallengeSource {
  const _ChallengeSource({this.playerId, this.preprocessed, this.playerJs});

  /// The player version both scripts belong to. The solver keeps its
  /// compiled pre-solved script in the engine under this key, so a repeat
  /// solve for the same version ships only the challenges.
  final String? playerId;

  /// A script produced by the AST pass, answered without redoing it.
  final String? preprocessed;

  /// The raw player script, which needs the AST pass on this device.
  final String? playerJs;
}
