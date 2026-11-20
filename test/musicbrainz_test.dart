// Tests for the MusicBrainz release lookup: parsing, cache and failure
// behaviour.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/musicbrainz.dart';

import 'mock_dio.dart';

void main() {
  test('lookupRelease parses the release facts and caches them', () async {
    var calls = 0;
    final musicbrainz = MusicBrainzService(
      dio: mockDio((options) async {
        calls++;
        expect(
          options.uri.queryParameters['query'],
          'release:"Random Access Memories" AND artist:"Daft Punk"',
        );
        return (
          200,
          jsonEncode({
            'releases': [
              {
                'id': 'mbid-1',
                'title': 'Random Access Memories',
                'date': '2013-05-17',
                'country': 'GB',
                'label-info': [
                  {
                    'label': {'name': 'Columbia'},
                  },
                ],
                'release-group': {
                  'primary-type': 'Album',
                  'secondary-types': ['Remix'],
                },
              },
            ],
          }),
        );
      }),
    );

    final release = await musicbrainz.lookupRelease(
      'Daft Punk',
      'Random Access Memories',
    );
    expect(release, isNotNull);
    expect(release!.date, '2013-05-17');
    expect(release.label, 'Columbia');
    expect(release.country, 'GB');
    expect(release.primaryType, 'Album');
    expect(release.secondaryTypes, ['Remix']);

    // A second lookup is served from the cache.
    final again = await musicbrainz.lookupRelease(
      'Daft Punk',
      'Random Access Memories',
    );
    expect(again, same(release));
    expect(calls, 1);
  });

  test('year hint picks the matching edition', () async {
    final musicbrainz = MusicBrainzService(
      dio: mockDio(
        (_) async => (
          200,
          jsonEncode({
            'releases': [
              {'title': 'Random Access Memories', 'date': '2023-05-12'},
              {'title': 'Random Access Memories', 'date': '2013-05-17'},
            ],
          }),
        ),
      ),
    );
    final release = await musicbrainz.lookupRelease(
      'Daft Punk',
      'Random Access Memories',
      year: '2013',
    );
    expect(release!.date, '2013-05-17');
  });

  test('without a year hint the earliest release wins', () async {
    final musicbrainz = MusicBrainzService(
      dio: mockDio(
        (_) async => (
          200,
          jsonEncode({
            'releases': [
              {'title': 'Random Access Memories', 'date': '2023-05-12'},
              {'title': 'Random Access Memories', 'date': '2013-05-17'},
            ],
          }),
        ),
      ),
    );
    final release = await musicbrainz.lookupRelease(
      'Daft Punk',
      'Random Access Memories',
    );
    expect(release!.date, '2013-05-17');
  });

  test('no release match yields null', () async {
    final musicbrainz = MusicBrainzService(
      dio: mockDio((_) async => (200, jsonEncode({'releases': []}))),
    );
    expect(await musicbrainz.lookupRelease('Nobody', 'Nothing'), isNull);
  });

  test('a failed request yields null', () async {
    final musicbrainz = MusicBrainzService(
      dio: mockDio((_) async => (503, 'busy')),
    );
    expect(await musicbrainz.lookupRelease('Nobody', 'Nothing'), isNull);
  });

  test('blank artist or album skips the request', () async {
    var calls = 0;
    final musicbrainz = MusicBrainzService(
      dio: mockDio((_) async {
        calls++;
        return (200, '{}');
      }),
    );
    expect(await musicbrainz.lookupRelease('', 'Album'), isNull);
    expect(await musicbrainz.lookupRelease('Artist', ''), isNull);
    expect(calls, 0);
  });
}
