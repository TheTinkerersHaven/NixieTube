// Fixture tests for square-cover resolution: the panel's own row wins,
// other tracks' art is never stamped, 16:9-only panels fall back to
// the album page, and misses stay cached. Responses are scripted.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';

import 'mock_dio.dart';

/// Transport-level failure, the only kind cover fetches retry.
DioException _blip() => DioException(
  requestOptions: RequestOptions(path: 'https://x/'),
  type: DioExceptionType.connectionError,
);

Map<String, dynamic> _panelRow(
  String videoId,
  List<Map<String, dynamic>> thumbs,
) => {
  'playlistPanelVideoRenderer': {
    'title': {
      'runs': [
        {'text': 'Title $videoId'},
      ],
    },
    'navigationEndpoint': {
      'watchEndpoint': {'videoId': videoId},
    },
    'thumbnail': {'thumbnails': thumbs},
  },
};

Map<String, dynamic> _watchResponse(List<Map<String, dynamic>> rows) => {
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
                      'playlistPanelRenderer': {'contents': rows},
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

Map<String, dynamic> _albumResponse() => {
  'musicDetailHeaderRenderer': {
    'title': {
      'runs': [
        {'text': 'Album'},
      ],
    },
    'subtitle': {
      'runs': [
        {'text': 'Artist'},
      ],
    },
    'thumbnails': [
      {'url': 'https://x/album.jpg', 'width': 544, 'height': 544},
    ],
  },
  'musicShelfRenderer': {'contents': []},
};

/// Album page whose header art is 16:9 (no true square available).
Map<String, dynamic> _wideAlbumResponse() => {
  'musicDetailHeaderRenderer': {
    'title': {
      'runs': [
        {'text': 'Album'},
      ],
    },
    'subtitle': {
      'runs': [
        {'text': 'Artist'},
      ],
    },
    'thumbnails': [
      {'url': 'https://x/wide.jpg', 'width': 544, 'height': 306},
    ],
  },
  'musicShelfRenderer': {'contents': []},
};

Future<InnerTube> _tube(
  Map<String, dynamic> watch,
  Map<String, dynamic>? album,
  List<String> paths,
) async {
  final dir = Directory.systemTemp.createTempSync('nt-square-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final client = mockDio((options) async {
    paths.add(options.uri.path);
    if (options.uri.path.endsWith('/next')) {
      return (200, jsonEncode(watch));
    }
    if (album != null) return (200, jsonEncode(album));
    return (404, '{}');
  });
  final tube = InnerTube(
    dio: client,
    squareCoversPath: '${dir.path}/square-covers.json',
  );
  addTearDown(tube.close);
  return tube;
}

const List<Map<String, dynamic>> _frame = [
  {'url': 'https://x/f1.jpg', 'width': 320, 'height': 180},
];
const List<Map<String, dynamic>> _square = [
  {'url': 'https://x/s1.jpg', 'width': 120, 'height': 120},
  {'url': 'https://x/s2.jpg', 'width': 544, 'height': 544},
];

