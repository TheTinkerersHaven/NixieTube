// Last.fm scrobbling over the ws.audioscrobbler.com API: session auth
// (request token approved in the browser),
// MD5-signed calls, now-playing updates on track start, and scrobbles once
// the standard playback threshold is reached (half the track or 4 minutes,
// tracks over 30 seconds). Credentials live in [SysConfig]; nothing is sent
// when disabled or logged out.

import 'dart:convert' show jsonDecode, utf8;

import 'package:crypto/crypto.dart' show md5;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../core/models/models.dart' show Track;
import '../core/player/player_state.dart' show PlayerState;
import 'http_client.dart' show newResilientClient;
import 'sys_config.dart' show SysConfig;

/// Last.fm API endpoint for all signed calls.
const lastfmApiUrl = 'https://ws.audioscrobbler.com/2.0/';

/// Browser URL where the user approves a request token.
const lastfmAuthUrl = 'https://www.last.fm/api/auth/';

/// Built-in shared Last.fm API credentials, used whenever the settings
/// fields are left empty so connecting needs no last.fm/api application
/// of your own. A custom key/secret in Settings always overrides these.
/// The secret lives in the binary like in every client that ships one —
/// acceptable for a free non-commercial app, and the override is there
/// if this key is ever revoked or rate-limited.
const defaultLastfmApiKey = '38d8a6ea0a40c47f428cbe7b887480f4';
const defaultLastfmSecret = '0dc85259b68c9164d18b490b04812857';

/// Minimum track length worth scrobbling, in seconds (Last.fm rule).
const minScrobbleDurationSec = 30;

/// Scrobble once playback passes this many seconds regardless of track length.
const scrobbleCapSec = 240;

/// Backward seek that counts as a restarted play rather than a position update.
const seekBackToleranceMs = 2000;

/// Max characters of an error message kept in status text.
const _errorSnippetLen = 80;

/// User-Agent sent with Last.fm API calls.
const _lastfmUserAgent = 'NixieTube/1.0';

/// One play's scrobble bookkeeping, reset on every new track or restart.
class ScrobbleProgress {
  String? videoId;
  int startEpochSec = 0;
  int lastPositionMs = 0;
  bool scrobbled = false;
}

/// Primary artist name: only the first artist goes to the scrobbler. Falls
/// back to the joined credit line (which is empty for an unlinked track).
String lastfmArtistName(Track track) {
  for (final a in track.artists) {
    if (a.name.trim().isNotEmpty) return a.name;
  }
  return track.artistNames();
}

/// Matches a "feat. X" / "ft. X" / "featuring X" / "w/ X" credit clause,
/// optionally wrapped in `()`/`[]`, anywhere in a title. Used for
/// feature-credit stripping.
final _featureCreditRe = RegExp(
  r'''\s*[\(\[]?(?:feat\.?|ft\.?|featuring|w/)\s+[^)\]]+[\)\]]?''',
  caseSensitive: false,
);

/// Strips featuring credits from [title] so Last.fm receives the clean
/// release title ("Song (feat. Artist)" → "Song").
String cleanScrobbleTitle(String title) =>
    title.replaceAll(_featureCreditRe, '').trim();

/// Playback-noise check for bracketed title tags: an optional run of
/// filler words ("Official Music") in front of a noise keyword.
final _videoNoiseRe = RegExp(
  r'(?:(?:official|music|player)\s+)*(?:video|audio|lyrics?|visualizer|mv|m/v|2k|4k|hd|hq)\b',
  caseSensitive: false,
);

/// Removes trailing bracketed playback-noise tags from a track title so
/// YouTube variants ("Engravings (Official Video)") resolve to the Last.fm
/// release ("Engravings"). Musical versions (Remaster, Live…) stay — the
/// search fallback handles those when the direct lookup misses.
String cleanInfoTitle(String title) {
  var t = title.trim();
  while (true) {
    final m = RegExp(r'[(\[]([^)\]]+)[)\]]$').firstMatch(t);
    if (m == null || !_videoNoiseRe.hasMatch(m.group(1)!)) break;
    t = t.substring(0, m.start).trim();
  }
  return t;
}

/// Last.fm client: web-auth handshake, now-playing updates, and scrobbles.
///
/// API key/secret come from Settings, falling back to the bundled
/// [defaultLastfmApiKey]/[defaultLastfmSecret] when the fields are left
/// empty; the session key persists in [SysConfig] after the browser
/// approval. All network use is opt-in via `SysConfig.lastfmEnabled`.
/// A [ChangeNotifier] so the Settings card can watch [status].
class LastFmService extends ChangeNotifier {
  LastFmService({required SysConfig config, Dio? dio}) {
    _config = config;
    _dio = dio ?? newResilientClient();
    refreshStatus();
  }

