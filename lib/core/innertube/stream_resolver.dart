// Stream URL resolution via the InnerTube player endpoint.
//
// Signed-out playback uses the VISIONOS client, whose audio URLs need no
// deciphering and serve arbitrary byte ranges. When VISIONOS returns a
// login- or age-restriction status, the resolver falls back to yt-dlp
// (shelling out to the `yt-dlp` binary) which handles cipher deciphering
// and PO tokens for age-restricted tracks.
//
// Both clients return direct audio URLs when deciphering isn't needed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../sys/http_client.dart';
import 'json.dart';

/// Logger for stream resolution diagnostics.
final _log = Logger('nixietube.stream_resolver');

const _visionosUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const _visionosClientVersion = '1.02';
const _visionosClientName = '101';
const _ytOrigin = 'https://www.youtube.com';
const _ytPlayer = 'https://www.youtube.com/youtubei/v1/player?alt=json';

/// Age-restriction / login-related playability statuses that mean VISIONOS
/// cannot play the track and the resolver should fall back to yt-dlp.
const _ytDlpFallbackStatuses = {
  'LOGIN_REQUIRED',
  'AGE_VERIFICATION_REQUIRED',
  'AGE_CHECK_REQUIRED',
  'CONTENT_CHECK_REQUIRED',
};

