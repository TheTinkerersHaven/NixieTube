// Tests for the quick-picks grid metrics shared with the liked-list
// height cut: both sides must agree on the rendered grid height. The grid
// never repeats an item, so rows shrink below three when distinct sources
// are few.
//
// Also covers the ordering algorithm: user pins first, then pool songs
// most-recent-first with same-cover tracks held back for the fill pass,
// so the same artwork never shows twice unless sources run dry.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/screens/home_screen.dart'
    show
        orderQuickPicks,
        pickArtKey,
        quickPickMetrics,
        quickPicksHeight,
        rankPickSongs;

List<ShelfItem> _songs(int n) => [
  for (var i = 0; i < n; i++)
    ShelfItem.song(Track(videoId: 'v$i', title: 's$i')),
];

/// Songs with covers: [coverOf] maps the song index to a cover id.
/// Same id means the same artwork (different size suffixes still match).
List<ShelfItem> _coveredSongs(int n, String Function(int i) coverOf) => [
  for (var i = 0; i < n; i++)
    ShelfItem.song(
      Track(
        videoId: 'v$i',
        title: 's$i',
        thumbnails: [
          Thumbnail(
            'https://x/${coverOf(i)}.jpg=w60-h60-l90-rj',
            width: 60,
            height: 60,
          ),
        ],
      ),
    ),
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

String _key(ShelfItem item) => item is SongItem
    ? 's:${item.track.videoId}'
    : 'b:${(item as BrowseItem).browseId}';

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

  group('pickArtKey', () {
    Track cover(String id, String size) => Track(
      videoId: 'v-$id-$size',
      title: 't',
      thumbnails: [
        Thumbnail('https://x/$id.jpg=$size-l90-rj', width: 60, height: 60),
      ],
    );

    test('same cover at different sizes shares a key', () {
      expect(
        pickArtKey(cover('a', 'w60-h60')),
        pickArtKey(cover('a', 'w540-h540')),
      );
    });

    test('different covers differ', () {
      expect(
        pickArtKey(cover('a', 'w60-h60')),
        isNot(pickArtKey(cover('b', 'w60-h60'))),
      );
    });

    test('art-less tracks key on their own id', () {
      const t1 = Track(videoId: 'v1', title: 't');
      const t2 = Track(videoId: 'v2', title: 't');
      expect(pickArtKey(t1), isNot(pickArtKey(t2)));
    });
  });

  group('rankPickSongs', () {
    Track activityTrack(String id) =>
        Track(videoId: id, title: 'Title $id', artists: const []);

    test('tiers replayed recent, then recent, then old', () {
      // v0 x10 plays, v1 x1, v2 unplayed-but-recent, like o1 old.
      final out = rankPickSongs(
        activity: [
          activityTrack('v0'),
          activityTrack('v1'),
          activityTrack('v2'),
        ],
        liked: [activityTrack('o1'), activityTrack('v1')],
        history: const [],
        counts: {'v0': 10, 'v1': 1},
      );
      expect(out.map(_key), ['s:v0', 's:v1', 's:v2', 's:o1']);
    });

    test('liked songs already recent are not duplicated as old', () {
      final out = rankPickSongs(
        activity: [activityTrack('v0')],
        liked: [activityTrack('v0'), activityTrack('o1')],
        history: const [],
        counts: const {},
      );
      expect(out.map(_key), ['s:v0', 's:o1']);
    });

    test('history tracks join by count, activity metadata wins', () {
      // h1 replayed on another device (x7) tops tier 1 even though it
      // is absent from activity; h2 played once long ago lands old.
      // v1 exists in both: the activity copy (fresher title) is kept.
      final out = rankPickSongs(
        activity: [activityTrack('v0'), activityTrack('v1')],
        liked: [activityTrack('o1')],
        history: [
          Track(videoId: 'h1', title: 'Hist One', artists: const []),
          Track(videoId: 'h2', title: 'Hist Two', artists: const []),
          Track(videoId: 'v1', title: 'Stale Title', artists: const []),
        ],
        counts: {'h1': 7, 'v0': 3},
      );
      expect(out.map(_key), ['s:h1', 's:v0', 's:v1', 's:o1', 's:h2']);
      final v1 = out.whereType<SongItem>().firstWhere(
        (e) => e.track.videoId == 'v1',
      );
      expect(v1.track.title, 'Title v1');
    });

    test('pool caps at the requested size', () {
      final out = rankPickSongs(
        activity: [for (var i = 0; i < 10; i++) activityTrack('v$i')],
        liked: const [],
        history: const [],
        counts: const {},
        cap: 4,
      );
      // First 4 in FNV hash order (deterministic everywhere).
      expect(out.map(_key), ['s:v9', 's:v8', 's:v1', 's:v0']);
    });

    test('each tier orders by hash nonce, boundaries hold', () {
      List<ShelfItem> run(int nonce) => rankPickSongs(
        activity: [for (var i = 0; i < 6; i++) activityTrack('v$i')],
        liked: const [],
        history: const [],
        counts: {'v0': 5, 'v1': 5, 'v2': 5, 'v3': 5, 'v4': 5},
        nonce: nonce,
      );
      final a = run(1373158606).map(_key).toList();
      final b = run(239081663).map(_key).toList();
      // Same tier sets on both nonces…
      expect(a.take(5).toSet(), {'s:v0', 's:v1', 's:v2', 's:v3', 's:v4'});
      expect(b.take(5).toSet(), {'s:v0', 's:v1', 's:v2', 's:v3', 's:v4'});
      expect(a.skip(5).toSet(), {'s:v5'});
      // …but ordered differently within the tier (FNV is deterministic
      // everywhere, so these exact orders are safe to pin).
      expect(a.take(5).toList(), ['s:v0', 's:v1', 's:v2', 's:v3', 's:v4']);
      expect(b.take(5).toList(), ['s:v4', 's:v3', 's:v2', 's:v1', 's:v0']);
      // Same nonce is stable across calls.
      expect(run(1373158606).map(_key).toList(), a);
    });

    test('pool growth keeps existing relative order', () {
      List<String> keys(List<Track> activity) => rankPickSongs(
        activity: activity,
        liked: const [],
        history: const [],
        counts: const {},
        nonce: 7,
      ).map(_key).toList();
      final base = keys([for (var i = 0; i < 6; i++) activityTrack('v$i')]);
      final grown = keys([
        for (var i = 0; i < 6; i++) activityTrack('v$i'),
        activityTrack('vNew'),
      ]);
      // Newcomers slot in by hash rank; existing tiles never move
      // relative to each other (this is what stops background
      // refreshes from scrambling the grid).
      expect(grown.where(base.contains).toList(), base);
    });

    test('default nonce is deterministic', () {
      List<String> keys() => rankPickSongs(
        activity: [for (var i = 0; i < 4; i++) activityTrack('v$i')],
        liked: const [],
        history: const [],
        counts: {'v3': 9},
      ).map(_key).toList();
      final a = keys();
      final b = keys();
      expect(a, b);
      // v3 replayed still leads its tier.
      expect(a.first, 's:v3');
    });
  });

  group('orderQuickPicks', () {
    test('pins come first in pin order', () {
      final out = orderQuickPicks(
        pins: [_songs(8)[5], _browse(6, 'b')[2]],
        songs: _songs(8),
        slots: 6,
      );
      expect(out.length, 6);
      expect(_key(out[0]), 's:v5');
      expect(_key(out[1]), 'b:b2');
    });

    test('pinned ids are excluded from the pool (no repeats)', () {
      final out = orderQuickPicks(
        pins: [..._songs(8), ..._browse(6, 'b')],
        songs: _songs(8),
        slots: 18,
      );
      final keys = out.map(_key).toList();
      expect(keys.toSet().length, keys.length);
      // All 14 pins; the pool is fully excluded, nothing left to add.
      expect(out.length, 14);
    });

    test('pins beyond slots are cut', () {
      final out = orderQuickPicks(pins: _songs(8), songs: _songs(8), slots: 3);
      expect(out.map(_key), ['s:v0', 's:v1', 's:v2']);
    });

    test('same-cover songs wait for the fill pass', () {
      // s0..s2 share cover A, s3 has cover B. Four slots: the diverse
      // pass takes s0 (A) and s3 (B); s1/s2 backfill the rest.
      final songs = _coveredSongs(4, (i) => i < 3 ? 'A' : 'B');
      final out = orderQuickPicks(pins: const [], songs: songs, slots: 4);
      expect(out.map(_key), ['s:v0', 's:v3', 's:v1', 's:v2']);
    });

    test('tight slots still fill when sources run dry', () {
      // Three tracks, one cover, two slots: the diverse pass takes
      // one, the fill pass takes the next — a duplicate cover beats
      // an empty cell.
      final songs = _coveredSongs(3, (_) => 'A');
      final out = orderQuickPicks(pins: const [], songs: songs, slots: 2);
      expect(out.map(_key), ['s:v0', 's:v1']);
    });

    test('pool covers matching a pin wait too', () {
      final pin = _coveredSongs(1, (_) => 'A');
      final songs = _coveredSongs(3, (_) => 'A');
      final out = orderQuickPicks(pins: pin, songs: songs, slots: 3);
      // Pool s:v0 is the pin itself (excluded by id); s:v1/s:v2 share
      // its cover, so the fill pass places them after.
      expect(out.map(_key), ['s:v0', 's:v1', 's:v2']);
    });

    test('pool order is kept as ranked', () {
      final out = orderQuickPicks(pins: const [], songs: _songs(6), slots: 6);
      expect(out.map(_key), ['s:v0', 's:v1', 's:v2', 's:v3', 's:v4', 's:v5']);
    });

    test('empty pool renders pins only', () {
      final out = orderQuickPicks(
        pins: [..._browse(2, 'b')],
        songs: const [],
        slots: 6,
      );
      expect(out.map(_key), ['b:b0', 'b:b1']);
    });
  });
}