  late final SysConfig _config;
  late final Dio _dio;

  final ScrobbleProgress _progress = ScrobbleProgress();

  String _status = 'disabled';

  /// Human-readable state: "disabled", "signed in as …", "signed out",
  /// or "error: …".
  String get status => _status;

  /// Currently linked Last.fm username, or empty when logged out.
  String get username => _config.lastfmUsername;

  /// Effective API key: the Settings value, or the bundled shared
  /// credentials when the field is empty.
  String get _apiKey {
    final custom = _config.lastfmApiKey.trim();
    return custom.isEmpty ? defaultLastfmApiKey : custom;
  }

  /// Effective shared secret: same fallback rule as [_apiKey].
  String get _secret {
    final custom = _config.lastfmSecret.trim();
    return custom.isEmpty ? defaultLastfmSecret : custom;
  }

  /// True when scrobbling can run: enabled and holding a session. The
  /// key is always effectively present via the built-in fallback.
  bool ready() =>
      _config.lastfmEnabled && _config.lastfmSessionKey.trim().isNotEmpty;

  /// Fetches Last.fm metadata (tags, playcount, listeners, album, wiki)
  /// for a track. The direct auto-corrected `track.getInfo` lookup runs
  /// first; when it misses, a `track.search` fallback picks the closest
  /// entry (scored by artist/title likeness and [durationSec]) and looks
  /// it up by MBID. Returns null on failure or when nothing close enough
  /// is found — wrong-track data is worse than no data.
  Future<Map<String, dynamic>?> trackInfo(
    String artist,
    String title, {
    int durationSec = 0,
  }) async {
    if (_blank(artist) || _blank(title)) return null;
    // Feature credits first (anywhere in the title), then trailing
    // playback-noise tags — mirrors the scrobble-title cleaning.
    final clean = cleanInfoTitle(cleanScrobbleTitle(title));
    try {
      final direct = await _callPublic('track.getInfo', {
        'artist': artist,
        'track': clean,
        'autocorrect': '1',
      }, root: 'track');
      if (direct != null) return direct;
      final best = await _searchBestTrack(
        artist,
        clean,
        durationSec: durationSec,
      );
      if (best == null) return null;
      final mbid = best['mbid'];
      if (mbid is String && mbid.isNotEmpty) return await _byMbid(best);
      return await _byCandidate(best);
    } catch (_) {
      return null;
    }
  }

  /// Looks a search hit up by its MBID.
  Future<Map<String, dynamic>?> _byMbid(Map best) => _callPublic(
    'track.getInfo',
    {'mbid': best['mbid'] as String, 'autocorrect': '1'},
    root: 'track',
  );

  /// Looks a search hit up by its own artist and title, or null when
  /// either is missing.
  Future<Map<String, dynamic>?> _byCandidate(Map best) async {
    final artist = best['artist'];
    final title = best['name'];
    if (artist is! String || _blank(artist)) return null;
    if (title is! String || _blank(title)) return null;
    return _callPublic('track.getInfo', {
      'artist': artist,
      'track': title,
      'autocorrect': '1',
    }, root: 'track');
  }

  /// The artist's most-voted tags (artist.getTopTags). Used as the genre
  /// fallback when a track itself carries none in `track.getInfo`. Empty
  /// list on failure or when the artist is unknown.
  Future<List<String>> artistTags(String artist, {int limit = 10}) async {
    if (_blank(artist)) return [];
    try {
      final root = await _callPublic('artist.getTopTags', {
        'artist': artist,
        'autocorrect': '1',
        'limit': '$limit',
      }, root: 'toptags');
      final tags = <String>[];
      if (root != null) {
        final tag = root['tag'];
        if (tag is List) {
          for (final t in tag) {
            if (t is Map && t['name'] is String) {
              tags.add(t['name'] as String);
            }
          }
        }
      }
      return tags;
    } catch (_) {
      return [];
    }
  }

  /// Fetches Last.fm metadata for an album (album.getInfo): its wiki
  /// summary, release year, and tag list. Returns null on failure or
  /// when the album is unknown.
  Future<Map<String, dynamic>?> albumInfo(
    String artist,
    String album, {
    String? mbid,
  }) async {
    if (_blank(artist) || _blank(album)) return null;
    try {
      final params = <String, String>{
        'artist': artist,
        'album': album,
        'autocorrect': '1',
        if (mbid != null && mbid.isNotEmpty) 'mbid': mbid,
      };
      final root = await _callPublic('album.getInfo', params, root: 'album');
      if (root == null) return null;
      return root;
    } catch (_) {
      return null;
    }
  }

