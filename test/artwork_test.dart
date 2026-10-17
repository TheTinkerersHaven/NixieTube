// Artwork pipeline tests: whole-frame decodes (no client crop), border
// stripping, palette bands, URL upgrades, and the end-to-end disk-cache
// path with seeded bytes.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/sys/http_client.dart';

img.Image _solid(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

void main() {
  group('decode keeps frames whole', () {
    test('non-square frames are never center-cropped', () async {
      // Square tiles resolve YouTube's own square art (or fetched
      // album art) instead: the pipeline keeps the source geometry
      // and the UI cover-fit handles tile boxes.
      final dir = await Directory.systemTemp.createTemp('nt-artwork-test');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      const url = 'https://artwork.invalid/cover.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img4')
          .writeAsBytes(img.encodeJpg(_solid(200, 100, 255, 255, 255)));
      final image = await store.image(url);
      expect(image, isNotNull);
      expect(image!.width, 200);
      expect(image.height, 100);
    });

    test('square thumbnails pass through untouched', () async {
      final dir = await Directory.systemTemp.createTemp('nt-artwork-test');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      const url = 'https://artwork.invalid/square.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img4')
          .writeAsBytes(img.encodeJpg(_solid(100, 100, 200, 30, 30)));
      final image = await store.image(url);
      expect(image, isNotNull);
      expect(image!.width, 100);
      expect(image.height, 100);
      expect(image.getPixel(50, 50).r, 200);
    });
  });

  group('coverBands', () {
    test('averages a 5x5 grid row-major', () {
      // Left column red, center green, right blue; rows split top/bottom
      // brightness so every cell is distinguishable.
      final raw = img.Image(width: 90, height: 90);
      for (var y = 0; y < 90; y++) {
        for (var x = 0; x < 90; x++) {
          final bright = y < 45 ? 200 : 60;
          if (x < 30) {
            raw.setPixelRgb(x, y, bright, 20, 20);
          } else if (x < 60) {
            raw.setPixelRgb(x, y, 20, bright, 20);
          } else {
            raw.setPixelRgb(x, y, 20, 20, bright);
          }
        }
      }
      final bands = coverBands(raw)!;
      expect(bands.length, 25);
      // Top-left red, top-center green, top-right blue.
      expect(bands[0].$1, greaterThan(150));
      expect(bands[2].$2, greaterThan(150));
      expect(bands[4].$3, greaterThan(150));
      // Bottom row is the dim variant of the same columns.
      expect(bands[20].$1, lessThan(100));
      expect(bands[22].$2, lessThan(100));
      expect(bands[24].$3, lessThan(100));
      // Center cell is mid bright green.
      expect(bands[12].$2, greaterThan(100));
    });

    test('ignores edge pixels when sampling the grid', () {
      // Solid mid-red core with a bright white frame: the bands must
      // read the artwork, not the border.
      final raw = img.Image(width: 90, height: 90);
      for (var y = 0; y < 90; y++) {
        for (var x = 0; x < 90; x++) {
          final border = x < 12 || y < 12 || x >= 78 || y >= 78;
          if (border) {
            raw.setPixelRgb(x, y, 250, 250, 250);
          } else {
            raw.setPixelRgb(x, y, 140, 20, 20);
          }
        }
      }
      final bands = coverBands(raw)!;
      expect(bands.length, 25);
      for (final band in bands) {
        // Red core dominates; the white frame stays inside
        // the sampling inset and never leaks in.
        expect(band.$1, greaterThan(100));
        expect(band.$2, lessThan(100));
        expect(band.$3, lessThan(100));
      }
    });
  });

  group('upgradeArt', () {
    test('rewrites size params preserving the source ratio', () {
      // Square source stays square (kept as-is downstream).
      expect(
        upgradeArt('https://x/y=w120-h120-p-l90-rj'),
        'https://x/y=w1080-h1080-p-l90-rj',
      );
      // Non-square source keeps its ratio: the server must not
      // pre-crop it to a square, square tiles resolve YouTube's own
      // square art (or fetched album art) instead.
      expect(
        upgradeArt('https://x/y=w976-h549-l90-rj'),
        'https://x/y=w1080-h608-l90-rj',
      );
      expect(upgradeArt('https://x/y=w600-h300'), 'https://x/y=w1080-h540');
      expect(upgradeArt('https://x/plain.jpg'), 'https://x/plain.jpg');
      expect(upscaleArtworkUrl('https://x/y=w60', 1920), 'https://x/y=w1920');
      expect(upscaleArtworkUrl('https://x/y=w2000', 1920), 'https://x/y=w2000');
    });
  });

  group('maxResGuess', () {
    test('rewrites ytimg stills to maxres', () {
      expect(
        maxResGuess('https://i.ytimg.com/vi/ABC123/hqdefault.jpg'),
        'https://i.ytimg.com/vi/ABC123/maxresdefault.jpg',
      );
      expect(
        maxResGuess('https://i.ytimg.com/vi/ABC123/sddefault.jpg'),
        'https://i.ytimg.com/vi/ABC123/maxresdefault.jpg',
      );
    });

    test('leaves maxres and non-ytimg urls alone', () {
      expect(
        maxResGuess('https://i.ytimg.com/vi/ABC123/maxresdefault.jpg'),
        isNull,
      );
      expect(
        maxResGuess('https://lh3.googleusercontent.com/x=w60-h60-l90-rj'),
        isNull,
      );
      expect(maxResGuess('https://x/plain.jpg'), isNull);
      expect(maxResGuess(''), isNull);
    });
  });

  group('error-page rejection', () {
    test('text error bodies never pass as art', () async {
      final dir = await Directory.systemTemp.createTemp('nt-art-ctype');
      addTearDown(() => dir.deleteSync(recursive: true));
      final good = img.encodePng(_solid(64, 64, 10, 200, 30));
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) {
        if (request.uri.path.endsWith('/missing.jpg')) {
          request.response
            ..statusCode = HttpStatus.notFound
            ..headers.contentType = ContentType.html
            ..write('<html><body>Not found</body></html>')
            ..close();
        } else {
          request.response
            ..headers.contentType = ContentType('image', 'png')
            ..add(good)
            ..close();
        }
      });
      addTearDown(() => server.close(force: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      // The HTML error page is rejected even though it is long enough
      // to pass the completeness check (non-JPEG always passes it).
      expect(
        await store.image('http://127.0.0.1:${server.port}/missing.jpg'),
        isNull,
      );
      // Real images (even non-JPEG content types) still decode.
      final image = await store.image(
        'http://127.0.0.1:${server.port}/good.png',
      );
      expect(image, isNotNull);
      expect(image!.width, 64);
    });
  });

  group('store disk path', () {
    test('seeded raw bytes decode whole with a stable tile render', () async {
      final dir = await Directory.systemTemp.createTemp('nt-artwork-test');
      addTearDown(() => dir.delete(recursive: true));
      final raw = _solid(200, 100, 255, 255, 255);
      final jpeg = img.encodeJpg(raw);
      // Seed under the URL hash like a previous download would.
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      const url = 'https://artwork.invalid/cover.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img4').writeAsBytes(jpeg);
      final image = await store.image(url);
      expect(image, isNotNull);
      expect(image!.width, 200);
      expect(image.height, 100);
      // Second call is served from memory.
      final again = await store.image(url);
      expect(again!.width, 200);
      // Stable tile render on demand (full frame, new generation).
      final file = await store.file(url);
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      expect(file.path.endsWith('.tile7.png'), isTrue);
      // cachedFile resolves the same on-disk render.
      final cached = await store.cachedFile(url);
      expect(cached, isNotNull);
      expect(cached!.path, file.path);
    });

    test('a cover with its own black border is kept whole', () async {
      // Square art printed with a black frame: the frame IS the artwork,
      // not letterboxing. The client must not trim it away.
      final dir = await Directory.systemTemp.createTemp('nt-art-border');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final framed = _solid(120, 120, 200, 30, 30);
      void black(int x1, int y1, int x2, int y2) => img.fillRect(
        framed,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        color: img.ColorRgb8(0, 0, 0),
      );
      black(0, 0, 119, 9);
      black(0, 110, 119, 119);
      black(0, 0, 9, 119);
      black(110, 0, 119, 119);
      const url = 'https://artwork.invalid/framed.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img4').writeAsBytes(img.encodePng(framed));
      final image = await store.image(url);
      expect(image, isNotNull);
      expect(image!.width, 120);
      expect(image.height, 120);
      // The rendered tile keeps the whole frame: border included.
      final file = await store.file(url);
      expect(file, isNotNull);
      final rendered = img.decodePng(file!.readAsBytesSync());
      expect(rendered, isNotNull);
      expect(rendered!.width, 120);
      expect(rendered.height, 120);
      expect(rendered.getPixel(0, 0).r.toInt(), lessThan(20));
      expect(rendered.getPixel(60, 60).r.toInt(), greaterThan(180));
    });

    test('worker pool serves more decodes than its size', () async {
      // The pool keeps 2 warm isolates; a burst of more concurrent decodes
      // must all succeed (a stall here means a worker never reported idle),
      // and each must return ITS OWN image (no cross-job routing).
      final dir = await Directory.systemTemp.createTemp('nt-art-pool');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final urls = [for (var i = 0; i < 6; i++) 'https://pool.invalid/$i.jpg'];
      for (var i = 0; i < urls.length; i++) {
        // Distinct solid color per URL; PNG keeps it lossless.
        final raw = _solid(64 + i, 64 + i, 30 * (i + 1), 20, 10);
        final hex = _shaForTest(urls[i]);
        await File('${dir.path}/$hex.img4').writeAsBytes(img.encodePng(raw));
      }
      final squares = await Future.wait([for (final u in urls) store.image(u)]);
      for (var i = 0; i < squares.length; i++) {
        expect(squares[i], isNotNull, reason: 'square decode $i');
        expect(squares[i]!.width, 64 + i);
        // The returned cover belongs to THIS url.
        expect(
          squares[i]!.getPixel(0, 0).r.toInt(),
          inInclusiveRange(30 * (i + 1) - 3, 30 * (i + 1) + 3),
          reason: 'decode $i content',
        );
      }
      final files = await Future.wait([for (final u in urls) store.file(u)]);
      for (var i = 0; i < files.length; i++) {
        expect(files[i], isNotNull, reason: 'tile render $i');
      }
    });

    test('clearCache deletes seeded raw and rendered files', () async {
      final dir = await Directory.systemTemp.createTemp('nt-art-clear');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      const url = 'https://artwork.invalid/clear.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img4')
          .writeAsBytes(img.encodePng(_solid(80, 40, 10, 200, 30)));
      // Renders the on-disk tile file from the seeded raw bytes.
      final file = await store.file(url);
      expect(file, isNotNull);
      expect(File('${dir.path}/$hex.tile7.png').existsSync(), isTrue);
      // Clearing removes every cached artwork file.
      store.clearCache();
      expect(File('${dir.path}/$hex.img4').existsSync(), isFalse);
      expect(File('${dir.path}/$hex.tile7.png').existsSync(), isFalse);
    });

    test('transient failures retry, and clearCache resets the skips', () async {
      final dir = await Directory.systemTemp.createTemp('nt-art-fails');
      addTearDown(() => dir.delete(recursive: true));
      var requests = 0;
      var serveGood = false;
      final good = img.encodePng(_solid(64, 64, 10, 200, 30));
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) {
        requests++;
        if (serveGood) {
          request.response
            ..headers.contentType = ContentType.binary
            ..add(good)
            ..close();
        } else {
          request.response
            ..statusCode = HttpStatus.serviceUnavailable
            ..close();
        }
      });
      addTearDown(() => server.close(force: true));
      // The real retrying client, with waits shrunk to nothing so the
      // test exercises the retry ladder instead of waiting it out.
      final store = ArtworkStore(
        cacheDirPath: dir.path,
        dio: newResilientClient(
          policy: const RetryPolicy(
            maxAttempts: 3,
            baseDelay: Duration(milliseconds: 1),
            maxDelay: Duration(milliseconds: 2),
          ),
        ),
      );
      addTearDown(store.close);
      final url = 'http://127.0.0.1:${server.port}/flaky.jpg';
      // One call spends its whole retry budget on the 503s before
      // counting as a failure, and a url is benched only after five
      // such failures: a flaky backend is given every chance.
      for (var i = 0; i < 5; i++) {
        expect(await store.image(url), isNull);
      }
      final afterSkips = requests;
      expect(afterSkips, 15);
      // Still skipped: no further requests.
      expect(await store.image(url), isNull);
      expect(requests, afterSkips);
      // Clearing resets the skips, so the (now healthy) url retries.
      serveGood = true;
      store.clearCache();
      final image = await store.image(url);
      expect(image, isNotNull);
      expect(requests, greaterThan(afterSkips));
    });

    test('clearCache drops the banner memo so banners re-render', () async {
      final dir = await Directory.systemTemp.createTemp('nt-art-banner');
      addTearDown(() => dir.delete(recursive: true));
      var requests = 0;
      final good = img.encodePng(_solid(64, 64, 10, 200, 30));
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) {
        requests++;
        request.response
          ..headers.contentType = ContentType.binary
          ..add(good)
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final url = 'http://127.0.0.1:${server.port}/banner.jpg';
      expect((await store.bannerPng(url)).isNotEmpty, isTrue);
      expect(requests, 1);
      // Memoized: no new request.
      expect((await store.bannerPng(url)).isNotEmpty, isTrue);
      expect(requests, 1);
      // Clearing drops the memo: the next call re-fetches.
      store.clearCache();
      expect((await store.bannerPng(url)).isNotEmpty, isTrue);
      expect(requests, 2);
    });
  });

  group('bannerPng memo', () {
    Future<HttpServer> servePng(List<int> bytes) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) {
        request.response
          ..headers.contentType = ContentType.binary
          ..add(bytes)
          ..close();
      });
      addTearDown(() => server.close(force: true));
      return server;
    }

    test('empty urls resolve empty without fetching', () async {
      final dir = await Directory.systemTemp.createTemp('nt-art-banner');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final first = store.bannerPng('');
      final second = store.bannerPng('');
      expect(identical(first, second), isTrue);
      expect(await first, isEmpty);
    });

    test('remounts reuse the finished bytes', () async {
      final png = img.encodePng(_solid(160, 90, 10, 200, 30));
      final server = await servePng(png);
      final dir = await Directory.systemTemp.createTemp('nt-art-banner');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final url = 'http://127.0.0.1:${server.port}/banner.png';
      final first = await store.bannerPng(url);
      expect(first, isNotEmpty);
      // Second call: identical future, no second download.
      final second = store.bannerPng(url);
      expect(await second, first);
    });

    test('the memo holds the newest entries', () async {
      final png = img.encodePng(_solid(160, 90, 10, 200, 30));
      final server = await servePng(png);
      final dir = await Directory.systemTemp.createTemp('nt-art-banner');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final first = store.bannerPng('http://127.0.0.1:${server.port}/0.png');
      for (var i = 1; i <= 8; i++) {
        await store.bannerPng('http://127.0.0.1:${server.port}/$i.png');
      }
      // Nine entries in an eight-slot memo: the first was evicted.
      expect(
        identical(
          store.bannerPng('http://127.0.0.1:${server.port}/0.png'),
          first,
        ),
        isFalse,
      );
    });
  });
}

String _shaForTest(String url) => sha1.convert(utf8.encode(url)).toString();
