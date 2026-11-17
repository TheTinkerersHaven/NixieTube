// Fixture tests for the shared track-merge policy: the panel/catalog,
// cache and header-backfill behaviours all route through `mergeTrack`,
// so the precedence rules are pinned in one place.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/track_merge.dart';
import 'package:nixietube/core/models/models.dart';

Track _track({
  String videoId = 'v1',
  String title = 'Title',
  List<ArtistRef> artists = const [],
  AlbumRef? album,
  int durationSec = 0,
  List<Thumbnail> thumbnails = const [],
  bool explicit = false,
}) => Track(
  videoId: videoId,
  title: title,
  artists: artists,
  album: album,
  durationSec: durationSec,
  thumbnails: thumbnails,
  explicit: explicit,
);

Track _incoming({
  String title = '',
  List<ArtistRef> artists = const [],
  AlbumRef? album,
  int durationSec = 0,
  List<Thumbnail> thumbnails = const [],
  bool explicit = false,
}) => Track(
  videoId: 'v1',
  title: title,
  artists: artists,
  album: album,
  durationSec: durationSec,
  thumbnails: thumbnails,
  explicit: explicit,
);

void main() {
  group('artist policy', () {
    test('panel replaces a generic credit', () {
      final out = mergeTrack(
        _track(artists: const [ArtistRef('Release')]),
        _incoming(artists: const [ArtistRef('Real', browseId: 'UC1')]),
      );
      expect(out.artists.map((a) => a.name), ['Real']);
      expect(out.artists.single.browseId, 'UC1');
    });

    test('panel keeps a fuller linked credit', () {
      final current = _track(
        artists: const [
          ArtistRef('A', browseId: 'UC1'),
          ArtistRef('B', browseId: 'UC2'),
        ],
      );
      final out = mergeTrack(
        current,
        _incoming(artists: const [ArtistRef('A', browseId: 'UC1')]),
      );
      expect(out.artists.map((a) => a.name), ['A', 'B']);
    });

    test('panel upgrades an unlinked same-name credit', () {
      final out = mergeTrack(
        _track(artists: const [ArtistRef('A')]),
        _incoming(artists: const [ArtistRef('A', browseId: 'UC1')]),
      );
      expect(out.artists.single.browseId, 'UC1');
    });

    test('thin replaces a single unlinked name', () {
      final out = mergeTrack(
        _track(artists: const [ArtistRef('A')]),
        _incoming(artists: const [ArtistRef('B', browseId: 'UC2')]),
        const TrackMerge(artists: ArtistMerge.thin),
      );
      expect(out.artists.map((a) => a.name), ['B']);
    });

    test('thin keeps a multi-artist credit', () {
      final current = _track(
        artists: const [
          ArtistRef('A', browseId: 'UC1'),
          ArtistRef('B', browseId: 'UC2'),
        ],
      );
      final out = mergeTrack(
        current,
        _incoming(
          artists: const [
            ArtistRef('A', browseId: 'UC1'),
            ArtistRef('B', browseId: 'UC2'),
            ArtistRef('C', browseId: 'UC3'),
          ],
        ),
        const TrackMerge(artists: ArtistMerge.thin),
      );
      expect(out.artists.map((a) => a.name), ['A', 'B']);
    });

    test('fillMissing only fills an empty credit', () {
      const opts = TrackMerge(artists: ArtistMerge.fillMissing);
      expect(
        mergeTrack(
          _track(artists: const [ArtistRef('A')]),
          _incoming(artists: const [ArtistRef('B')]),
          opts,
        ).artists.map((a) => a.name),
        ['A'],
      );
      expect(
        mergeTrack(_track(), _incoming(artists: const [ArtistRef('B')]), opts)
            .artists
            .map((a) => a.name),
        ['B'],
      );
    });
  });

  group('album policy', () {
    test('preferred takes a linked incoming album', () {
      final out = mergeTrack(
        _track(album: const AlbumRef('Kept')),
        _incoming(
          album: const AlbumRef(
            'Other',
            browseId: 'MPRE1',
            kind: ReleaseKind.ep,
            year: '2024',
          ),
        ),
      );
      expect(out.album?.name, 'Other');
      expect(out.album?.browseId, 'MPRE1');
      expect(out.album?.kind, ReleaseKind.ep);
      expect(out.album?.year, '2024');
    });

    test('preferred keeps the current album when incoming is null', () {
      final current = _track(album: const AlbumRef('Kept'));
      final out = mergeTrack(current, _incoming());
      expect(out.album?.name, 'Kept');
    });

    test('fillMissing only fills a missing album', () {
      const opts = TrackMerge(album: AlbumMerge.fillMissing);
      expect(
        mergeTrack(
          _track(album: const AlbumRef('Kept')),
          _incoming(album: const AlbumRef('Other', kind: ReleaseKind.ep)),
          opts,
        ).album?.name,
        'Kept',
      );
      expect(
        mergeTrack(_track(), _incoming(album: const AlbumRef('Other')), opts)
            .album
            ?.name,
        'Other',
      );
    });

    test('fills a missing year on the kept album', () {
      final out = mergeTrack(
        _track(album: const AlbumRef('Kept', kind: ReleaseKind.album)),
        _incoming(album: const AlbumRef('Kept', kind: ReleaseKind.album, year: '2024')),
        const TrackMerge(album: AlbumMerge.fillMissing),
      );
      expect(out.album?.year, '2024');
    });
  });

  group('other fields', () {
    test('unions thumbnails by url', () {
      final out = mergeTrack(
        _track(thumbnails: const [Thumbnail('https://x/a.jpg')]),
        _incoming(
          thumbnails: const [
            Thumbnail('https://x/a.jpg'),
            Thumbnail('https://x/b.jpg'),
          ],
        ),
      );
      expect(out.thumbnails.map((t) => t.url), [
        'https://x/a.jpg',
        'https://x/b.jpg',
      ]);
    });

    test('fills a missing duration but never overwrites a known one', () {
      expect(
        mergeTrack(_track(durationSec: 200), _incoming(durationSec: 100))
            .durationSec,
        200,
      );
      expect(
        mergeTrack(_track(), _incoming(durationSec: 100)).durationSec,
        100,
      );
    });

    test('ORs the explicit flag', () {
      expect(mergeTrack(_track(), _incoming(explicit: true)).explicit, isTrue);
      expect(
        mergeTrack(_track(explicit: true), _incoming()).explicit,
        isTrue,
      );
    });

    test('incomingWins takes a non-empty incoming title', () {
      const opts = TrackMerge(title: TitleMerge.incomingWins);
      expect(mergeTrack(_track(title: 'Old'), _incoming(title: 'New'), opts)
          .title, 'New');
      expect(mergeTrack(_track(title: 'Old'), _incoming(), opts).title, 'Old');
    });

    test('preferredFeatured prefers the credited variant', () {
      final out = mergeTrack(
        _track(title: 'Song'),
        _incoming(title: 'Song (feat. X)'),
      );
      expect(out.title, 'Song (feat. X)');
    });

    test('returns the same instance when nothing changes', () {
      final current = _track(
        title: 'Song',
        artists: const [ArtistRef('A', browseId: 'UC1')],
        album: const AlbumRef('Album', kind: ReleaseKind.album, year: '2024'),
        durationSec: 200,
        explicit: true,
      );
      final out = mergeTrack(current, _incoming());
      expect(identical(out, current), isTrue);
    });
  });
}