  /// GETs [method] and returns [root]'s object from the decoded JSON body,
  /// or null when Last.fm says "not found" (`error` field or empty [root]).
  Future<Map<String, dynamic>?> _callPublic(
    String method,
    Map<String, String> params, {
    required String root,
  }) async {
    final res = await _dio.get(
      lastfmApiUrl,
      queryParameters: {
        'method': method,
        'api_key': _apiKey,
        ...params,
        'format': 'json',
      },
    );
    final data = _decodeBody(res.data);
    if (data == null || data['error'] != null) return null;
    final obj = data[root];
    return obj is Map ? Map<String, dynamic>.from(obj) : null;
  }

  /// Picks the closest `track.search` hit: artist and title likeness plus
  /// a duration check give the score; anything below [minScore] is
  /// discarded so an unrelated song is never shown as crosstalk.
  Future<Map<String, dynamic>?> _searchBestTrack(
    String artist,
    String title, {
    int durationSec = 0,
  }) async {
    final res = await _dio.get(
      lastfmApiUrl,
      queryParameters: {
        'method': 'track.search',
        'api_key': _apiKey,
        'track': title,
        'limit': '30',
        'format': 'json',
      },
    );
    final data = _decodeBody(res.data);
    if (data == null) return null;
    final matches = data['results'];
    final trackMatches = matches is Map ? matches['trackmatches'] : null;
    var list = const [];
    if (trackMatches is Map) {
      final t = trackMatches['track'];
      if (t is List) list = t;
    }
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    var bestVerified = false;
    for (final e in list) {
      if (e is! Map) continue;
      final score = _matchScore(e, artist, title, durationSec);
      if (score > bestScore) {
        bestScore = score;
        best = Map<String, dynamic>.from(e);
        bestVerified =
            _artistMatch(e, artist) || _durationAgrees(e, durationSec);
      }
    }
    // A title-only match without an artist or duration signal is exactly
    // how the wrong song sneaks in — require one verifiable signal.
    const minScore = 1.0;
    return bestScore >= minScore && bestVerified ? best : null;
  }

  /// True when a search candidate names the queried artist (either
  /// direction of a substring counts: "The Weeknd" vs "Weeknd").
  bool _artistMatch(Map e, String artist) {
    final a = ('${e['artist']}').toLowerCase().trim();
    final q = artist.toLowerCase().trim();
    return a.isNotEmpty &&
        q.isNotEmpty &&
        (a == q || a.contains(q) || q.contains(a));
  }

  /// True when a search candidate's duration is within tolerance of the
  /// player's (accepts seconds or milliseconds encodings).
  bool _durationAgrees(Map e, int durationSec) {
    if (durationSec <= 0) return false;
    final candSec = _durationSeconds(e['duration'] ?? 0);
    if (candSec <= 0) return false;
    return (candSec - durationSec).abs() <= 20;
  }

  /// Likeness score for one `track.search` candidate row.
  double _matchScore(Map e, String artist, String title, int durationSec) {
    final candTitle = ('${e['name']}').toLowerCase().trim();
    final wantArtist = artist.toLowerCase().trim();
    final wantTitle = title.toLowerCase().trim();
    var score = 0.0;
    if (_artistMatch(e, artist)) {
      score += ('${e['artist']}').toLowerCase().trim() == wantArtist
          ? 1.5
          : 0.75;
    }
    if (candTitle == wantTitle) {
      score += 1.0;
    } else if (candTitle.contains(wantTitle) || wantTitle.contains(candTitle)) {
      score += 0.5;
    }
    if (durationSec > 0) {
      final candSec = _durationSeconds(e['duration'] ?? 0);
      if (candSec > 0) {
        final diff = (candSec - durationSec).abs();
        if (diff <= 5) {
          score += 1.5;
        } else if (diff <= 20) {
          score += 0.75;
        }
      }
    }
    return score;
  }

  void _setStatus(String value) {
    if (_status != value) {
      _status = value;
      notifyListeners();
    }
  }

  /// Requests a fresh auth token for the browser approval step.
  ///
  /// Returns the token, or null when it is missing or rejected.
  Future<String?> requestToken() async {
    try {
      final el = await _signedCall({
        'method': 'auth.getToken',
        'api_key': _apiKey,
      }, _secret);
      final token = el['token'] as String?;
      if (token == null || token.trim().isEmpty) {
        _setStatus('error: ${_lastfmError(el)}');
        return null;
      }
      return token;
    } catch (e) {
      _setStatus('error: ${_snippet('$e')}');
      return null;
    }
  }

