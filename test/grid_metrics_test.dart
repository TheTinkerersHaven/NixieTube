// Tests for the quick-picks grid metrics shared with the liked-list
// height cut: both sides must agree on the rendered grid height. The grid
// never repeats an item, so rows shrink below three when distinct sources
// are few.
//
// Also covers the fill algorithm: pseudo-random, no repeats, prefers the
// most recent (front of each pool) items, and never places two non-song
// entries (albums/artists/playlists) adjacent.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/screens/home_screen.dart'
    show
        buildQuickPickItems,
        fillQuickPicks,
        isSingleRelease,
        quickPickMetrics,
        quickPicksHeight;

List<ShelfItem> _songs(int n) => [
      for (var i = 0; i < n; i++)
        ShelfItem.song(Track(videoId: 'v$i', title: 's$i')),
    ];

List<ShelfItem> _browse(int n, String prefix) => [
      for (var i = 0; i < n; i++)
        ShelfItem.browse(
          title: '$prefix$i',
          subtitle: '',
          browseId: '$prefix$i',
          thumbnails: const [],
        ),
    ];

void main() {
  group('quickPickMetrics', () {
    test('columns clamp to 3..6', () {
      expect(quickPickMetrics(400, 18).cols, 3);
      expect(quickPickMetrics(1200, 18).cols, 6);
      expect(quickPickMetrics(700, 18).cols, 4);
    });

    test('rows shrink when distinct sources are few', () {
      // Plenty of sources: three full rows.
      expect(quickPickMetrics(1200, 18).rows, 3);
      expect(quickPickMetrics(1200, 18).shown, 18);
      // Few sources: fewer rows, never more than available.
      expect(quickPickMetrics(1200, 5).rows, 1);
      expect(quickPickMetrics(1200, 5).shown, 5);
      expect(quickPickMetrics(700, 8).rows, 2);
      // No content at all: nothing renders.
      expect(quickPickMetrics(1200, 0).rows, 0);
      expect(quickPickMetrics(1200, 0).shown, 0);
    });

    test('height matches header plus the tile grid', () {
      // 1200px grid: 6 cols, 200px tiles, 3 rows -> 56 + 600.
      expect(quickPicksHeight(1200, 18), 56 + 600);
      // 1 row at 1200px -> 56 + 200.
      expect(quickPicksHeight(1200, 5), 56 + 200);
      expect(quickPicksHeight(1200, 0), 56);
    });
  });

  group('fillQuickPicks', () {
    test('fills up to the requested slots, never more than sources', () {
      // 14 distinct sources, 18 slots requested -> exactly 14, no repeats.
      final out = fillQuickPicks(_songs(8), _browse(6, 'b'), 18, rng: Random(1));
      expect(out.length, 14);
      expect(out.toSet().length, out.length); // all distinct
    });

    test('never repeats an item', () {
      final out = fillQuickPicks(_songs(6), _browse(5, 'b'), 11, rng: Random(3));
      expect(out.toSet().length, out.length);
    });

    test('never places two non-song entries adjacent', () {
      for (var seed = 0; seed < 20; seed++) {
        final out = fillQuickPicks(
          _songs(8),
          [..._browse(4, 'al'), ..._browse(4, 'ar'), ..._browse(4, 'pl')],
          18,
          rng: Random(seed),
        );
        for (var i = 1; i < out.length; i++) {
          final adjacentNonSongs =
              out[i - 1] is BrowseItem && out[i] is BrowseItem;
          expect(adjacentNonSongs, isFalse,
              reason: 'seed $seed: adjacent non-songs at $i');
        }
      }
    });

    test('prefers recent items over older ones', () {
      final songs = _songs(6); // s0 most recent … s5 oldest
      final nonSongs = _browse(3, 'a'); // a0 most recent
      // Only 6 of the 9 distinct sources fit: the oldest song (s5) and
      // older non-songs must be left out.
      final out = fillQuickPicks(songs, nonSongs, 6, rng: Random(7));
      expect(out.length, 6);
      expect(out.contains(songs[5]), isFalse, reason: 'oldest song skipped');
      expect(out.contains(nonSongs[0]), isTrue, reason: 'recent album kept');
    });

    test('includes both songs and browsable entries', () {
      final out = fillQuickPicks(_songs(6), _browse(5, 'b'), 11, rng: Random(9));
      expect(out.any((e) => e is SongItem), isTrue);
      expect(out.any((e) => e is BrowseItem), isTrue);
    });
  });

  group('buildQuickPickItems', () {
    String key(ShelfItem item) => item is SongItem
        ? 's:${item.track.videoId}'
        : 'b:${(item as BrowseItem).browseId}';

    test('pins come first in pin order', () {
      final out = buildQuickPickItems(
        pins: [_songs(8)[5], _browse(6, 'b')[2]],
        songs: _songs(8),
        nonSongs: _browse(6, 'b'),
        slots: 6,
        rng: Random(1),
      );
      expect(out.length, 6);
      expect(key(out[0]), 's:v5');
      expect(key(out[1]), 'b:b2');
    });

    test('pinned ids are excluded from pools (no repeats)', () {
      final out = buildQuickPickItems(
        pins: [..._songs(8), ..._browse(6, 'b')],
        songs: _songs(8),
        nonSongs: _browse(6, 'b'),
        slots: 18,
        rng: Random(1),
      );
      final keys = out.map(key).toList();
      expect(keys.toSet().length, keys.length);
      expect(out.length, 14);
    });

    test('pins beyond slots are cut', () {
      final out = buildQuickPickItems(
        pins: _songs(8),
        songs: _songs(8),
        nonSongs: _browse(6, 'b'),
        slots: 3,
        rng: Random(1),
      );
      expect(out.map(key), ['s:v0', 's:v1', 's:v2']);
    });

    test('no pins behaves like fillQuickPicks', () {
      final a = buildQuickPickItems(
        pins: const [],
        songs: _songs(8),
        nonSongs: _browse(6, 'b'),
        slots: 10,
        rng: Random(4),
      );
      final b = fillQuickPicks(_songs(8), _browse(6, 'b'), 10, rng: Random(4));
      expect(a.map(key), b.map(key));
    });
  });

  group('isSingleRelease', () {
    Track song(String id, String title, {AlbumRef? album}) => Track(
          videoId: id,
          title: title,
          album: album,
        );

    test('explicit Single kind counts', () {
      expect(
        isSingleRelease(
          song('v1', 'Some Song',
              album: const AlbumRef('Some Song',
                  browseId: 'MPRE1', kind: ReleaseKind.single)),
        ),
        isTrue,
      );
    });

    test('EPs, albums and unknown kinds never count, even same-named', () {
      for (final kind in [
        ReleaseKind.ep,
        ReleaseKind.album,
        ReleaseKind.compilation,
        null,
      ]) {
        expect(
          isSingleRelease(
            song('v1', 'Neon Sky',
                album: AlbumRef('Neon Sky', browseId: 'MPRE1', kind: kind)),
          ),
          isFalse,
          reason: 'kind $kind',
        );
      }
    });

    test('tracks without albums do not count', () {
      expect(isSingleRelease(song('v1', 'No Album Song')), isFalse);
    });
  });
}
