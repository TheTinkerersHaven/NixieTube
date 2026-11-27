// The audio cache: downloads the queue ahead of the playhead, captures the
// track being streamed, and serves a complete file back through the
// loopback proxy without touching the network. Everything here runs on
// real sockets and a temp directory, like the rest of the file-cache
// tests.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/player/audio_cache.dart';
import 'package:nixietube/core/player/stream_proxy.dart';

/// Payload of [length] bytes where every byte is `index % 251`, so a file
/// that was written out of order is detectable.
Uint8List _payload(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = i % 251;
  }
  return bytes;
}

/// A media edge that serves [body] the way the signed URLs do: `clen` in
/// the query, and ranges honored one request at a time.
class _Edge {
  _Edge(this.body);

  final Uint8List body;
  int requests = 0;

  /// Paths that answer 403, standing in for a URL whose budget ran out.
  final Set<String> refuse = {'/deny'};

  late final HttpServer server;

  String url(String id) =>
      'http://127.0.0.1:${server.port}/$id?clen=${body.length}';

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    requests++;
    final response = request.response;
    if (refuse.contains(request.uri.path)) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (match == null) {
      response.headers.contentLength = body.length;
      response.add(body);
      await response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final end = int.tryParse(match.group(2) ?? '') ?? body.length - 1;
    final slice = body.sublist(start, end + 1);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${body.length}',
    );
    response.headers.contentLength = slice.length;
    response.add(slice);
    await response.close();
  }
}