  /// Browser URL where the user approves [token].
  String authorizeUrl(String token) =>
      '$lastfmAuthUrl?api_key=$_apiKey&token=$token';

  /// Exchanges an approved request [token] for a session, persisting it.
  ///
  /// Returns true when a session was stored.
  Future<bool> completeAuth(String token) async {
    if (token.trim().isEmpty) {
      _setStatus('error: approval token is missing — restart the login');
      return false;
    }
    try {
      final el = await _signedCall({
        'method': 'auth.getSession',
        'api_key': _apiKey,
        'token': token,
      }, _secret);
      final session = el['session'];
      final sessionKey = session is Map
          ? (session['key'] as String?)?.trim() ?? ''
          : '';
      final name = session is Map
          ? (session['name'] as String?)?.trim() ?? ''
          : '';
      if (sessionKey.isEmpty || name.isEmpty) {
        _setStatus('error: ${_lastfmError(el)}');
        return false;
      }
      _config.lastfmSessionKey = sessionKey;
      _config.lastfmUsername = name;
      refreshStatus();
      return true;
    } catch (e) {
      _setStatus('error: ${_snippet('$e')}');
      return false;
    }
  }

  /// Clears the stored session, keeping key/secret for the next login.
  void logout() {
    _config.lastfmSessionKey = '';
    _config.lastfmUsername = '';
    _setStatus('signed out');
  }

  /// Refreshes [status] from the current credentials.
  void refreshStatus() {
    if (!_config.lastfmEnabled) {
      _setStatus('disabled');
    } else if (_config.lastfmSessionKey.trim().isEmpty) {
      _setStatus('signed out');
    } else {
      _setStatus('signed in as ${_config.lastfmUsername}');
    }
  }

  /// Publishes a now-playing update; failures only surface via [status].
  Future<void> updateNowPlaying({
    required String artist,
    required String track,
    String? album,
    int durationSec = 0,
  }) async {
    if (!ready() || _blank(artist) || _blank(track)) return;
    await _signedTrackCall(
      method: 'track.updateNowPlaying',
      artist: artist,
      track: track,
      timestampSec: null,
      album: album,
      durationSec: durationSec,
    );
  }

  /// Scrobbles one play; failures only surface via [status].
  Future<bool> scrobble({
    required String artist,
    required String track,
    required int timestampSec,
    String? album,
    int durationSec = 0,
  }) async {
    if (!ready() || _blank(artist) || _blank(track)) return false;
    final ok = await _signedTrackCall(
      method: 'track.scrobble',
      artist: artist,
      track: track,
      timestampSec: timestampSec,
      album: album,
      durationSec: durationSec,
    );
    if (ok) _setStatus('signed in as ${_config.lastfmUsername}');
    return ok;
  }

  /// Runs one signed track call (now-playing or scrobble), reporting a
  /// failure through [status]. Returns whether Last.fm accepted it.
  Future<bool> _signedTrackCall({
    required String method,
    required String artist,
    required String track,
    required int? timestampSec,
    String? album,
    int durationSec = 0,
  }) async {
    try {
      final el = await _signedCall(
        _trackParams(
          method: method,
          artist: artist,
          track: track,
          timestampSec: timestampSec,
          album: album,
          durationSec: durationSec,
        ),
        _secret,
      );
      if (el['error'] != null) {
        _setStatus('error: ${_lastfmError(el)}');
        return false;
      }
      return true;
    } catch (e) {
      _setStatus('error: ${_snippet('$e')}');
      return false;
    }
  }

  /// Reports [track] as the now-playing one; failures only surface via
  /// [status].
  Future<void> _pushNowPlaying(Track track) => updateNowPlaying(
    artist: lastfmArtistName(track),
    track: cleanScrobbleTitle(track.title),
    album: track.album?.name,
    durationSec: track.durationSec,
  );

  /// Track params shared by now-playing and scrobble calls.
  Map<String, String> _trackParams({
    required String method,
    required String artist,
    required String track,
    required int? timestampSec,
    required String? album,
    required int durationSec,
  }) {
    return {
      'method': method,
      'api_key': _apiKey,
      'sk': _config.lastfmSessionKey,
      'artist': artist,
      'track': track,
      if (timestampSec != null) 'timestamp': '$timestampSec',
      'album': album ?? '',
      if (durationSec > 0) 'duration': '$durationSec',
    };
  }