void main() {
  test('album art wins over panel thumbs', () async {
    final paths = <String>[];
    final tube = await _tube(
      _watchResponse([
        _panelRow('v1', [..._frame, ..._square]),
        _panelRow('v2', _square),
      ]),
      _albumResponse(),
      paths,
    );
    // The album header beats even the own row's square thumbs, which
    // may hide letterboxing inside a square canvas.
    expect(
      await tube.squareCoverOf('v1', albumId: 'MPRE1'),
      'https://x/album.jpg',
    );
    expect(paths.where((p) => p.endsWith('/browse')), hasLength(1));
    // Cached: no second request (album served it; panel untouched).
    expect(await tube.squareCoverOf('v1'), 'https://x/album.jpg');
    expect(paths.length, 1);
  });

  test('square-less album falls back to the own panel row', () async {
    final paths = <String>[];
    final tube = await _tube(
      _watchResponse([
        _panelRow('v1', [..._frame, ..._square]),
        // Another track's square art must NOT be stamped as v1's.
        _panelRow('v2', _square),
      ]),
      _wideAlbumResponse(),
      paths,
    );
    expect(
      await tube.squareCoverOf('v1', albumId: 'MPRE1'),
      'https://x/s2.jpg',
    );
  });

  test('16:9-only panel falls back to the album art', () async {
    final paths = <String>[];
    final tube = await _tube(
      _watchResponse([
        _panelRow('v1', _frame),
        // Another track's square art must NOT be stamped as v1's.
        _panelRow('v2', _square),
      ]),
      _albumResponse(),
      paths,
    );
    expect(
      await tube.squareCoverOf('v1', albumId: 'MPRE1'),
      'https://x/album.jpg',
    );
  });

  test('missing covers stay missing without repeat requests', () async {
    final paths = <String>[];
    final tube = await _tube(
      _watchResponse([_panelRow('v1', _frame)]),
      null,
      paths,
    );
    expect(await tube.squareCoverOf('v1'), isNull);
    expect(await tube.squareCoverOf('v1'), isNull);
    // One next call total; no browse attempted without an album id.
    expect(paths, ['/youtubei/v1/next']);
  });

  test('one album browse serves every track off it', () async {
    final paths = <String>[];
    final tube = await _tube(
      _watchResponse([_panelRow('v1', _frame), _panelRow('v2', _frame)]),
      _albumResponse(),
      paths,
    );
    expect(
      await tube.squareCoverOf('v1', albumId: 'MPRE1'),
      'https://x/album.jpg',
    );
    expect(
      await tube.squareCoverOf('v2', albumId: 'MPRE1'),
      'https://x/album.jpg',
    );
    // A single album browse total — and neither track paid for a
    // panel call, since the album answered first.
    expect(paths, ['/youtubei/v1/browse']);
  });

  Future<InnerTube> tubeWith(
    Future<(int, Object)> Function(dynamic options) onRequest,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-square-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = mockDio((options) => onRequest(options));
    final tube = InnerTube(
      dio: client,
      squareCoversPath: '${dir.path}/square-covers.json',
    );
    addTearDown(tube.close);
    return tube;
  }

  test('a panel blip retries instead of condemning the track', () async {
    final paths = <String>[];
    var nextCalls = 0;
    final tube = await tubeWith((options) async {
      paths.add(options.uri.path);
      if (options.uri.path.endsWith('/next')) {
        nextCalls++;
        if (nextCalls == 1) throw _blip();
        return (
          200,
          jsonEncode(
            _watchResponse([
              _panelRow('v1', [..._frame, ..._square]),
            ]),
          ),
        );
      }
      return (404, '{}');
    });
    expect(await tube.squareCoverOf('v1'), 'https://x/s2.jpg');
    expect(paths, ['/youtubei/v1/next', '/youtubei/v1/next']);
  });

  test('a dying panel gives up after retries and stays missing', () async {
    var nextCalls = 0;
    final tube = await tubeWith((options) async {
      nextCalls++;
      throw _blip();
    });
    expect(await tube.squareCoverOf('v1'), isNull);
    // 3 attempts (each retried once inside post), then missing
    // with no second wave.
    expect(nextCalls, 6);
    expect(await tube.squareCoverOf('v1'), isNull);
    expect(nextCalls, 6);
  });

  test('an album blip retries too', () async {
    final paths = <String>[];
    var browseCalls = 0;
    final tube = await tubeWith((options) async {
      paths.add(options.uri.path);
      if (options.uri.path.endsWith('/browse')) {
        browseCalls++;
        if (browseCalls == 1) throw _blip();
        return (200, jsonEncode(_albumResponse()));
      }
      return (200, jsonEncode(_watchResponse([_panelRow('v1', _frame)])));
    });
    expect(
      await tube.squareCoverOf('v1', albumId: 'MPRE1'),
      'https://x/album.jpg',
    );
    expect(browseCalls, 2);
    // The album answered, so the panel was never fetched.
    expect(paths, ['/youtubei/v1/browse', '/youtubei/v1/browse']);
  });
}
