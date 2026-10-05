// Lyrics tests: LRC parsing, fuzzy normalization, and the
// LRCLIB lookup's retry behaviour on transient failures.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nixietube/core/innertube/lyrics.dart';

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
    });
  });

  group('fetchLyricsAndAlbum', () {
    test('retries a rate-limited lookup', () async {
      var gets = 0;
      var searches = 0;
      final client = MockClient((request) async {
        final direct = request.url.path == '/api/get';
        final n = direct ? ++gets : ++searches;
        // The first hit on each endpoint is throttled.
        if (n == 1) return http.Response('rate limited', 429);
        return http.Response(_entry, 200);
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        httpClient: client,
      );
      expect(res.lines, hasLength(2));
      expect(res.lines.first.text, 'line one');
      expect(res.album, 'Swerve it');
      // Direct hit succeeded on the retry; search never ran.
      expect(gets, 2);
      expect(searches, 0);
    });

    test('retries a dropped connection', () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (++calls == 1) {
          throw const SocketException('connection reset');
        }
        return http.Response(_entry, 200);
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        httpClient: client,
      );
      expect(res.lines, hasLength(2));
      expect(calls, 2);
    });

    test('gives up when rate limits persist', () async {
      var count = 0;
      final client = MockClient((request) async {
        count++;
        return http.Response('rate limited', 429);
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        httpClient: client,
      );
      expect(res.lines, isEmpty);
      expect(res.album, isNull);
      // Three attempts per endpoint (initial + two retries).
      expect(count, 6);
    });

    test('a 404 is final, never retried', () async {
      var count = 0;
      final client = MockClient((request) async {
        count++;
        return http.Response('not found', 404);
      });
      final res = await fetchLyricsAndAlbum(
        'Bou',
        'Swerve It',
        '',
        0,
        httpClient: client,
      );
      expect(res.lines, isEmpty);
      // One attempt per endpoint.
      expect(count, 2);
    });
  });
}
