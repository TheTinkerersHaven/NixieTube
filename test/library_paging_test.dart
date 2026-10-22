// Library paging: the liked-songs list and playlist tracks are served
// one shelf page at a time, so the client must follow the shelf's own
// continuation token instead of stopping at the first page (or
// following a token that belongs to a different shelf).
//
// The liked list reads YouTube's "Liked Music" playlist in its
// "Newest first" order, so the list reads newest-like first.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';

import 'mock_dio.dart';

/// One shelf row: a titled track, optionally with the like timestamp
/// the liked-music playlist carries.
Map<String, dynamic> _row(
  String videoId,
  String title, {
  int? likedAt,
  String? duration,
}) => {
  'musicResponsiveListItemRenderer': {
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': title},
            ],
          },
        },
      },
    ],
    'navigationEndpoint': {
      'watchEndpoint': {'videoId': videoId},
    },
    if (likedAt != null)
      'playlistItemData': {
        'videoId': videoId,
        'voteSortValue': likedAt,
      },
    if (duration != null)
      'fixedColumns': [
        {
          'musicResponsiveListItemFixedColumnRenderer': {
            'text': {
              'runs': [
                {'text': duration},
              ],
            },
          },
        },
      ],
  },
};

/// A shelf page: the rows plus, optionally, a trailing continuation row
/// and a section-level continuation that belongs to another shelf.
Map<String, dynamic> _shelfPage(
  List<String> titles,
  String? token, {
  String renderer = 'musicShelfRenderer',
  String? sectionToken,
  String idPrefix = 'v',
}) {
  final contents = <Map<String, dynamic>>[
    for (var i = 0; i < titles.length; i++) _row('$idPrefix$i', titles[i]),
  ];
  if (token != null) {
    contents.add({
      'continuationItemRenderer': {
        'continuationEndpoint': {
          'continuationCommand': {'token': token},
        },
      },
    });
  }
  return {
    'contents': {
      'singleColumnBrowseResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': [
                    {renderer: {'contents': contents}},
                  ],
                  if (sectionToken != null)
                    'continuations': [
                      {
                        'nextContinuationData': {'continuation': sectionToken},
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

/// A liked-music page: rows carrying their like timestamp.
Map<String, dynamic> _likedPage(
  List<(String, String, int)> rows,
  String? token,
) {
  final contents = <Map<String, dynamic>>[
    for (final (id, title, likedAt) in rows) _row(id, title, likedAt: likedAt),
  ];
  if (token != null) {
    contents.add(<String, dynamic>{
      'continuationItemRenderer': <String, dynamic>{
        'continuationEndpoint': <String, dynamic>{
          'continuationCommand': <String, dynamic>{'token': token},
        },
      },
    });
  }
  return <String, dynamic>{
    'contents': <String, dynamic>{
      'twoColumnBrowseResultsRenderer': <String, dynamic>{
        'secondaryContents': <String, dynamic>{
          'sectionListRenderer': <String, dynamic>{
            'contents': <dynamic>[
              <String, dynamic>{
                'musicPlaylistShelfRenderer': <String, dynamic>{
                  'contents': contents,
                },
              },
            ],
          },
        },
      },
    },
  };
}

/// The "Liked Music" playlist page, with the sort options it ships in
/// `frameworkUpdates` (the "Newest first" reload is the one the
/// client asks for) and the song count its header reports.
Map<String, dynamic> _playlistPage(
  List<(String, String, int)> rows, {
  String? token,
  int? songCount,
}) {
  final page = _likedPage(rows, token);
  page['frameworkUpdates'] = {
    'entityBatchUpdate': {
      'mutations': [
        {
          'entityKey': base64.encode(
            utf8.encode(
              'music_sort_option_command_entity_key_VLLM_NEWEST_ADDED',
            ),
          ),
          'payload': {
            'commandEntity': {
              'command': {
                'browseSectionListReloadEndpoint': {
                  'continuation': {
                    'reloadContinuationData': {'continuation': 'sort-newest'},
                  },
                },
              },
            },
          },
        },
      ],
    },
  };
  if (songCount != null) {
    page['contents']['twoColumnBrowseResultsRenderer']['secondaryContents']
        ['sectionListRenderer']['contents'][0]['musicPlaylistShelfRenderer']
        ['header'] = <String, dynamic>{
      'musicResponsiveHeaderRenderer': <String, dynamic>{
        'secondSubtitle': <String, dynamic>{
          'runs': <Map<String, dynamic>>[
            <String, dynamic>{'text': '$songCount songs'},
            <String, dynamic>{'text': ' • '},
            <String, dynamic>{'text': '6+ hours'},
          ],
        },
      },
    };
  }
  return page;
}

/// Serves the liked-songs pages: the "Liked Music" playlist page and
/// its "Newest first" reload.
class _LikedServer {
  _LikedServer({
    this.playlist = const [],
    this.nextPage = const [],
    this.songCount,
  });

  /// Rows of the playlist in its newest-first order.
  final List<(String, String, int)> playlist;

  /// Rows of the playlist's next page.
  final List<(String, String, int)> nextPage;

  /// The song count the playlist page reports ("524 songs").
  final int? songCount;

  int calls = 0;

  (int, Object) handle(String body) {
    calls++;
    final parsed = jsonDecode(body) as Map<String, dynamic>;
    final continuation = parsed['continuation'];
    if (continuation == 'sort-newest') {
      return (
        200,
        jsonEncode(_likedPage(playlist, 'tok1')),
      );
    }
    if (continuation == 'tok1') {
      return (
        200,
        jsonEncode(_likedPage(nextPage, null)),
      );
    }
    return (200, jsonEncode(_playlistPage(const [], songCount: songCount)));
  }
}

void main() {
  final auth = const AuthSession(cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc');

  group('liked songs paging', () {
    test('follows the shelf token across pages', () async {
      final server = _LikedServer(
        playlist: [('a', 'a', 400), ('b', 'b', 300)],
        nextPage: [('c', 'c', 200), ('d', 'd', 100)],
      );
      final client = mockDio((options) async => server.handle(options.data as String));
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos();
      // Newest like first, across both pages.
      expect(liked.map((t) => t.title).toList(), ['a', 'b', 'c', 'd']);
      // The playlist page, its sorted shelf and that shelf's next page.
      expect(server.calls, 3);
      tube.close();
    });

    test('stops when the shelf runs out of tokens', () async {
      final server = _LikedServer(playlist: [('a', 'a', 100)]);
      final client = mockDio((options) async => server.handle(options.data as String));
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos(max: 1);
      expect(liked.map((t) => t.title).toList(), ['a']);
      tube.close();
    });

    test('honours the max cap', () async {
      final server = _LikedServer(
        playlist: [('a', 'a', 100), ('b', 'b', 200), ('c', 'c', 300)],
      );
      final client = mockDio((options) async => server.handle(options.data as String));
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos(max: 2);
      expect(liked.length, 2);
      expect(server.calls, 2);
      tube.close();
    });
  });

  group('liked songs source', () {
    test('reads the playlist in its newest-first order', () async {
      final client = mockDio((options) async {
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        if (body['continuation'] == 'sort-newest') {
          return (
            200,
            jsonEncode(_likedPage([('a', 'Newest', 300)], null)),
          );
        }
        expect(body['browseId'], 'VLLM');
        return (200, jsonEncode(_playlistPage([('x', 'x', 1)])));
      });
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos(max: 1);
      expect(liked.map((t) => t.title).toList(), ['Newest']);
      tube.close();
    });

    test('reports the playlist count from its header', () async {
      final server = _LikedServer(
        playlist: [('a', 'Playlist song', 200)],
        songCount: 524,
      );
      final client = mockDio((options) async => server.handle(options.data as String));
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos();
      expect(liked.map((t) => t.title).toList(), ['Playlist song']);
      // The playlist header counts every entry, the shelf renders
      // fewer — the app reports the playlist's own count.
      expect(tube.likedCount, 524);
      tube.close();
    });

    test('orders the playlist rows by like timestamp', () async {
      final server = _LikedServer(
        playlist: [
          ('a', 'Older', 100),
          ('b', 'Newest', 300),
          ('c', 'Middle', 200),
        ],
      );
      final client = mockDio((options) async => server.handle(options.data as String));
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos();
      expect(liked.map((t) => t.title).toList(), ['Newest', 'Middle', 'Older']);
      tube.close();
    });

    test('keeps a song listed twice only once', () async {
      final server = _LikedServer(
        playlist: [('v0', 'Repeat', 100)],
        nextPage: [('v0', 'Repeat', 100)],
      );
      final client = mockDio((options) async => server.handle(options.data as String));
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos();
      expect(liked.map((t) => t.title).toList(), ['Repeat']);
      tube.close();
    });

    test('keeps the duration the row carries in its fixed column', () async {
      final client = mockDio((options) async {
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        if (body['continuation'] == 'sort-newest') {
          return (
            200,
            jsonEncode({
              'continuationContents': {
                'sectionListContinuation': {
                  'contents': [
                    {
                      'musicPlaylistShelfRenderer': {
                        'contents': [
                          _row('a', 'Timed', likedAt: 100, duration: '3:28'),
                        ],
                      },
                    },
                  ],
                },
              },
            }),
          );
        }
        return (200, jsonEncode(_playlistPage(const [])));
      });
      final tube = InnerTube(auth: auth, dio: client);

      final liked = await tube.likedVideos(max: 1);
      expect(liked.single.durationSec, 208);
      tube.close();
    });
  });

  group('playlist paging', () {
    test('follows the trailing continuation row', () async {
      var calls = 0;
      final client = mockDio((options) async {
        calls++;
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        if (body.containsKey('continuation')) {
          expect(body['continuation'], 'tok1');
          return (
            200,
            jsonEncode(_appendedPage(['c', 'd'], idPrefix: 'w')),
          );
        }
        expect(body['browseId'], 'VLPLtest');
        return (200, jsonEncode(_shelfPage(['a', 'b'], 'tok1')));
      });
      final tube = InnerTube(auth: auth, dio: client);

      final tracks = await tube.playlistTracks('PLtest');
      expect(tracks.map((t) => t.title).toList(), ['a', 'b', 'c', 'd']);
      expect(calls, 2);
      tube.close();
    });

    test('does not follow a page-level token from another shelf', () async {
      // The page also carries a section-list continuation that loads
      // unrelated shelves; following it would append foreign tracks.
      var calls = 0;
      final client = mockDio((options) async {
        calls++;
        return (
          200,
          jsonEncode(
            _shelfPage(['a', 'b'], null, sectionToken: 'other-shelf'),
          ),
        );
      });
      final tube = InnerTube(auth: auth, dio: client);

      final tracks = await tube.playlistTracks('PLtest');
      expect(tracks.map((t) => t.title).toList(), ['a', 'b']);
      expect(calls, 1);
      tube.close();
    });
  });
}

/// A continued playlist page: the rows arrive as appended items.
Map<String, dynamic> _appendedPage(
  List<String> titles, {
  String idPrefix = 'v',
}) => {
  'onResponseReceivedActions': [
    {
      'appendContinuationItemsAction': {
        'continuationItems': [
          for (var i = 0; i < titles.length; i++) _row('$idPrefix$i', titles[i]),
        ],
      },
    },
  ],
};
