// Last.fm scrobbling over the ws.audioscrobbler.com API, ported from Kotlin
// `LastFm.kt`: session auth (request token approved in the browser),
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
import 'http_client.dart';
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
/// optionally wrapped in `()`/`[]`, anywhere in a title. Mirrors the Kotlin
/// `FEATURE_SEGMENT_RE` used for feature-credit stripping.
final _featureCreditRe = RegExp(
  r'''\s*[\(\[]?(?:feat\.?|ft\.?|featuring|w/)\s+[^)\]]+[\)\]]?''',
  caseSensitive: false,
);

/// Strips featuring credits from [title] so Last.fm receives the clean
/// release title ("Song (feat. Artist)" → "Song").
String cleanScrobbleTitle(String title) =>
    title.replaceAll(_featureCreditRe, '').trim();

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
    _dio = dio ?? newHttpClient();
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
      _setStatus('error: ${_snippet('$e', 'request failed')}');
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
      _setStatus('error: ${_snippet('$e', 'request failed')}');
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
    if (!ready() || artist.trim().isEmpty || track.trim().isEmpty) return;
    try {
      final el = await _signedCall(
        _trackParams(
          'track.updateNowPlaying',
          artist,
          track,
          null,
          album,
          durationSec,
        ),
        _secret,
      );
      if (el['error'] != null) _setStatus('error: ${_lastfmError(el)}');
    } catch (e) {
      _setStatus('error: ${_snippet('$e', 'request failed')}');
    }
  }

  /// Scrobbles one play; failures only surface via [status].
  Future<void> scrobble({
    required String artist,
    required String track,
    required int timestampSec,
    String? album,
    int durationSec = 0,
  }) async {
    if (!ready() || artist.trim().isEmpty || track.trim().isEmpty) return;
    try {
      final el = await _signedCall(
        _trackParams(
          'track.scrobble',
          artist,
          track,
          timestampSec,
          album,
          durationSec,
        ),
        _secret,
      );
      if (el['error'] != null) {
        _setStatus('error: ${_lastfmError(el)}');
      } else {
        _setStatus('signed in as ${_config.lastfmUsername}');
      }
    } catch (e) {
      _setStatus('error: ${_snippet('$e', 'request failed')}');
    }
  }

  /// Track params shared by now-playing and scrobble calls.
  Map<String, String> _trackParams(
    String method,
    String artist,
    String track,
    int? timestampSec,
    String? album,
    int durationSec,
  ) {
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

  /// Truncates an error string to [_errorSnippetLen] chars, with a fallback.
  String _snippet(String raw, String fallback) {
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
    final decoded = jsonDecode(res.data ?? '');
    return decoded is Map<String, dynamic> ? decoded : const {};
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
        await updateNowPlaying(
          artist: lastfmArtistName(track),
          track: cleanScrobbleTitle(track.title),
          album: track.album?.name,
          durationSec: track.durationSec,
        );
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
        await updateNowPlaying(
          artist: lastfmArtistName(track),
          track: cleanScrobbleTitle(track.title),
          album: track.album?.name,
          durationSec: track.durationSec,
        );
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
      progress.scrobbled = true;
      await scrobble(
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
