// Loopback stream proxy for the media engines.
//
// The client's range is passed through unchanged: the direct URLs
// (TVHTML5, yt-dlp's WEB_EMBEDDED_PLAYER) answer one open-ended range
// with the whole rest of the file, so a track plays to the end on a
// single request.
//
// Cipher-solved `svpuc` URLs are stricter: they refuse open ranges and
// serve about 1 MB per URL before the edge 403s. For those the proxy
// falls back to bounded 256 KB chunks and, when the edge refuses one,
// asks the resolver for a fresh URL for the same video and retries.
// The client keeps using the same loopback URL either way.
//
// The proxy listens on 127.0.0.1 only and keeps a random token in the
// path, so other local processes cannot use it as an open relay.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../sys/log.dart';

final _log = TaggedLog('proxy');

/// Desktop-only loopback proxy that makes open-range clients work with
/// signed YouTube media URLs.
class StreamProxy {
  StreamProxy._();

  static final StreamProxy instance = StreamProxy._();

  HttpServer? _server;
  HttpClient? _client;
  final String _token = List.generate(
    16,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'.codeUnitAt(
      Random.secure().nextInt(36),
    ),
  ).join();

  /// Resolves a fresh raw URL for [videoId]. Wired by the app to the
  /// stream resolver; the proxy uses it when the edge refuses a chunk.
  Future<String?> Function(String videoId)? resolveFresh;

  /// Original URL → fresh URL, so the client's next request (same `s`
  /// parameter) uses the new URL without a re-resolve.
  final Map<String, String> _freshByOriginal = {};
  static const _maxFresh = 32;

  /// Returns a loopback URL that proxies [url]. [videoId] lets the
  /// proxy re-resolve when the URL's 1 MB budget runs out.
  Future<String> wrap(String url, {String? videoId}) async {
    final server = _server ??= await _start();
    final query = {
      's': url,
      if (videoId != null && videoId.isNotEmpty) 'v': videoId,
    };
    return 'http://127.0.0.1:${server.port}/$_token'
        '?${Uri(queryParameters: query).query}';
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient()..autoUncompress = false;
    _client = client;
    server.listen((request) {
      unawaited(_handle(request, client));
    });
    _log.d('stream proxy on 127.0.0.1:${server.port}');
    return server;
  }

  Future<void> _handle(HttpRequest request, HttpClient client) async {
    final response = request.response;
    try {
      if (request.uri.path != '/$_token') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final original = request.uri.queryParameters['s'];
      final parsedOriginal = original == null ? null : Uri.tryParse(original);
      if (parsedOriginal == null || parsedOriginal.host.isEmpty) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }
      final videoId = request.uri.queryParameters['v'];

      if (request.method == 'HEAD') {
        final clen = int.tryParse(parsedOriginal.queryParameters['clen'] ?? '');
        response.statusCode = HttpStatus.ok;
        if (clen != null && clen > 0) {
          response.headers.set(HttpHeaders.contentLengthHeader, clen);
        }
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        await response.close();
        return;
      }

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      var target = _freshByOriginal[original!] ?? original;
      var targetClen = int.tryParse(
        Uri.parse(target).queryParameters['clen'] ?? '',
      );
      var fetched = await _fetch(
        client,
        request.method,
        target,
        clientRange,
        targetClen,
      );

      final resolver = resolveFresh;
      if (fetched.response.statusCode == HttpStatus.forbidden &&
          resolver != null &&
          videoId != null) {
        final fresh = await resolver(videoId);
        if (fresh != null && fresh.isNotEmpty && fresh != target) {
          _rememberFresh(original, fresh);
          await _discard(fetched.response);
          target = fresh;
          targetClen = int.tryParse(
            Uri.parse(fresh).queryParameters['clen'] ?? '',
          );
          fetched = await _fetch(
            client,
            request.method,
            fresh,
            clientRange,
            targetClen,
          );
        }
      }

      final upstream = fetched.response;
      _log.d(
        '${request.method} range=${fetched.range ?? '(none)'} clen=$targetClen '
        '-> ${upstream.statusCode}',
      );
      response.statusCode = upstream.statusCode;
      for (final header in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'cache-control',
        'expires',
      ]) {
        final values = upstream.headers.value(header);
        if (values != null) response.headers.set(header, values);
      }
      await upstream.pipe(response);
    } catch (error) {
      _log.w('proxy request failed: $error');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  /// Opens [target] with the client's own range first. Only when the edge
  /// refuses it does the request fall back to a bounded chunk: an
  /// open-ended range that is accepted streams the whole rest of the
  /// file, which is what keeps a track playing past the first megabyte.
  Future<({HttpClientResponse response, String? range})> _fetch(
    HttpClient client,
    String method,
    String target,
    String? clientRange,
    int? contentLength,
  ) async {
    final upstream = await _open(client, method, target, clientRange);
    if (upstream.statusCode != HttpStatus.forbidden) {
      return (response: upstream, range: clientRange);
    }
    final bounded = _boundedRange(clientRange, contentLength);
    if (bounded == clientRange) {
      return (response: upstream, range: clientRange);
    }
    await _discard(upstream);
    return (
      response: await _open(client, method, target, bounded),
      range: bounded,
    );
  }

  /// Releases a refused response's connection without blocking the
  /// request that replaces it.
  Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } catch (_) {}
  }

  Future<HttpClientResponse> _open(
    HttpClient client,
    String method,
    String target,
    String? range,
  ) async {
    final upstream = await client.openUrl(method, Uri.parse(target));
    upstream.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    );
    upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) {
      upstream.headers.set(HttpHeaders.rangeHeader, range);
    }
    return upstream.close();
  }

  void _rememberFresh(String original, String fresh) {
    _freshByOriginal[original] = fresh;
    if (_freshByOriginal.length > _maxFresh) {
      _freshByOriginal.remove(_freshByOriginal.keys.first);
    }
  }

  /// Rewrites a range to a bounded chunk, for the URLs that refuse an
  /// open-ended one.
  ///
  /// Those URLs serve fixed-size chunks only: a range covering the whole
  /// file is refused too. The client asks for `bytes=<n>-`, so cap the
  /// end one chunk ahead; it then asks for the next chunk when it needs
  /// more.
  static const _chunkSize = 256 * 1024;

  String? _boundedRange(String? range, int? contentLength) {
    final clen = contentLength;
    if (clen == null || clen <= 0) return range;
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    final start = int.tryParse(match?.group(1) ?? '') ?? 0;
    final requestedEnd = int.tryParse(match?.group(2) ?? '');
    var end = requestedEnd ?? (start + _chunkSize - 1);
    if (end < start) end = start;
    if (end > start + _chunkSize - 1) end = start + _chunkSize - 1;
    if (end >= clen) end = clen - 1;
    if (start >= clen) return 'bytes=${clen - 1}-${clen - 1}';
    return 'bytes=$start-$end';
  }

  /// Stops the proxy and closes its client.
  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _client?.close(force: true);
    _client = null;
    _freshByOriginal.clear();
    resolveFresh = null;
  }
}
