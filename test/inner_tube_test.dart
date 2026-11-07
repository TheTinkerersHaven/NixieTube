// Transport tests for the InnerTube client: auth fallback order, the
// broken-bearer memo, feedback priority, and the client version shape.
// Responses are scripted; no network involved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';

import 'mock_dio.dart';

String? _header(Map<String, dynamic> headers, String name) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) {
      final v = e.value;
      return v is String ? v : v?.toString();
    }
  }
  return null;
}

(int, Object) _envelope(Object json) => (200, jsonEncode(json));

void main() {
  group('auth fallback', () {
    test('cookie first, then anonymous fallback on search', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockDio((options) async {
        seen.add(Map.of(options.headers));
        if (_header(options.headers, 'cookie') != null) {
          return _envelope({
            'error': {'code': 401},
          });
        }
        return _envelope({'contents': <String, dynamic>{}});
      });
      final tube = InnerTube(
        auth: const AuthSession(
          cookie: 'SID=x; SAPISID=y',
          sapisidHash: '1_abc',
        ),
        dio: client,
      );
      final res = await tube.post('search', {'query': 'x'});
      expect(seen.length, 2);
      expect(_header(seen[0], 'cookie'), isNotNull);
      expect(_header(seen[1], 'cookie'), isNull);
      expect(_header(seen[1], 'authorization'), isNull);
      expect(res, {'contents': <String, dynamic>{}});
      tube.close();
    });

    test('library browse stays an honest auth check', () async {
      var calls = 0;
      final client = mockDio((options) async {
        calls++;
        return _envelope({
          'error': {'code': 401},
        });
      });
      final tube = InnerTube(
        auth: const AuthSession(
          cookie: 'SID=x; SAPISID=y',
          sapisidHash: '1_abc',
        ),
        dio: client,
      );
      await tube.post('browse', {'browseId': 'FEmusic_library_landing'});
      expect(calls, 1);
      tube.close();
    });

    test('broken bearer is skipped on later calls', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockDio((options) async {
        seen.add(Map.of(options.headers));
        if (_header(options.headers, 'authorization') != null) {
          return _envelope({
            'error': {'code': 400},
          });
        }
        return _envelope({'contents': <String, dynamic>{}});
      });
      final tube = InnerTube(dio: client);
      const bearer = AuthSession(accessToken: 'tok');
      tube.authProvider = () async => bearer;
      await tube.post('search', {'query': 'x'});
      expect(seen.length, 2);
      seen.clear();
      await tube.post('search', {'query': 'y'});
      expect(seen.length, 1);
      expect(_header(seen[0], 'authorization'), isNull);
      tube.close();
    });

    test('feedback tries bearer before cookie', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockDio((options) async {
        seen.add(Map.of(options.headers));
        return _envelope(<String, dynamic>{});
      });
      final tube = InnerTube(
        auth: const AuthSession(
          cookie: 'SID=x; SAPISID=y',
          sapisidHash: '1_abc',
        ),
        dio: client,
      );
      tube.authProvider = () async => const AuthSession(accessToken: 'tok');
      await tube.post('feedback', {});
      expect(seen.length, 1);
      expect(_header(seen[0], 'authorization'), startsWith('Bearer '));
      expect(_header(seen[0], 'cookie'), isNull);
      tube.close();
    });

    test('cookie requests carry SAPISIDHASH and X-Origin', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockDio((options) async {
        seen.add(Map.of(options.headers));
        return _envelope(<String, dynamic>{});
      });
      final tube = InnerTube(
        auth: const AuthSession(
          cookie: 'SID=x; SAPISID=y',
          sapisidHash: '1_primary',
        ),
        dio: client,
      );
      await tube.post('browse', {'browseId': 'FEmusic_library_landing'});
      expect(_header(seen.single, 'authorization'), 'SAPISIDHASH 1_primary');
      expect(_header(seen.single, 'x-goog-authuser'), '0');
      tube.close();
    });
  });

  group('explore feed', () {
    Map<String, dynamic> shelf(String title, String videoId) => {
      'musicCarouselShelfRenderer': {
        'header': {
          'musicCarouselShelfBasicHeaderRenderer': {
            'title': {
              'runs': [
                {'text': title},
              ],
            },
          },
        },
        'contents': [
          {
            'musicTwoRowItemRenderer': {
              'title': {
                'runs': [
                  {'text': 'Song $videoId'},
                ],
              },
              'navigationEndpoint': {
                'watchEndpoint': {'videoId': videoId},
              },
            },
          },
        ],
      },
    };

    test('requests FEmusic_explore and parses its shelves', () async {
      Map<String, dynamic>? sent;
      final client = mockDio((options) async {
        sent = jsonDecode(options.data as String) as Map<String, dynamic>;
        return _envelope({
          'contents': {
            'singleColumnBrowseResultsRenderer': {
              'tabs': [
                {
                  'tabRenderer': {
                    'content': {
                      'sectionListRenderer': {
                        'contents': [
                          shelf('New albums & singles', 'a'),
                          shelf('Trending', 'b'),
                        ],
                      },
                    },
                  },
                },
              ],
            },
          },
        });
      });
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);

      final shelves = await tube.explore();
      expect(sent?['browseId'], 'FEmusic_explore');
      expect(shelves.map((s) => s.title), ['New albums & singles', 'Trending']);
      expect((shelves.first.items.single as SongItem).track.videoId, 'a');
    });

    test('empty when the response has no tabs', () async {
      final client = mockDio((options) async => _envelope({'contents': {}}));
      final tube = InnerTube(dio: client);
      addTearDown(tube.close);
      expect(await tube.explore(), isEmpty);
    });
  });

  group('clientVersion', () {
    test('matches 1.YYYYMMDD.01.00', () {
      expect(
        InnerTube.clientVersion(DateTime.utc(2026, 10, 2)),
        '1.20261002.01.00',
      );
      expect(
        RegExp(r'^1\.\d{8}\.01\.00$').hasMatch(InnerTube.clientVersion()),
        isTrue,
      );
    });
  });

  group('square cover cache', () {
    test('notes, flushes, and reloads from disk', () async {
      final dir = Directory.systemTemp.createTempSync('nt-sqcover');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/square-covers.json';

      final tube = InnerTube(squareCoversPath: path);
      addTearDown(tube.close);
      tube.noteSquareCover('v1', 'https://x/cover1');
      tube.noteSquareCover('v2', 'https://x/cover2');
      expect(tube.cachedSquareCover('v1'), 'https://x/cover1');
      expect(tube.cachedSquareCover('missing'), isNull);
      await tube.flushSquareCovers();

      // A fresh client loads the persisted covers from disk.
      final tube2 = InnerTube(squareCoversPath: path);
      addTearDown(tube2.close);
      expect(tube2.cachedSquareCover('v1'), 'https://x/cover1');
      expect(tube2.cachedSquareCover('v2'), 'https://x/cover2');
    });
  });

  group('watch info', () {
    /// A watch-next body with a like overlay and a two-row queue: the
    /// same response the queue metadata pass reads per row.
    Map<String, Object> nextBody() => {
      'playerOverlays': {
        'playerOverlayRenderer': {
          'actions': [
            {
              'likeButtonRenderer': {'likeStatus': 'LIKE'},
            },
          ],
        },
      },
      'contents': {
        'singleColumnMusicWatchNextResultsRenderer': {
          'tabbedRenderer': {
            'watchNextTabbedResultsRenderer': {
              'tabs': [
                {
                  'tabRenderer': {
                    'content': {
                      'musicQueueRenderer': {
                        'content': {
                          'playlistPanelRenderer': {
                            'contents': [
                              {
                                'playlistPanelVideoRenderer': {
                                  'title': {
                                    'runs': [
                                      {'text': 'One'},
                                    ],
                                  },
                                  'lengthText': {'simpleText': '3:20'},
                                  'navigationEndpoint': {
                                    'watchEndpoint': {'videoId': 'v1'},
                                  },
                                },
                              },
                              {
                                'playlistPanelVideoRenderer': {
                                  'title': {
                                    'runs': [
                                      {'text': 'Two'},
                                    ],
                                  },
                                  'lengthText': {'simpleText': '4:00'},
                                  'navigationEndpoint': {
                                    'watchEndpoint': {'videoId': 'v2'},
                                  },
                                },
                              },
                            ],
                          },
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        },
      },
    };

    test('one read yields the like state and the queue lengths', () async {
      final calls = <String>[];
      final tube = InnerTube(
        dio: mockDio((options) async {
          calls.add(options.path);
          return _envelope(nextBody());
        }),
      );
      addTearDown(tube.close);

      final info = await tube.watchInfo('v2');
      expect(info, isNotNull);
      expect(info!.rating, RatingStatus.like);
      expect(info.durations, {'v1': 200, 'v2': 240});
      // The single-read rating path shares the same parse.
      expect(await tube.rating('v2'), RatingStatus.like);
      expect(calls, everyElement(contains('/next')));
    });

    test('a response with no queue panel answers without lengths', () async {
      final tube = InnerTube(
        dio: mockDio(
          (options) async => _envelope({'contents': <String, Object>{}}),
        ),
      );
      addTearDown(tube.close);

      final info = await tube.watchInfo('v1');
      expect(info, isNotNull);
      expect(info!.rating, RatingStatus.unknown);
      expect(info.durations, isEmpty);
      expect(await tube.rating('v1'), RatingStatus.unknown);
    });

    test('failed reads return null and empty ids make no request', () async {
      var calls = 0;
      final tube = InnerTube(
        dio: mockDio((options) async {
          calls++;
          throw StateError('offline');
        }),
      );
      addTearDown(tube.close);

      expect(await tube.watchInfo(''), isNull);
      expect(calls, 0);
      expect(await tube.watchInfo('v1'), isNull);
      expect(await tube.rating('v1'), RatingStatus.unknown);

      final batch = await tube.watchInfos(['v1', 'v1', ' ']);
      expect(batch, isEmpty);
    });

    test('batch reads key by id and skip failed rows', () async {
      final tube = InnerTube(
        dio: mockDio((options) async {
          final body = options.data as String;
          if (body.contains('"videoId":"v2"')) throw StateError('offline');
          return _envelope(nextBody());
        }),
      );
      addTearDown(tube.close);

      final batch = await tube.watchInfos(['v1', 'v2', 'v1']);
      expect(batch.keys, ['v1']);
      expect(batch['v1']!.rating, RatingStatus.like);
      expect(batch['v1']!.durations['v2'], 240);
    });
  });

  group('viewCount', () {
    (int, Object) playerEnvelope(Map<String, dynamic> details) =>
        _envelope({'videoDetails': details});

    test('parses videoDetails.viewCount', () async {
      var calls = 0;
      final client = mockDio((options) async {
        expect(options.uri.path, '/youtubei/v1/player');
        calls++;
        return playerEnvelope({'videoId': 'vid1', 'viewCount': '123456'});
      });
      final tube = InnerTube(dio: client);
      expect(await tube.viewCount('vid1'), 123456);
      expect(calls, 1);
      tube.close();
    });

    test('coalesces identical in-flight calls', () async {
      final client = mockDio((options) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return playerEnvelope({'viewCount': '1000'});
      });
      final tube = InnerTube(dio: client);
      final a = tube.viewCount('v');
      final b = tube.viewCount('v');
      expect(await a, 1000);
      expect(await b, 1000);
      tube.close();
    });

    test('returns zero on error responses and transport failures', () async {
      final client = mockDio((options) async {
        throw const HttpException('down');
      });
      final tube = InnerTube(dio: client);
      expect(await tube.viewCount('v'), 0);
      tube.close();
    });

    test('returns zero on a malformed viewCount', () async {
      final client = mockDio((options) async {
        return playerEnvelope({'viewCount': 'abc'});
      });
      final tube = InnerTube(dio: client);
      expect(await tube.viewCount('v'), 0);
      tube.close();
    });

    test('skips the call for a blank videoId', () async {
      final client = mockDio((options) async {
        fail('no call expected');
      });
      final tube = InnerTube(dio: client);
      expect(await tube.viewCount(''), 0);
      expect(await tube.viewCount('   '), 0);
      tube.close();
    });
  });
}