/// Direct audio stream URL plus metadata.
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.bitrate,
    this.codec,
    this.likes = -1,
    this.dislikes = -1,
    this.durationSec = 0,
  });

  final String url;
  final int bitrate;
  final String? codec;

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
  StreamResolver({Dio? dio, this._cookie})
      : _dio = dio ?? newHttpClient();

  Dio _dio;

  String? _cookie;

  /// Updates the cookie used to authenticate yt-dlp for age-restricted
  /// content. Called after the session is restored from the secret store.
  set cookie(String? value) => _cookie = value;

  String? _visitor;

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
  final _cache = <String, _CacheEntry>{};

  /// Releases the HTTP client. Call once at shutdown; in-flight
  /// requests fail fast instead of hanging on dispose.
  void close() => _dio.close();

  /// Drops all HTTP-side stream state the way an app restart would:
  /// pooled keepalive connections plus the cached visitor id. The next
  /// resolve refetches everything. Called when a stream-URL family
  /// keeps dying (edge 403s on fresh URLs), before surfacing an error.
  Future<void> reset() async {
    _visitor = null;
    _visitorAt = null;
    _cache.clear();
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

  Future<dynamic> _playerRequest(String videoId, String visitor) async {
    final body = {
      'context': {
        'client': {
          'clientName': 'VISIONOS',
          'clientVersion': _visionosClientVersion,
          'deviceMake': 'Apple',
          'deviceModel': 'RealityDevice17,1',
          'userAgent': _visionosUserAgent,
          'osName': 'visionOS',
          'osVersion': '26.5.23O471',
          'hl': 'en',
        },
        'user': <String, dynamic>{},
      },
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    final res = await _dio
        .postUri<String>(
          Uri.parse(_ytPlayer),
          data: jsonEncode(body),
          options: Options(
            headers: {
              'User-Agent': _visionosUserAgent,
              'X-YouTube-Client-Name': _visionosClientName,
              'X-YouTube-Client-Version': _visionosClientVersion,
              'X-Goog-Visitor-Id': visitor,
              'Origin': _ytOrigin,
              'Content-Type': 'application/json',
            },
          ),
        )
        .timeout(const Duration(seconds: 30));
    return decodeJsonResponse(res.data ?? '');
  }

  /// Resolves the highest-bitrate direct audio URL for [videoId], or null
  /// when nothing playable is offered.
  ///
  /// VISIONOS is tried first. If it returns a login or age-restriction
  /// status, yt-dlp is used as a fallback (shelling out to the `yt-dlp`
  /// binary). Successful results are cached for [_cacheTtl] so replaying
  /// the same track doesn't repeat the (slow) yt-dlp shell-out.
  Future<ResolvedStream?> resolve(String videoId) async {
    final entry = _cache[videoId];
    if (entry != null && DateTime.now().isBefore(entry.expiry)) {
      return entry.stream;
    }

    final visionos = await _resolveAnonymous(videoId);
    if (visionos != null) {
      _cache[videoId] = _CacheEntry(
        visionos,
        DateTime.now().add(cacheTtl),
      );
      return visionos;
    }
    final ytDlp = await _resolveYtDlp(videoId);
    if (ytDlp != null) {
      _cache[videoId] = _CacheEntry(
        ytDlp,
        DateTime.now().add(cacheTtl),
      );
    }
    return ytDlp;
  }

  /// Signed-out resolve with the JS-less VISIONOS client.
  Future<ResolvedStream?> _resolveAnonymous(String videoId) async {
    dynamic res;
    for (final refresh in [false, true]) {
      final visitor = await _visitorData(refresh);
      if (visitor == null) return null;
      try {
        res = await _playerRequest(videoId, visitor);
      } catch (_) {
        res = null;
      }
      final status = str(nav(res, const ['playabilityStatus', 'status']));
      if (status == 'OK') break;
      if (_ytDlpFallbackStatuses.contains(status)) {
        _log.info(
          'VISIONOS returned $status for $videoId — falling back to yt-dlp',
        );
        return null;
      }
      res = null;
      if (refresh) break;
    }
    if (res == null) return null;
    return _streamFrom(res);
  }

  /// Resolves via the `yt-dlp` binary, which handles cipher deciphering,
  /// PO tokens, and age-restricted content. Returns null when yt-dlp is
  /// unavailable or cannot extract a URL.
  ///
  /// When [_cookie] (a `Cookie:` header) is set it is written to a
  /// throwaway Netscape-format file and passed via `--cookies`, so
  /// age-restricted content authenticates with the viewer's session.
  Future<ResolvedStream?> _resolveYtDlp(String videoId) async {
    if (!await _ytDlpAvailable()) {
      _log.warning('yt-dlp binary not available on PATH');
      return null;
    }
    try {
      final args = <String>[
        '--format',
        'bestaudio',
        '--get-url',
        '--no-check-certificates',
      ];
      String? cookieFile;
      final cookie = _cookie;
      if (cookie != null && cookie.isNotEmpty) {
        final file = File(
            '${Directory.systemTemp.path}/nixietube_yt_dlp_cookies.txt');
        final netscape = _cookieToNetscape(cookie);
        await file.writeAsString(netscape);
        cookieFile = file.path;
        args.addAll(['--cookies', cookieFile]);
        _log.fine('Wrote yt-dlp cookie file at $cookieFile');
      }
      _log.fine('Running yt-dlp for $videoId with ${cookieFile != null ? 'cookies' : 'no cookies'}');
      final result = await Process.run(
        'yt-dlp',
        [...args, 'https://www.youtube.com/watch?v=$videoId'],
        runInShell: true,
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0 || result.stdout.isEmpty) {
        _log.warning(
          'yt-dlp failed for $videoId: exitCode=${result.exitCode} '
          'stderr=${result.stderr}',
        );
        return null;
      }
      final url = result.stdout.trim().split('\n').first.trim();
      if (url.isEmpty || !url.startsWith('http')) {
        _log.warning('yt-dlp returned non-URL output for $videoId');
        return null;
      }
      _log.info('Resolved stream for $videoId via yt-dlp: ${url.length} chars');
      return ResolvedStream(
        url: url,
        bitrate: 0, // yt-dlp doesn't expose bitrate via --get-url
        durationSec: 0,
      );
    } catch (error) {
      _log.warning('yt-dlp exception for $videoId: $error');
      return null;
    } finally {
      try {
        await File('${Directory.systemTemp.path}/nixietube_yt_dlp_cookies.txt')
            .delete();
      } catch (_) {}
    }
  }

  /// True when the `yt-dlp` binary is on PATH and executable.
  Future<bool> _ytDlpAvailable() async {
    try {
      final result = await Process.run(
        'yt-dlp',
        ['--version'],
        runInShell: true,
      ).timeout(const Duration(seconds: 5));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Picks the highest-bitrate audio format from a player response.
  ResolvedStream? _streamFrom(dynamic res) {
    final length = int.tryParse(
      str(nav(res, const ['videoDetails', 'lengthSeconds'])) ?? '',
    );
    ResolvedStream? best;
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
        if (best != null && best.bitrate >= bitrate) continue;
        best = ResolvedStream(
          url: url,
          bitrate: bitrate,
          codec: _codecOf(mime),
          durationSec: length ?? 0,
        );
      }
    }
    return best;
  }

  /// Converts a `Cookie:` header string to Netscape cookie file format for
  /// yt-dlp. All cookies are written against `.youtube.com` so they match
  /// both `youtube.com` and `music.youtube.com` requests.
  String _cookieToNetscape(String cookie) {
    final buf = StringBuffer();
    buf.writeln('# Netscape HTTP Cookie File');
    buf.writeln('# Generated by NixieTube for yt-dlp authentication');
    for (final pair in cookie.split(';')) {
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      // domain, include_subdomains, path, secure, expires, name, value
      buf.writeln('.youtube.com\tTRUE\t/\tFALSE\t0\t$name\t$value');
    }
    return buf.toString();
  }
}
