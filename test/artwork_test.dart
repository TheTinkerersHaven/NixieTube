// Artwork pipeline tests: square crops, border stripping, palette bands,
// URL upgrades, and the end-to-end disk-cache path with seeded bytes.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nixietube/core/artwork/artwork_store.dart';

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
  group('centerSquare', () {
    test('keeps full height on landscape', () {
      final raw = _solid(200, 100, 255, 255, 255);
      for (var x = 0; x < 200; x++) {
        for (var y = 0; y < 10; y++) {
          raw.setPixelRgb(x, y, 0, 0, 0);
          raw.setPixelRgb(x, 99 - y, 0, 0, 0);
        }
      }
      final out = centerSquare(raw);
      expect(out.width, 100);
      expect(out.height, 100);
      // Full height kept: top/bottom border rows included.
      expect(out.getPixel(0, 0).r, 0);
      expect(out.getPixel(50, 50).r, 255);
    });

    test('keeps square thumbnails untouched', () {
      // Already square: no cropping, no shaving — returned as-is.
      final raw = _solid(100, 100, 200, 30, 30);
      for (var x = 0; x < 100; x++) {
        for (var y = 0; y < 10; y++) {
          raw.setPixelRgb(x, y, 0, 0, 0);
        }
      }
      final out = centerSquare(raw);
      expect(out.width, 100);
      expect(out.height, 100);
      // The white margin is part of the cover and survives.
      expect(out.getPixel(50, 0).r, 0);
      expect(out.getPixel(50, 50).r, 200);
    });

    test('portrait center-squares to full width', () {
      final raw = _solid(100, 200, 255, 255, 255);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 10; x++) {
          raw.setPixelRgb(x, y, 0, 0, 0);
          raw.setPixelRgb(99 - x, y, 0, 0, 0);
        }
      }
      final out = centerSquare(raw);
      expect(out.width, 100);
      expect(out.height, 100);
      // Full width kept: left/right border columns included.
      expect(out.getPixel(0, 0).r, 0);
      expect(out.getPixel(50, 50).r, 255);
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
      expect(upgradeArt('https://x/y=w120-h120-p-l90-rj'),
          'https://x/y=w540-h540-p-l90-rj');
      // Non-square source keeps its ratio: the server must not
      // pre-crop it to a square, the client center-square does that.
      expect(upgradeArt('https://x/y=w976-h549-l90-rj'),
          'https://x/y=w540-h304-l90-rj');
      expect(upgradeArt('https://x/y=w600-h300'),
          'https://x/y=w540-h270');
      expect(
          upgradeArt('https://x/plain.jpg'), 'https://x/plain.jpg');
      expect(upscaleArtworkUrl('https://x/y=w60', 1920),
          'https://x/y=w1920');
      expect(upscaleArtworkUrl('https://x/y=w2000', 1920),
          'https://x/y=w2000');
    });
  });

  group('store disk path', () {
    test('seeded raw bytes decode to a square crop', () async {
      final dir = await Directory.systemTemp
          .createTemp('nt-artwork-test');
      addTearDown(() => dir.delete(recursive: true));
      final raw = _solid(200, 100, 255, 255, 255);
      final jpeg = img.encodeJpg(raw);
      // Seed under the URL hash like a previous download would.
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      const url = 'https://artwork.invalid/cover.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img3')
          .writeAsBytes(jpeg);
      final image = await store.image(url);
      expect(image, isNotNull);
      expect(image!.width, image.height);
      expect(image.width, 100);
      // Second call is served from memory.
      final again = await store.image(url);
      expect(again!.width, 100);
      // Stable cropped file renders on demand.
      final file = await store.file(url);
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      // cachedFile resolves the same on-disk render.
      final cached = await store.cachedFile(url);
      expect(cached, isNotNull);
      expect(cached!.path, file.path);
    });

    test('worker pool serves more decodes than its size', () async {
      // The pool keeps 2 warm isolates; a burst of more concurrent decodes
      // must all succeed (a stall here means a worker never reported idle),
      // and each must return ITS OWN image (no cross-job routing).
      final dir = await Directory.systemTemp.createTemp('nt-art-pool');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final urls = [
        for (var i = 0; i < 6; i++) 'https://pool.invalid/$i.jpg',
      ];
      for (var i = 0; i < urls.length; i++) {
        // Distinct solid color per URL; PNG keeps it lossless.
        final raw = _solid(64 + i, 64 + i, 30 * (i + 1), 20, 10);
        final hex = _shaForTest(urls[i]);
        await File('${dir.path}/$hex.img3').writeAsBytes(img.encodePng(raw));
      }
      final squares = await Future.wait([
        for (final u in urls) store.image(u),
      ]);
      for (var i = 0; i < squares.length; i++) {
        expect(squares[i], isNotNull, reason: 'square decode $i');
        expect(squares[i]!.width, squares[i]!.height);
        // The returned cover belongs to THIS url.
        expect(
          squares[i]!.getPixel(0, 0).r.toInt(),
          inInclusiveRange(30 * (i + 1) - 3, 30 * (i + 1) + 3),
          reason: 'decode $i content',
        );
      }
      final files = await Future.wait([for (final u in urls) store.file(u)]);
      for (var i = 0; i < files.length; i++) {
        expect(files[i], isNotNull, reason: 'crop render $i');
      }
    });

    test('clearCache deletes seeded raw and rendered files', () async {
      final dir = await Directory.systemTemp.createTemp('nt-art-clear');
      addTearDown(() => dir.delete(recursive: true));
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      const url = 'https://artwork.invalid/clear.jpg';
      final hex = _shaForTest(url);
      await File('${dir.path}/$hex.img3')
          .writeAsBytes(img.encodePng(_solid(80, 40, 10, 200, 30)));
      // Renders the on-disk crop from the seeded raw bytes.
      final file = await store.file(url);
      expect(file, isNotNull);
      expect(File('${dir.path}/$hex.crop5.png').existsSync(), isTrue);
      // Clearing removes every cached artwork file.
      store.clearCache();
      expect(File('${dir.path}/$hex.img3').existsSync(), isFalse);
      expect(File('${dir.path}/$hex.crop5.png').existsSync(), isFalse);
    });

    test('clearCache resets failure skips so urls retry', () async {
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
      final store = ArtworkStore(cacheDirPath: dir.path);
      addTearDown(store.close);
      final url = 'http://127.0.0.1:${server.port}/flaky.jpg';
      // Three consecutive failures trip the skip-list.
      for (var i = 0; i < 4; i++) {
        expect(await store.image(url), isNull);
      }
      final afterSkips = requests;
      expect(afterSkips, 3);
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

    test('clearCache drops the banner memo so banners re-render',
        () async {
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
        identical(store.bannerPng('http://127.0.0.1:${server.port}/0.png'), first),
        isFalse,
      );
    });
  });

  group('removeLetterbox', () {
    img.Image bars({
      required int w,
      required int h,
      int top = 0,
      int bottom = 0,
      int left = 0,
      int right = 0,
    }) {
      final image = _solid(w, h, 200, 30, 30);
      if (top > 0) {
        img.fillRect(
          image,
          x1: 0,
          y1: 0,
          x2: w - 1,
          y2: top - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      if (bottom > 0) {
        img.fillRect(
          image,
          x1: 0,
          y1: h - bottom,
          x2: w - 1,
          y2: h - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      if (left > 0) {
        img.fillRect(
          image,
          x1: 0,
          y1: 0,
          x2: left - 1,
          y2: h - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      if (right > 0) {
        img.fillRect(
          image,
          x1: w - right,
          y1: 0,
          x2: w - 1,
          y2: h - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      return image;
    }

    test('trims facing top/bottom bars to the content box', () {
      final out = removeLetterbox(bars(w: 100, h: 100, top: 20, bottom: 20));
      expect(out.width, 100);
      expect(out.height, 60);
      // Content survives: the middle row is still red.
      final px = out.getPixel(50, 30);
      expect(px.r.toInt(), 200);
    });

    test('trims facing left/right pillarbox bars', () {
      final out = removeLetterbox(bars(w: 100, h: 100, left: 15, right: 15));
      expect(out.width, 70);
      expect(out.height, 100);
    });

    test('plain frames pass through untouched', () {
      final out = removeLetterbox(_solid(90, 60, 200, 30, 30));
      expect(out.width, 90);
      expect(out.height, 60);
    });

    test('all-black covers are kept, not collapsed', () {
      final out = removeLetterbox(_solid(50, 50, 0, 0, 0));
      expect(out.width, 50);
      expect(out.height, 50);
    });

    test('single-edge darkness never trims', () {
      final out = removeLetterbox(bars(w: 100, h: 100, bottom: 20));
      expect(out.width, 100);
      expect(out.height, 100);
    });

    test('dark-but-not-black content is kept', () {
      final out = removeLetterbox(_solid(80, 80, 30, 30, 30));
      expect(out.width, 80);
      expect(out.height, 80);
    });
  });
}

String _shaForTest(String url) =>
    sha1.convert(utf8.encode(url)).toString();
