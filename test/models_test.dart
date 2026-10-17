// Pure-Dart model tests mirroring the Kotlin suites:
// thumbnail squareness/upscaling, rating parsing, artwork preference.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';

void main() {
  group('Thumbnail.isSquare', () {
    test('explicit dimensions win', () {
      expect(
        const Thumbnail('https://x/y', width: 60, height: 60).isSquare,
        isTrue,
      );
      expect(
        const Thumbnail('https://x/y', width: 60, height: 40).isSquare,
        isFalse,
      );
    });

    test('falls back to the =w-h URL suffix', () {
      expect(const Thumbnail('https://x/y=w540-h540-l90-rj').isSquare, isTrue);
      expect(const Thumbnail('https://x/y=w480-h360').isSquare, isFalse);
      expect(const Thumbnail('https://x/plain.jpg').isSquare, isFalse);
    });
  });

  group('Thumbnail.upscaledTo', () {
    test('never downscales or distorts', () {
      const t = Thumbnail(
        'https://x/y=w540-h540-l90-rj',
        width: 540,
        height: 540,
      );
      expect(identical(t.upscaledTo(60), t), isTrue);
      expect(identical(t.upscaledTo(0), t), isTrue);
    });

    test('rewrites known w/h proportionally', () {
      const t = Thumbnail('https://x/y=w60-h60-l90-rj', width: 60, height: 60);
      final up = t.upscaledTo(540);
      expect(up.url, contains('=w540-h540'));
    });

    test('appends a width request when no size param exists', () {
      const t = Thumbnail('https://x/plain.jpg');
      expect(t.upscaledTo(540).url, 'https://x/plain.jpg=w540');
    });
  });

  group('RatingStatus.fromValue', () {
    test('maps raw strings', () {
      expect(RatingStatus.fromValue('LIKE'), RatingStatus.like);
      expect(RatingStatus.fromValue(' dislike '), RatingStatus.dislike);
      expect(RatingStatus.fromValue('NONE'), RatingStatus.indifferent);
      expect(RatingStatus.fromValue('removed'), RatingStatus.indifferent);
      expect(RatingStatus.fromValue(null), RatingStatus.unknown);
      expect(RatingStatus.fromValue('bogus'), RatingStatus.unknown);
    });
  });

  group('Track artwork', () {
    test('displayArtwork prefers a square cover over larger frames', () {
      const t = Track(
        videoId: 'v',
        title: 't',
        thumbnails: [
          Thumbnail('https://x/wide.jpg', width: 480, height: 360),
          Thumbnail('https://x/sq.jpg=w100-h100', width: 100, height: 100),
        ],
      );
      expect(t.displayArtwork, 'https://x/sq.jpg=w100-h100');
      expect(t.bestArtwork, 'https://x/wide.jpg');
    });

    test('displayArtwork falls back to the largest available', () {
      const t = Track(
        videoId: 'v',
        title: 't',
        thumbnails: [Thumbnail('https://x/wide.jpg', width: 480, height: 360)],
      );
      expect(t.displayArtwork, 'https://x/wide.jpg');
    });

    test('missing dimensions resolve to the last thumb', () {
      // No width/height anywhere (some responses omit them): YouTube
      // orders sizes ascending, so the final entry is the biggest.
      const t = Track(
        videoId: 'v',
        title: 't',
        thumbnails: [
          Thumbnail('https://x/a.jpg=w60-h60-l90-rj'),
          Thumbnail('https://x/a.jpg=w120-h120-l90-rj'),
          Thumbnail('https://x/a.jpg=w544-h544-l90-rj'),
        ],
      );
      expect(t.displayArtwork, 'https://x/a.jpg=w544-h544-l90-rj');
      expect(t.bestArtwork, 'https://x/a.jpg=w544-h544-l90-rj');
    });

    test('artistNames joins with commas', () {
      const t = Track(
        videoId: 'v',
        title: 't',
        artists: [ArtistRef('A'), ArtistRef('B')],
      );
      expect(t.artistNames(), 'A, B');
    });
  });
}
