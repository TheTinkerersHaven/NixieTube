// The InnerTube search response normalization: the raw shelves of a
// search answer are grouped into the stable "Songs", "Albums/EP/Singles"
// and "Artists" categories, and the named recording is completed from
// the artist's catalog when the results lack it.
//
// Responses are scripted; no network involved.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';

import 'mock_dio.dart';

Map<String, dynamic> _run(String text, {String? videoId, String? browseId}) {
  final run = <String, dynamic>{'text': text};
  if (videoId != null) {
    run['navigationEndpoint'] = {
      'watchEndpoint': {'videoId': videoId},
    };
  }
  if (browseId != null) {
    run['navigationEndpoint'] = {
      'browseEndpoint': {'browseId': browseId},
    };
  }
  return run;
}

Map<String, dynamic> _col(List<Map<String, dynamic>> runs) => {
  'musicResponsiveListItemFlexColumnRenderer': {
    'text': {'runs': runs},
  },
};

Map<String, dynamic> _songRow(String title, String videoId, String artist) => {
  'musicResponsiveListItemRenderer': {
    'flexColumns': [
      _col([_run(title, videoId: videoId)]),
      _col([_run(artist, browseId: 'UCARTIST')]),
    ],
  },
};

Map<String, dynamic> _artistRow(String name) => {
  'musicResponsiveListItemRenderer': {
    'flexColumns': [
      _col([_run(name, browseId: 'UCARTIST')]),
    ],
  },
};

/// A search answer with one song row and one artist row.
Map<String, dynamic> _searchResponse({
  required List<Map<String, dynamic>> rows,
}) {
  return {
    'contents': {
      'tabbedSearchResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': [
                    {
                      'itemSectionRenderer': {'contents': rows},
                    },
                  ],
                },
              },
            },
          },
        ],
      },
    },
  };
}

/// A search answer whose first section is a top-result card shelf
/// (`musicCardShelfRenderer`), the way an unfiltered "All" search
/// answers when there is one obvious match.
Map<String, dynamic> _searchResponseWithCard(
  Map<String, dynamic> card, {
  List<Map<String, dynamic>> rows = const [],
}) {
  return {
    'contents': {
      'tabbedSearchResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': [
                    card,
                    if (rows.isNotEmpty)
                      {
                        'itemSectionRenderer': {'contents': rows},
                      },
                  ],
                },
              },
            },
          },
        ],
      },
    },
  };
}

/// A song top-result card: title in the header, "Song • Artist • Album •
/// m:ss" subtitle runs, card-level thumbnail, watch-endpoint onTap.
Map<String, dynamic> _songCard({
  String title = 'Kid Again',
  String videoId = 'VID9',
  String artist = 'Ivycomb',
  String artistId = 'UCARTIST',
  String album = 'Kid Again',
  String albumId = 'MPREALBUM',
  String duration = '3:45',
}) {
  return {
    'musicCardShelfRenderer': {
      'header': {
        'musicCardShelfHeaderBasicRenderer': {
          'title': {
            'runs': [
              {'text': title},
            ],
          },
        },
      },
      'title': {
        'runs': [
          {'text': title},
        ],
      },
      'subtitle': {
        'runs': [
          {'text': 'Song'},
          {'text': ' • '},
          {
            'text': artist,
            'navigationEndpoint': {
              'browseEndpoint': {'browseId': artistId},
            },
          },
          {'text': ' • '},
          {
            'text': album,
            'navigationEndpoint': {
              'browseEndpoint': {'browseId': albumId},
            },
          },
          {'text': ' • '},
          {'text': duration},
        ],
      },
      'thumbnail': {
        'musicThumbnailRenderer': {
          'thumbnails': [
            {'url': 'https://img/cover.jpg', 'width': 544, 'height': 544},
          ],
        },
      },
      'onTap': {
        'watchEndpoint': {'videoId': videoId},
      },
      'contents': [],
    },
  };
}

