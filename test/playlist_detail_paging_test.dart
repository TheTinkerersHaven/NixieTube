// A browsed playlist (the one a playlist card opens, from home or from
// search) lists every song it holds: the playlist page carries the
// first rows and the token for the next ones, so the client must follow
// that token instead of stopping at the first page.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';

import 'mock_dio.dart';

/// One playlist row.
Map<String, dynamic> _row(String videoId, String title) => {
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
  },
};

/// The trailing row that carries the token for the next page.
Map<String, dynamic> _continuation(String token) => {
  'continuationItemRenderer': {
    'continuationEndpoint': {
      'continuationCommand': {'token': token},
    },
  },
};

/// The playlist page: the shelf with its rows.
Map<String, dynamic> _playlistPage(List<Map<String, dynamic>> rows) => {
  'contents': {
    'twoColumnBrowseResultsRenderer': {
      'secondaryContents': {
        'sectionListRenderer': {
          'contents': [
            {
              'musicPlaylistShelfRenderer': {'contents': rows},
            },
          ],
        },
      },
    },
  },
};

/// A continued page: the rows arrive as appended items.
Map<String, dynamic> _continuedPage(List<Map<String, dynamic>> rows) => {
  'onResponseReceivedActions': [
    {
      'appendContinuationItemsAction': {'continuationItems': rows},
    },
  ],
};

void main() {
  test('a browsed playlist lists every page of its songs', () async {
    var calls = 0;
    final client = mockDio((options) async {
      calls++;
      final body = jsonDecode(options.data as String) as Map<String, dynamic>;
      final continuation = body['continuation'];
      if (continuation == null) {
        return (
          200,
          jsonEncode(
            _playlistPage([
              _row('a', 'A'),
              _row('b', 'B'),
              _continuation('t1'),
            ]),
          ),
        );
      }
      if (continuation == 't1') {
        return (
          200,
          jsonEncode(
            _continuedPage([
              _row('c', 'C'),
              _row('d', 'D'),
              _continuation('t2'),
            ]),
          ),
        );
      }
      return (200, jsonEncode(_continuedPage([_row('e', 'E')])));
    });
    final tube = InnerTube(dio: client);

    final detail = await tube.playlist('VLPLabc');
    expect(detail?.tracks.map((t) => t.title).toList(), [
      'A',
      'B',
      'C',
      'D',
      'E',
    ]);
    // The page, then one request per continuation.
    expect(calls, 3);
    tube.close();
  });

  test('a playlist without a continuation stops at its first page', () async {
    var calls = 0;
    final client = mockDio((options) async {
      calls++;
      return (200, jsonEncode(_playlistPage([_row('a', 'A'), _row('b', 'B')])));
    });
    final tube = InnerTube(dio: client);

    final detail = await tube.playlist('VLPLabc');
    expect(detail?.tracks.map((t) => t.title).toList(), ['A', 'B']);
    expect(calls, 1);
    tube.close();
  });
}
