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
import 'audio_cache.dart';

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

  /// Track cache. When set, a complete cached file is served without
  /// touching the network, and the streams that are not cached yet are
  /// captured as they are relayed.
  AudioCache? cache;

  /// Whether resolved audio should be routed through the proxy even when
  /// its URL serves ranges directly: only then can the cache see it.
  bool get servesCache => cache?.enabled ?? false;

  /// Original URL → fresh URL, so the client's next request (same `s`
  /// parameter) uses the new URL without a re-resolve.
  final Map<String, String> _freshByOriginal = {};
  static const _maxFresh = 32;

  /// Media URLs that answered a range request with 403, so every later
  /// request for them is bounded from the start instead of spending a
  /// round trip on a range the edge will refuse again.
  final Set<String> _strictUrls = {};
  static const _maxStrict = 32;

  /// The track whose bytes the capture holds, so a track change can drop
  /// what the previous one left behind.
  String? _lastTrack;

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

      // A new track: the bytes captured for the previous one are of no
      // further use, and only the playing track's are.
      final track = videoId ?? '';
      if (track.isNotEmpty && track != _lastTrack) {
        _lastTrack = track;
        cache?.dropCapturesExcept(track);
      }

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

      final cached = cache?.completeFile(videoId ?? '');
      if (cached != null) {
        _log.d('$track served from the cache');
        await _serveFile(request, cached);
        return;
      }

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      var target = _freshByOriginal[original!] ?? original;
      var targetClen = int.tryParse(
        Uri.parse(target).queryParameters['clen'] ?? '',
      );

      // A seek back into what the track already played is answered from
      // the capture on disk: those bytes came down the wire once, and
      // asking the edge for them again is what made a backward seek sit
      // silent through a round trip (or a re-resolve) while it waited.
      final captured = cache?.capturedPrefix(track, total: targetClen);
      if (captured != null &&
          await _serveCaptured(
            request,
            captured,
            track: track,
            total: targetClen,
          )) {
        return;
      }

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
        '$track ${request.method} range=${fetched.range ?? '(none)'} '
        'clen=$targetClen -> ${upstream.statusCode}',
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
      // Capture what the engine is already streaming, so a track played
      // once is on disk for the next time without a second download.
      final capture = (request.method == 'GET' && videoId != null)
          ? cache?.beginCapture(
              videoId,
              _startOf(upstream, clientRange),
              total: targetClen,
            )
          : null;
      if (capture == null) {
        await upstream.pipe(response);
      } else {
        try {
          await response.addStream(
            upstream.map((chunk) {
              capture.add(chunk);
              return chunk;
            }),
          );
        } finally {
          await response.close();
          await capture.close();
        }
      }
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
  ///
  /// A URL that refused a range once keeps refusing it, so the refusal is
  /// remembered and the next request goes straight to the bounded chunk:
  /// after a seek that round trip is time the listener spends in silence.
  Future<({HttpClientResponse response, String? range})> _fetch(
    HttpClient client,
    String method,
    String target,
    String? clientRange,
    int? contentLength,
  ) async {
    final bounded = _boundedRange(clientRange, contentLength);
    if (bounded != clientRange && _strictUrls.contains(target)) {
      return (
        response: await _open(client, method, target, bounded),
        range: bounded,
      );
    }
    final upstream = await _open(client, method, target, clientRange);
    if (upstream.statusCode != HttpStatus.forbidden) {
      return (response: upstream, range: clientRange);
    }
    _rememberStrict(target);
    if (bounded == clientRange) {
      return (response: upstream, range: clientRange);
    }
    await _discard(upstream);
    return (
      response: await _open(client, method, target, bounded),
      range: bounded,
    );
  }

  /// Serves the part of a range that [prefix] already holds on disk.
  ///
  /// Returns false when the request does not start inside the captured
  /// bytes — a forward seek into territory that still has to be fetched —
  /// so the caller falls through to the network. The response ends where
  /// the capture does, and the client asks for the rest, which is exactly
  /// the offset the capture continues from.
  Future<bool> _serveCaptured(
    HttpRequest request,
    ({File file, int length}) prefix, {
    required String track,
    int? total,
  }) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    final start = int.tryParse(match?.group(1) ?? '');
    if (start == null || start >= prefix.length) return false;
    final requestedEnd = int.tryParse(match?.group(2) ?? '');
    final last = prefix.length - 1;
    final end = requestedEnd == null || requestedEnd > last
        ? last
        : requestedEnd;
    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set('content-type', 'audio/mp4');
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${total ?? '*'}',
    );
    response.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
    _log.d('$track $start-$end from the capture '
        '(${prefix.length} bytes held)');
    try {
      await response.addStream(prefix.file.openRead(start, end + 1));
      await response.close();
    } catch (error) {
      // A half-written capture is not worth failing the request over:
      // the client asks again and the network answers it.
      _log.d('capture serve failed: $error');
      return false;
    }
    return true;
  }

  /// Releases a refused response's connection without blocking the
  /// request that replaces it.
  Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } catch (_) {}
  }

  /// Serves [file] to [request], honoring its range so the engine can seek
  /// inside a cached track.
  Future<void> _serveFile(HttpRequest request, File file) async {
    final response = request.response;
    final total = await file.length();
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set('content-type', 'audio/mp4');
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    if (match == null || total == 0) {
      response.statusCode = HttpStatus.ok;
      response.headers.set(HttpHeaders.contentLengthHeader, '$total');
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.addStream(file.openRead());
      await response.close();
      return;
    }
    final start = int.tryParse(match.group(1) ?? '') ?? 0;
    final requestedEnd = int.tryParse(match.group(2) ?? '');
    final end = (requestedEnd ?? total - 1).clamp(start, total - 1);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$total',
    );
    response.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, end + 1));
    await response.close();
  }

  /// Where in the file [upstream] starts, for the capture: the offset the
  /// engine asked for, or 0 when it asked for everything.
  int _startOf(HttpClientResponse upstream, String? clientRange) {
    final served = upstream.headers.value(HttpHeaders.contentRangeHeader);
    final fromServed = served == null
        ? null
        : RegExp(r'bytes (\d+)-').firstMatch(served);
    if (fromServed != null) {
      return int.tryParse(fromServed.group(1) ?? '') ?? 0;
    }
    if (clientRange == null) return 0;
    final match = RegExp(r'bytes=(\d+)-').firstMatch(clientRange);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
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

  void _rememberStrict(String target) {
    if (!_strictUrls.add(target)) return;
    if (_strictUrls.length > _maxStrict) {
      _strictUrls.remove(_strictUrls.first);
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
    _strictUrls.clear();
    _lastTrack = null;
    resolveFresh = null;
    cache = null;
  }
}