/// An artist top-result card: browse-endpoint onTap to the channel.
Map<String, dynamic> _artistCard({
  String name = 'Ivycomb',
  String browseId = 'UCARTIST',
}) {
  return {
    'musicCardShelfRenderer': {
      'header': {
        'musicCardShelfHeaderBasicRenderer': {
          'title': {
            'runs': [
              {'text': name},
            ],
          },
        },
      },
      'subtitle': {
        'runs': [
          {'text': 'Artist'},
        ],
      },
      'thumbnail': {
        'musicThumbnailRenderer': {
          'thumbnails': [
            {'url': 'https://img/artist.jpg', 'width': 544, 'height': 544},
          ],
        },
      },
      'onTap': {
        'browseEndpoint': {'browseId': browseId},
      },
      'contents': [],
    },
  };
}

/// A browse answer for an artist page.
Map<String, dynamic> _artistResponse(List<Map<String, dynamic>> topSongs) => {
  'contents': {
    'musicImmersiveHeaderRenderer': {
      'title': {
        'runs': [_run('Ivycomb')],
      },
    },
    'sectionListRenderer': {
      'contents': [
        {
          'musicShelfRenderer': {
            'title': {
              'runs': [_run('Songs')],
            },
            'contents': topSongs,
          },
        },
      ],
    },
  },
};

