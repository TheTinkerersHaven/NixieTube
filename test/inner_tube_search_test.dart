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

      final songs = result['Songs']!.cast<SongItem>();
      expect(songs.single.track.videoId, 'VID1');
      expect(songs.single.track.title, 'Kid Again');
      final artists = result['Artists']!.cast<BrowseItem>();
      expect(artists.single.browseId, 'UCARTIST');
      expect(result.containsKey('Albums/EP/Singles'), isFalse);
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
      final ids = result['Songs']!.cast<SongItem>().map((s) => s.track.videoId);
      expect(ids, contains('VID2'));
      expect(ids, contains('VID1'));
    });

    test('answers an empty result set without categories', () async {
      final client = mockDio((options) async {
        return (200, jsonEncode({'contents': <String, dynamic>{}}));
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      expect(await tube.search('nothing'), isEmpty);
    });
  });
}