  /// Short human-readable Last.fm API error, or "request rejected".
  String _lastfmError(Map<String, dynamic> el) {
    final message = el['message'] as String?;
    if (message != null && message.trim().isNotEmpty) return message;
    return 'request rejected';
  }

  /// True when [value] is null or only whitespace.
  static bool _blank(String? value) => value == null || value.trim().isEmpty;

  /// Decodes a response body that Dio may hand back either as a JSON
  /// string or as an already-decoded object; null when it is neither a
  /// map nor decodable.
  static Map<String, dynamic>? _decodeBody(Object? data) {
    final decoded = data is String ? jsonDecode(data) : data;
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Interprets a Last.fm duration that may be encoded in seconds or in
  /// milliseconds: values above [_maxDurationSec] are milliseconds.
  static int _durationSeconds(Object raw) {
    final ms = int.tryParse('$raw') ?? 0;
    if (ms <= 0) return 0;
    return ms > _maxDurationSec ? ms ~/ 1000 : ms;
  }

  /// Largest value still read as a whole number of seconds; anything
  /// above it must be milliseconds (a 3-hour track is ~10.8k seconds).
  static const _maxDurationSec = 10000;

  /// Truncates an error string to [_errorSnippetLen] chars, with a fallback.
  String _snippet(String raw, [String fallback = 'request failed']) {
    if (raw.isEmpty) return fallback;
    return raw.length > _errorSnippetLen
        ? raw.substring(0, _errorSnippetLen)
        : raw;
  }

  /// POSTs a signed API call and returns the decoded JSON body.
  ///
  /// [params] are the unsigned params including method and api_key; [secret]
  /// is the shared secret used for api_sig.
  Future<Map<String, dynamic>> _signedCall(
    Map<String, String> params,
    String secret,
  ) async {
    final keys = params.keys.toList()..sort();
    final sigBase = StringBuffer();
    for (final k in keys) {
      sigBase.write('$k${params[k]}');
    }
    sigBase.write(secret);
    final sig = md5.convert(utf8.encode(sigBase.toString())).toString();
    final res = await _dio.postUri<String>(
      Uri.parse(lastfmApiUrl),
      data: {...params, 'api_sig': sig, 'format': 'json'},
      options: Options(
        headers: {'User-Agent': _lastfmUserAgent},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    final decoded = _decodeBody(res.data);
    return decoded ?? const {};
  }

  /// Watches one player emission: now-playing on each new track, one scrobble
  /// per play once the standard threshold passes. Awaitable for tests; the
  /// playback watcher drives it fire-and-forget per emission.
  Future<void> update(PlayerState s) => _handleState(s, _progress);

  /// Routes one player emission to a track start or a progress update.
  Future<void> _handleState(PlayerState s, ScrobbleProgress progress) async {
    final track = s.current;
    final videoId = track?.videoId;
    if (videoId == null || videoId != progress.videoId) {
      progress.videoId = videoId;
      progress.startEpochSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      progress.lastPositionMs = 0;
      progress.scrobbled = false;
      if (videoId != null && track != null && ready()) {
        await _pushNowPlaying(track);
      }
      return;
    }
    if (track != null && ready() && !progress.scrobbled) {
      await _handleProgress(s, track, progress);
    }
    progress.lastPositionMs = s.positionMs;
  }

  /// Resets the play on backward seeks and scrobbles once past threshold.
  Future<void> _handleProgress(
    PlayerState s,
    Track track,
    ScrobbleProgress progress,
  ) async {
    if (s.positionMs < progress.lastPositionMs - seekBackToleranceMs) {
      // Seek back past tolerance (or repeat-one restart): new play.
      progress.startEpochSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      progress.scrobbled = false;
      if (s.playing) {
        await _pushNowPlaying(track);
      }
      return;
    }
    var durationSec = track.durationSec;
    if (durationSec <= 0) {
      final fromState = s.durationMs ~/ 1000;
      durationSec = fromState > 0 ? fromState : 0;
    }
    if (durationSec <= 0) return;
    if (durationSec <= minScrobbleDurationSec) return;
    final half = durationSec * 1000 ~/ 2;
    final thresholdMs = half < scrobbleCapSec * 1000
        ? half
        : scrobbleCapSec * 1000;
    if (s.playing && s.positionMs >= thresholdMs) {
      progress.scrobbled = await scrobble(
        artist: lastfmArtistName(track),
        track: cleanScrobbleTitle(track.title),
        timestampSec: progress.startEpochSec,
        album: track.album?.name,
        durationSec: durationSec,
      );
    }
  }

  @override
  void dispose() {
    _dio.close();
    super.dispose();
  }
}
