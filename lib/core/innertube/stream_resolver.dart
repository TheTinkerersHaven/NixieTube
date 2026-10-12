// Stream URL resolution via the InnerTube player endpoint.
//
// The Kotlin client uses NewPipe (Java) here, which has no Dart equivalent.
// Instead this calls the `player` endpoint directly with the VISIONOS client,
// whose audio URLs need no deciphering and serve arbitrary byte ranges
// (the same approach yt-dlp's `visionos` client uses, and what the previous
// native shell validated for full-track streaming + seeking).

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../sys/http_client.dart';
import 'json.dart';

const _visionosUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const _visionosClientVersion = '1.02';
const _visionosClientName = '101';
const _ytOrigin = 'https://www.youtube.com';
const _ytPlayer = 'https://www.youtube.com/youtubei/v1/player?alt=json';

/// Direct audio stream URL plus metadata.
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.bitrate,
    this.codec,
    this.likes = -1,
    this.dislikes = -1,
  });

  final String url;
  final int bitrate;
  final String? codec;

  /// Public like count, or -1 when unknown.
  final int likes;
  final int dislikes;
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

/// Resolves direct audio stream URLs through the InnerTube player endpoint.
class StreamResolver {
  StreamResolver({Dio? dio}) : _dio = dio ?? newHttpClient();

  Dio _dio;
  String? _visitor;

  /// When the cached visitor id was fetched. Visitor-bound stream URLs can
  /// die server-side well before their `expire` timestamp (the edge has
  /// returned 403 on minutes-old, IP-correct URLs), so the id is treated
  /// as perishable and re-fetched when older than [_visitorTtl].
  DateTime? _visitorAt;

  /// Maximum age of a cached visitor id before it is re-fetched.
  static const visitorTtl = Duration(minutes: 30);

  void close() => _dio.close();

  /// Drops all HTTP-side stream state the way an app restart would:
  /// pooled keepalive connections plus the cached visitor id. The next
  /// resolve refetches everything. Called when a stream-URL family
  /// keeps dying (edge 403s on fresh URLs), before surfacing an error.
  Future<void> reset() async {
    _visitor = null;
    _visitorAt = null;
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
      final m = RegExp(r'"VISITOR_DATA":"([^"]+)"')
          .firstMatch(res.data ?? '');
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
  Future<ResolvedStream?> resolve(String videoId) async {
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
      res = null;
      if (refresh) break;
    }
    if (res == null) return null;
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
        );
      }
    }
    return best;
  }
}