void main() {
  group('AudioCache downloads', () {
    test('a track is fetched in chunks and served afterwards', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-download');
      addTearDown(() => dir.delete(recursive: true));
      final edge = _Edge(_payload(1200 * 1024));
      await edge.start();
      addTearDown(() => edge.server.close(force: true));
      var resolves = 0;
      final cache = AudioCache(
        dirPath: dir.path,
        resolveUrl: (videoId) async {
          resolves++;
          return edge.url(videoId);
        },
      );

      await cache.download('track1');

      final file = cache.completeFile('track1');
      expect(file, isNotNull);
      expect(await file!.length(), edge.body.length);
      expect(await file.readAsBytes(), edge.body);
      // 1.2 MB in half-megabyte requests, one resolve for the whole file.
      expect(edge.requests, 3);
      expect(resolves, 1);

      // A second ask is free: the file is already there.
      await cache.download('track1');
      expect(edge.requests, 3);
      expect(resolves, 1);
    });

    test('a refused URL is re-resolved and the download continues', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-deny');
      addTearDown(() => dir.delete(recursive: true));
      final edge = _Edge(_payload(60 * 1024));
      await edge.start();
      addTearDown(() => edge.server.close(force: true));
      final urls = <String>[
        'http://127.0.0.1:${edge.server.port}/deny?clen=61440',
        edge.url('track2'),
      ];
      var calls = 0;
      final cache = AudioCache(
        dirPath: dir.path,
        resolveUrl: (videoId) async {
          final index = calls < urls.length ? calls : urls.length - 1;
          calls++;
          return urls[index];
        },
      );

      await cache.download('track2');

      expect(calls, 2);
      final file = cache.completeFile('track2');
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), edge.body);
    });

    test('a cache that is switched off never touches the network', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-off');
      addTearDown(() => dir.delete(recursive: true));
      final edge = _Edge(_payload(1024));
      await edge.start();
      addTearDown(() => edge.server.close(force: true));
      final cache = AudioCache(
        dirPath: dir.path,
        isEnabled: () => false,
        resolveUrl: (videoId) async => edge.url(videoId),
      );

      await cache.download('track3');

      expect(edge.requests, 0);
      expect(cache.completeFile('track3'), isNull);
    });

    test('the oldest files are evicted past the size cap', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-trim');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(
        dirPath: dir.path,
        maxBytes: () => 100,
        resolveUrl: (videoId) async => null,
      );
      final old = File('${dir.path}/old.audio')..writeAsBytesSync(List.filled(80, 1));
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      File('${dir.path}/new.audio').writeAsBytesSync(List.filled(80, 2));

      await cache.trim();

      expect(old.existsSync(), isFalse);
      expect(File('${dir.path}/new.audio').existsSync(), isTrue);
    });

    test('the cap is read per trim, so a new size applies at runtime',
        () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-cap');
      addTearDown(() => dir.delete(recursive: true));
      var cap = 1000;
      final cache = AudioCache(
        dirPath: dir.path,
        maxBytes: () => cap,
        resolveUrl: (videoId) async => null,
      );
      final first = File('${dir.path}/first.audio')
        ..writeAsBytesSync(List.filled(80, 1));
      first.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      File('${dir.path}/second.audio').writeAsBytesSync(List.filled(80, 2));

      await cache.trim();
      expect(first.existsSync(), isTrue);

      // Dropping the setting under the current usage evicts oldest-first
      // on the next pass, without a restart.
      cap = 100;
      await cache.trim();

      expect(first.existsSync(), isFalse);
      expect(File('${dir.path}/second.audio').existsSync(), isTrue);
    });
  });

  group('AudioCache captured prefix', () {
    test('a partial capture survives, and is dropped on a track change',
        () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-prefix');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);

      final capture = cache.beginCapture('keep1', 0, total: 1000)!;
      capture.add(List.filled(400, 7));
      await capture.close();

      // The bytes stay: they are what a seek back inside the track will
      // be answered from.
      expect(cache.capturedPrefix('keep1', total: 1000)?.length, 400);
      expect(cache.capturedPrefix('keep1', total: 10), isNull);

      // Only the playing track's capture is worth the disk.
      cache.dropCapturesExcept('other');
      expect(cache.capturedPrefix('keep1'), isNull);

      final second = cache.beginCapture('keep2', 0, total: 1000)!;
      second.add(List.filled(10, 7));
      await second.close();
      cache.dropCapturesExcept('keep2');
      expect(cache.capturedPrefix('keep2')?.length, 10);
    });

    test('a leftover of an earlier run is not served', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-leftover');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      // What a previous run left behind: no capture of ours wrote it, so
      // a different bitrate could have.
      File('${dir.path}/stale.audio.part').writeAsBytesSync(List.filled(64, 9));

      expect(cache.capturedPrefix('stale', total: 4096), isNull);
    });

    test('one writer at a time on the same capture file', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-writers');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);

      final first = cache.beginCapture('both', 0, total: 200)!;
      // A second request that would land on the same offset gets no
      // capture: two sinks on one file would interleave into it.
      expect(cache.beginCapture('both', 0, total: 200), isNull);
      first.add(List.filled(100, 1));
      await first.close();
      // Once the first is done the next one continues where it stopped.
      final next = cache.beginCapture('both', 100, total: 200);
      expect(next, isNotNull);
      await next!.close();
    });
  });

  group('AudioCache captures', () {
    test('a complete stream becomes a cache hit', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-capture');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);

      final capture = cache.beginCapture('track4', 0, total: 6);
      expect(capture, isNotNull);
      capture!.add([1, 2, 3]);
      capture.add([4, 5, 6]);
      await capture.close();

      final file = cache.completeFile('track4');
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    });

    test('a short stream is kept for a seek but never served as the track',
        () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-short');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);

      final capture = cache.beginCapture('track5', 0, total: 100);
      capture!.add([1, 2, 3]);
      await capture.close();

      // The track is not complete, so playback never gets it from disk…
      expect(cache.completeFile('track5'), isNull);
      // …but its bytes stay for a seek back, until the next track.
      expect(cache.capturedPrefix('track5')?.length, 3);
      cache.dropCapturesExcept('other');
      expect(dir.listSync(), isEmpty);
    });

    test('a seek that leaves a hole is not captured', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-seek');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      final first = cache.beginCapture('track6', 0, total: 10);

      expect(cache.beginCapture('track6', 4000, total: 10), isNull);
      await first!.close();
    });
  });

  group('stream proxy cache', () {
    tearDown(() => StreamProxy.instance.close());

    test('serves a complete file, honoring the range', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-proxy');
      addTearDown(() => dir.delete(recursive: true));
      final body = _payload(4096);
      File('${dir.path}/cached1.audio').writeAsBytesSync(body);
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      StreamProxy.instance.cache = cache;
      expect(StreamProxy.instance.servesCache, isTrue);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final url = await StreamProxy.instance.wrap(
        'http://127.0.0.1:1/never?clen=4096',
        videoId: 'cached1',
      );
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 100-199/4096');
      final received = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(received, body.sublist(100, 200));
    });

    test('a seek back inside the capture never reaches the edge', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-seekback');
      addTearDown(() => dir.delete(recursive: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      StreamProxy.instance.cache = cache;

      // What playback pulled down before the listener seeked away.
      final capture = cache.beginCapture('seek1', 0, total: 40000)!;
      capture.add(_payload(20000));
      await capture.close();

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      // A dead upstream: anything that goes to the network here fails,
      // so a served body can only have come from the capture.
      final url = await StreamProxy.instance.wrap(
        'http://127.0.0.1:1/dead?clen=40000',
        videoId: 'seek1',
      );
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 5000-19999/40000',
      );
      final received = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(received, _payload(20000).sublist(5000));
    });

    test('a seek past the capture goes to the edge and continues it',
        () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-seekfwd');
      addTearDown(() => dir.delete(recursive: true));
      final edge = _Edge(_payload(20 * 1024));
      await edge.start();
      addTearDown(() => edge.server.close(force: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      StreamProxy.instance.cache = cache;

      final capture = cache.beginCapture('seek2', 0, total: edge.body.length)!;
      capture.add(edge.body.sublist(0, 4096));
      await capture.close();

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final url = await StreamProxy.instance.wrap(
        edge.url('seek2'),
        videoId: 'seek2',
      );
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=4096-');
      final response = await request.close();
      final received = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(received, edge.body.sublist(4096));
      expect(edge.requests, 1);

      // The relay continued the capture instead of starting a new one,
      // so the whole track is on disk for the next play.
      var file = cache.completeFile('seek2');
      for (var i = 0; i < 40 && file == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        file = cache.completeFile('seek2');
      }
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), edge.body);
    });

    test('a URL that refused a range is asked for a bounded one next time',
        () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-strict');
      addTearDown(() => dir.delete(recursive: true));
      final edge = _Edge(_payload(8 * 1024));
      await edge.start();
      addTearDown(() => edge.server.close(force: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      StreamProxy.instance.cache = cache;

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final url = await StreamProxy.instance.wrap(
        'http://127.0.0.1:${edge.server.port}/deny?clen=${edge.body.length}',
        videoId: 'strict1',
      );
      // The first request discovers the refusal (one wasted round trip)…
      final first = await (await client.getUrl(Uri.parse(url))).close();
      await first.drain<void>();
      expect(edge.requests, 2);
      // …and the next one starts from a bounded range: a seek after the
      // first refusal is one round trip, not two.
      final second = await (await client.getUrl(Uri.parse(url))).close();
      await second.drain<void>();
      expect(edge.requests, 3);
    });

    test('captures what it relays and replays it from disk', () async {
      final dir = await Directory.systemTemp.createTemp('nt-cache-relay');
      addTearDown(() => dir.delete(recursive: true));
      final edge = _Edge(_payload(20 * 1024));
      await edge.start();
      addTearDown(() => edge.server.close(force: true));
      final cache = AudioCache(dirPath: dir.path, resolveUrl: (_) async => null);
      StreamProxy.instance.cache = cache;

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final url = await StreamProxy.instance.wrap(
        edge.url('relay1'),
        videoId: 'relay1',
      );
      final response = await (await client.getUrl(Uri.parse(url))).close();
      final received = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(received, edge.body);
      // The relay finished, so the capture is promoted; give the sink a
      // moment to land before checking.
      var file = cache.completeFile('relay1');
      for (var i = 0; i < 40 && file == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        file = cache.completeFile('relay1');
      }
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), edge.body);

      // Played back from disk: the edge is not asked again.
      final requests = edge.requests;
      final replay = await StreamProxy.instance.wrap(
        'http://127.0.0.1:1/dead?clen=${edge.body.length}',
        videoId: 'relay1',
      );
      final again = await (await client.getUrl(Uri.parse(replay))).close();
      final bytes = await again.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(bytes, edge.body);
      expect(edge.requests, requests);
    });
  });
}