void main() {
  group('InnerTube.search', () {
    test('groups the rows into the stable categories', () async {
      final client = mockDio((options) async {
        return (
          200,
          jsonEncode(
            _searchResponse(
              rows: [
                _songRow('Kid Again', 'VID1', 'Ivycomb'),
                _artistRow('Ivycomb'),
              ],
            ),
          ),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('kid again ivycomb');

      final songs = result.sections['Songs']!.cast<SongItem>();
      expect(songs.single.track.videoId, 'VID1');
      expect(songs.single.track.title, 'Kid Again');
      final artists = result.sections['Artists']!.cast<BrowseItem>();
      expect(artists.single.browseId, 'UCARTIST');
      expect(result.sections.containsKey('Albums/EP/Singles'), isFalse);
      expect(result.bestMatch, isNull);
    });

    test('completes the named recording from the artist catalog', () async {
      var browseCalls = 0;
      final client = mockDio((options) async {
        if (options.uri.path.endsWith('/browse')) {
          browseCalls++;
          return (
            200,
            jsonEncode(
              _artistResponse([
                _songRow('Kid Again', 'VID2', 'Ivycomb'),
                _songRow('Other Song', 'VID3', 'Ivycomb'),
              ]),
            ),
          );
        }
        return (
          200,
          jsonEncode(
            _searchResponse(
              rows: [
                _songRow('Some Other Song', 'VID1', 'Ivycomb'),
                _artistRow('Ivycomb'),
              ],
            ),
          ),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('kid again ivycomb');

      expect(browseCalls, greaterThan(0));
      final ids = result.sections['Songs']!.cast<SongItem>().map(
        (s) => s.track.videoId,
      );
      expect(ids, contains('VID2'));
      expect(ids, contains('VID1'));
    });

    test('answers an empty result set without categories', () async {
      final client = mockDio((options) async {
        return (200, jsonEncode({'contents': <String, dynamic>{}}));
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('nothing');
      expect(result.sections, isEmpty);
      expect(result.bestMatch, isNull);
    });

    test('parses the top-result card shelf as the best match song', () async {
      final client = mockDio((options) async {
        return (
          200,
          jsonEncode(
            _searchResponseWithCard(
              _songCard(),
              rows: [_songRow('Other Song', 'VID1', 'Ivycomb')],
            ),
          ),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('kid again');

      final best = result.bestMatch;
      expect(best, isA<SongItem>());
      final track = (best as SongItem).track;
      expect(track.videoId, 'VID9');
      expect(track.title, 'Kid Again');
      expect(track.artists.single.name, 'Ivycomb');
      expect(track.artists.single.browseId, 'UCARTIST');
      expect(track.album?.name, 'Kid Again');
      expect(track.album?.browseId, 'MPREALBUM');
      expect(track.durationSec, 225); // 3:45
      expect(track.thumbnails.single.url, 'https://img/cover.jpg');
      // The card rows still land in the categories as before.
      expect(
        result.sections['Songs']!.cast<SongItem>().single.track.videoId,
        'VID1',
      );
    });

    test('parses an artist top-result card as the best match', () async {
      final client = mockDio((options) async {
        return (200, jsonEncode(_searchResponseWithCard(_artistCard())));
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('ivycomb');

      final best = result.bestMatch;
      expect(best, isA<BrowseItem>());
      final artist = best as BrowseItem;
      expect(artist.title, 'Ivycomb');
      expect(artist.browseId, 'UCARTIST');
      expect(artist.subtitle, 'Artist');
      expect(artist.bestArtwork, 'https://img/artist.jpg');
    });

    test('prefers the audio-only song when the card links to the video', () async {
      final client = mockDio((options) async {
        return (
          200,
          jsonEncode(
            _searchResponseWithCard(
              _songCard(videoId: 'VIDMV'), // the music video's id
              rows: [_songRow('Kid Again', 'VID9', 'Ivycomb')], // audio row
            ),
          ),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('kid again');

      final best = result.bestMatch;
      expect(best, isA<SongItem>());
      final track = (best as SongItem).track;
      // The audio-only recording wins over the music video…
      expect(track.videoId, 'VID9');
      expect(track.title, 'Kid Again');
      // …and keeps the card's artwork, since the row carries none.
      expect(track.thumbnails.single.url, 'https://img/cover.jpg');
    });

    test('keeps the card song when it already is the audio version', () async {
      final client = mockDio((options) async {
        return (
          200,
          jsonEncode(
            _searchResponseWithCard(
              _songCard(videoId: 'VID9'),
              rows: [_songRow('Kid Again', 'VID9', 'Ivycomb')],
            ),
          ),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('kid again');
      expect((result.bestMatch as SongItem).track.videoId, 'VID9');
    });

    test('a filtered search reports no best match', () async {
      final client = mockDio((options) async {
        return (
          200,
          jsonEncode(
            _searchResponseWithCard(
              _songCard(),
              rows: [_songRow('Kid Again', 'VID9', 'Ivycomb')],
            ),
          ),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final result = await tube.search('kid again', filter: 'songs');
      expect(result.bestMatch, isNull);
      expect(result.sections['Songs'], isNotEmpty);
    });

    test('a category filter is sent as the params token', () async {
      String? sentParams;
      String? sentQuery;
      final client = mockDio((options) async {
        expect(options.uri.path, endsWith('/search'));
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        sentQuery = body['query'] as String;
        sentParams = body['params'] as String?;
        return (200, jsonEncode(_searchResponse(rows: [_songRow('Kid Again', 'VID1', 'Ivycomb')])));
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      await tube.search('kid again', filter: 'songs');
      expect(sentQuery, 'kid again');
      expect(sentParams, searchFilterParams['songs']);
      expect(sentParams, startsWith('EgWKAQ'));

      await tube.search('kid again');
      expect(sentParams, isNull);
    });
  });

  group('InnerTube.searchSuggestions', () {
    test('parses suggestion runs from get_search_suggestions', () async {
      final client = mockDio((options) async {
        expect(options.uri.path, endsWith('/music/get_search_suggestions'));
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        expect(body['input'], 'ivy');
        return (
          200,
          jsonEncode({
            'contents': [
              {
                'searchSuggestionsSectionRenderer': {
                  'contents': [
                    {
                      'searchSuggestionRenderer': {
                        'suggestion': {
                          'runs': [
                            {'text': 'ivy'},
                            {'text': 'comb'},
                          ],
                        },
                      },
                    },
                    {
                      'searchSuggestionRenderer': {
                        'suggestion': 'ivycomb songs',
                      },
                    },
                  ],
                },
              },
            ],
          }),
        );
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      expect(
        await tube.searchSuggestions('ivy'),
        ['ivycomb', 'ivycomb songs'],
      );
    });

    test('an empty answer yields no suggestions', () async {
      final client = mockDio((_) async => (200, jsonEncode({'contents': []})));
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);
      expect(await tube.searchSuggestions('x'), isEmpty);
    });
  });
}
