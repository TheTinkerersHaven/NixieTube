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
      await File('${dir.path}/$hex.img')
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
      expect(store.cachedFile(url), isNotNull);
    });
  });
}

String _shaForTest(String url) =>
    sha1.convert(utf8.encode(url)).toString();
