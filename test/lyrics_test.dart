// Lyrics tests: LRC parsing, fuzzy normalization, the
// LRCLIB lookup's retry behaviour on transient failures, and the
// YouTube Music lyrics source (tab discovery + shelf parsing).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/lyrics.dart';

import 'mock_dio.dart';

/// One LRCLIB entry as the API returns it.
const _entry = '{"id":1,"trackName":"Swerve It","artistName":"Bou",'
    '"albumName":"Swerve it","duration":167.0,'
    '"plainLyrics":"line one\\nline two"}';

void main() {
  setUp(() {
    lrclibRetryDelay = Duration.zero;
  });

  tearDown(() {
    lrclibRetryDelay = const Duration(milliseconds: 800);
  });

  group('parseLrc', () {
    test('parses timed lines, skips blanks', () {
      const lrc = '[00:12.34]Hello\n[01:02.5]World\n[02:00]No frac\n'
          '[bad] Skip\n[03:04.5678]Trimmed   \n[04:05.00]\n';
      final lines = parseLrc(lrc);
      expect(lines.length, 4);
      expect(lines[0].timeMs, 12340);
      expect(lines[0].text, 'Hello');
      expect(lines[1].timeMs, 62500);
      expect(lines[2].timeMs, 120000);
      expect(lines[3].timeMs, 3 * 60000 + 4567);
      expect(lines[3].text, 'Trimmed');
    });
  });

  group('normalizeLrc', () {
    test('strips features, editions, punctuation', () {
      expect(normalizeLrc('Song (feat. Guest)'), 'song');
      expect(normalizeLrc('Song - Live'), 'song');
      // "Remastered" has no word boundary after "remaster", so only the
      // exact "Remaster" form strips — same as Kotlin.
      expect(normalizeLrc('Song - Remaster 2023'), 'song');
      expect(normalizeLrc('Song - Remastered 2023'), 'song remastered 2023');
      expect(normalizeLrc("Don't Stop!"), 'dont stop');
      expect(normalizeLrc('Knock2/Dillon Francis'), 'knock2 dillon francis');
      expect(normalizeLrc('UK Apache, SHY FX'), 'uk apache shy fx');
      expect(normalizeLrc('Dillon Francis & Knock2'), 'dillon francis knock2');
    });
  });

  group('fetchLyricsAndAlbum', () {
    test('retries a rate-limited lookup', () async {
      var gets = 0;
      var searches = 0;
      final client = mockDio((options) async {
        final direct = options.uri.path == '/api/get';
        final n = direct ? ++gets : ++searches;
        // The first hit on each endpoint is throttled.
        if (n == 1) return (429, 'rate limited');
        return (200, _entry);
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        dio: client,
      );
      expect(res.lines, hasLength(2));
      expect(res.lines.first.text, 'line one');
      expect(res.album, 'Swerve it');
      // Direct hit succeeded on the retry — but it is plain-only,
      // so search still runs looking for a synced cut (and finds
      // the same entry again, deduplicated).
      expect(gets, 2);
      expect(searches, 2);
    });

    test('retries a dropped connection', () async {
      var calls = 0;
      final client = mockDio((options) async {
        if (++calls == 1) {
          throw const SocketException('connection reset');
        }
        return (200, _entry);
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        dio: client,
      );
      expect(res.lines, hasLength(2));
      expect(calls, 3);
    });

    test('gives up when rate limits persist', () async {
      var count = 0;
      final client = mockDio((options) async {
        count++;
        return (429, 'rate limited');
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        dio: client,
      );
      expect(res.lines, isEmpty);
      expect(res.album, isNull);
      // Three attempts per endpoint (initial + two retries).
      expect(count, 6);
    });

    test('a 404 is final, never retried', () async {
      var count = 0;
      final client = mockDio((options) async {
        count++;
        return (404, 'not found');
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        dio: client,
      );
      expect(res.lines, isEmpty);
      // One attempt per endpoint.
      expect(count, 2);
    });

    // A plain-only direct hit keeps searching for a synced cut
    // of the same song instead of settling for static lines.
    test('plain direct hit upgrades to a synced search hit', () async {
      const plain = '{"id":17373366,'
          '"trackName":"buttons!","artistName":"Knock2",'
          '"albumName":"buttons!","duration":239.098776,'
          '"plainLyrics":"push my buttons"}';
      const synced = '{"id":20564332,'
          '"trackName":"buttons!","artistName":"knock2/dillon francis",'
          '"albumName":"buttons!","duration":194.0,'
          '"plainLyrics":"push\\nbuttons",'
          '"syncedLyrics":"[00:01.00]push\\n[00:05.00]buttons"}';
      final client = mockDio((options) async {
        if (options.uri.path == '/api/get') return (200, plain);
        return (200, '[$synced]');
      });
      final res = await fetchLyricsAndAlbum(
        'Knock2',
        'buttons!',
        'buttons!',
        194,
        dio: client,
      );
      expect(res.lines.map((l) => l.text), ['push', 'buttons']);
      expect(res.lines.first.timeMs, greaterThanOrEqualTo(0));
    });

    // "Original Nuttah 25 [Chase & Status Remix] (feat. IRAH)" by
    // "UK Apache, SHY FX": the verbatim query matches nothing
    // server-side, but the normalized fallback finds the entry —
    // whose fewer credited artists still match.
    test('normalized fallback query finds remix/feat credits', () async {
      const nuttah = '{"id":32575872,'
          '"trackName":"Original Nuttah 25 [Chase & Status Remix] '
          '(feat. IRAH)",'
          '"artistName":"UK Apache","albumName":"Original Nuttah 25",'
          '"duration":223.0,'
          '"plainLyrics":"nuttah\\nsound",'
          '"syncedLyrics":"[00:01.00]nuttah\\n[00:05.00]sound"}';
      var searches = 0;
      final client = mockDio((options) async {
        if (options.uri.path == '/api/get') return (404, 'not found');
        searches++;
        // Verbatim query (still carries the feat credit) finds
        // nothing; the normalized one hits.
        if ((options.uri.queryParameters['track_name'] ?? '')
            .contains('feat')) {
          return (200, '[]');
        }
        return (200, '[$nuttah]');
      });
      final res = await fetchLyricsAndAlbum(
        'UK Apache, SHY FX',
        'Original Nuttah 25 [Chase & Status Remix] (feat. IRAH)',
        'Original Nuttah 25',
        223,
        dio: client,
      );
      expect(res.lines.map((l) => l.text), ['nuttah', 'sound']);
      expect(res.lines.first.timeMs, greaterThanOrEqualTo(0));
      expect(res.album, 'Original Nuttah 25');
      // Verbatim, then normalized — the synced hit stops the
      // cascade before the primary-artist round.
      expect(searches, 2);
    });

    // "buttons!" by "Knock2": the slash-joined artist entry must
    // tokenize as two artists, and the synced 194s cut must win
    // over the plain-only one on duration.
    test('slash artists match and duration picks the right cut', () async {
      const slash = '{"id":20564332,'
          '"trackName":"buttons!","artistName":"knock2/dillon francis",'
          '"albumName":"buttons!","duration":194.0,'
          '"plainLyrics":"push\\nbuttons",'
          '"syncedLyrics":"[00:01.00]push\\n[00:05.00]buttons"}';
      const plain = '{"id":17373366,'
          '"trackName":"buttons!","artistName":"Knock2",'
          '"albumName":"buttons!","duration":239.098776,'
          '"plainLyrics":"push my buttons"}';
      var searches = 0;
      final client = mockDio((options) async {
        if (options.uri.path == '/api/get') return (404, 'not found');
        searches++;
        return (200, '[$slash,$plain]');
      });
      final res = await fetchLyricsAndAlbum(
        'Knock2',
        'buttons!',
        'buttons!',
        194,
        dio: client,
      );
      expect(res.lines.map((l) => l.text), ['push', 'buttons']);
      expect(res.lines.first.timeMs, greaterThanOrEqualTo(0));
      // The verbatim round already yields synced lyrics, so the
      // normalized round never runs.
      expect(searches, 1);
    });

    // "rampage (extended) (feat. DJ SS)" by "venbee": the stored
    // "rampage" matches once parenthesized editions are ignored.
    test('parenthesized editions match the bare title', () async {
      const rampage = '{"id":19333603,'
          '"trackName":"rampage","artistName":"venbee",'
          '"albumName":"rampage","duration":210.0,'
          '"plainLyrics":"rampage\\nagain",'
          '"syncedLyrics":"[00:01.00]rampage\\n[00:05.00]again"}';
      final client = mockDio((options) async {
        if (options.uri.path == '/api/get') return (404, 'not found');
        if ((options.uri.queryParameters['track_name'] ?? '')
            .contains('feat')) {
          return (200, '[]');
        }
        return (200, '[$rampage]');
      });
      final res = await fetchLyricsAndAlbum(
        'venbee',
        'rampage (extended) (feat. DJ SS)',
        '',
        210,
        dio: client,
      );
      expect(res.lines.map((l) => l.text), ['rampage', 'again']);
      expect(res.lines.first.timeMs, greaterThanOrEqualTo(0));
    });

    test('same title with a disjoint artist stays rejected', () async {
      const wrong = '{"id":9,'
          '"trackName":"buttons!","artistName":"Dillon Francis",'
          '"albumName":"buttons!","duration":239.0,'
          '"plainLyrics":"nope"}';
      final client = mockDio((options) async {
        if (options.uri.path == '/api/get') return (404, 'not found');
        return (200, '[$wrong]');
      });
      final res = await fetchLyricsAndAlbum(
        'Knock2',
        'buttons!',
        '',
        0,
        dio: client,
      );
      expect(res.lines, isEmpty);
    });
  });

  group('LyricsSource', () {
    test('labels and key round-trip, unknown falls back to LRCLIB', () {
      expect(LyricsSource.lrclib.label, 'LRCLIB');
      expect(LyricsSource.ytmusic.label, 'YT Music');
      expect(LyricsSource.fromKey('ytmusic'), LyricsSource.ytmusic);
      expect(LyricsSource.fromKey('lrclib'), LyricsSource.lrclib);
      expect(LyricsSource.fromKey('bogus'), LyricsSource.lrclib);
    });
  });

  group('ytmLyricsBrowseId', () {
    Map<String, dynamic> tabsResponse(List<Map<String, dynamic>> tabs) => {
          'contents': {
            'singleColumnMusicWatchNextResultsRenderer': {
              'tabbedRenderer': {
                'watchNextTabbedResultsRenderer': {'tabs': tabs},
              },
            },
          },
        };

    Map<String, dynamic> lyricsTab(String browseId, {bool? unselectable}) => {
          'tabRenderer': {
            if (unselectable case final bool u) 'unselectable': u,
            'endpoint': {
              'browseEndpoint': {
                'browseId': browseId,
                'browseEndpointContextSupportedConfigs': {
                  'browseEndpointContextMusicConfig': {
                    'pageType': 'MUSIC_PAGE_TYPE_TRACK_LYRICS',
                  },
                },
              },
            },
            'title': 'Lyrics',
          },
        };

    test('finds the lyrics tab by page type', () {
      final res = tabsResponse([
        {
          'tabRenderer': {'title': 'Up next'},
        },
        lyricsTab('MPLYt_abc-1'),
      ]);
      expect(ytmLyricsBrowseId(res), 'MPLYt_abc-1');
    });

    test('skips unselectable tabs and tolerates missing shapes', () {
      final res = tabsResponse([
        lyricsTab('MPLYt_nope-1', unselectable: true),
        {'tabRenderer': {'title': 'Related'}},
      ]);
      expect(ytmLyricsBrowseId(res), isNull);
      expect(ytmLyricsBrowseId({}), isNull);
      expect(ytmLyricsBrowseId(null), isNull);
    });
  });

  group('ytmLyricsFromJson', () {
    test('concatenates shelf runs into untimed lines', () {
      final res = {
        'contents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicDescriptionShelfRenderer': {
                  'description': {
                    'runs': [
                      {'text': 'Line one\nLine two\n\nLine three\n'},
                    ],
                  },
                },
              },
            ],
          },
        },
      };
      final lines = ytmLyricsFromJson(res);
      expect(lines.map((l) => l.text), ['Line one', 'Line two', 'Line three']);
      expect(lines.every((l) => l.timeMs == -1), isTrue);
    });

    test('unavailable message and missing shapes yield nothing', () {
      expect(
        ytmLyricsFromJson({
          'contents': {
            'messageRenderer': {
              'text': {
                'runs': [
                  {'text': 'Lyrics not available'},
                ],
              },
            },
          },
        }),
        isEmpty,
      );
      expect(ytmLyricsFromJson({}), isEmpty);
      expect(ytmLyricsFromJson(null), isEmpty);
    });
  });

  group('fetchYtmLyrics', () {
    test('follows the lyrics tab to the shelf text', () async {
      String? pathOf(String uri) => Uri.parse(uri).pathSegments.last;
      final client = mockDio((options) async {
        final path = pathOf(options.uri.toString());
        if (path == 'next') {
          return (
            200,
            jsonEncode({
              'contents': {
                'singleColumnMusicWatchNextResultsRenderer': {
                  'tabbedRenderer': {
                    'watchNextTabbedResultsRenderer': {
                      'tabs': [
                        {
                          'tabRenderer': {
                            'endpoint': {
                              'browseEndpoint': {
                                'browseId': 'MPLYt_tab-1',
                                'browseEndpointContextSupportedConfigs': {
                                  'browseEndpointContextMusicConfig': {
                                    'pageType':
                                        'MUSIC_PAGE_TYPE_TRACK_LYRICS',
                                  },
                                },
                              },
                            },
                            'title': 'Lyrics',
                          },
                        },
                      ],
                    },
                  },
                },
              },
            }),
          );
        }
        return (
          200,
          jsonEncode({
            'contents': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'musicDescriptionShelfRenderer': {
                      'description': {
                        'runs': [
                          {'text': 'Hello\nWorld\n'},
                        ],
                      },
                    },
                  },
                ],
              },
            },
          }),
        );
      });
      final lines = await fetchYtmLyrics('vid1', dio: client);
      expect(lines.map((l) => l.text), ['Hello', 'World']);
    });

    test('no lyrics tab means no lyrics', () async {
      final client = mockDio(
        (options) async => (200, jsonEncode({'contents': {}})),
      );
      expect(await fetchYtmLyrics('vid1', dio: client), isEmpty);
    });
  });
}
