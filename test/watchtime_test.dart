// Tests for the watchtime reporting port: player token extraction,
// beacon URL shape, session-token caching, and the ptracking→playback→
// watchtime→feedback sequence for a new-track play.
// Responses are scripted; no network involved.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';

String? _header(Map<String, String> headers, String name) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

http.Response _envelope(Object json) =>
    http.Response(jsonEncode(json), 200);

void main() {
  group('watchtime reporting', () {
    test('player tokens extracted into WatchtimeContext', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('/player')) {
          return _envelope({
            'playbackTracking': {
              'videostatsWatchtimeUrl': {
                'baseUrl': 'https://music.youtube.com/api/stats/watchtime'
                    '?ei=test-ei&plid=test-plid&of=test-of&vm=test-vm&len=120',
              },
              'ptrackingUrl': {
                'baseUrl': 'https://music.youtube.com/watch?v=deadbeef',
              },
            },
            'videoDetails': {'lengthSeconds': '200'},
          });
        }
        return http.Response('', 404);
      });

      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
      );
      final ctx = await tube.watchtimeContext('deadbeef');
      tube.close();

      expect(ctx, isNotNull);
      expect(ctx!.ei, 'test-ei');
      expect(ctx.plid, 'test-plid');
      expect(ctx.of, 'test-of');
      expect(ctx.vm, 'test-vm');
      expect(ctx.lenSec, 200.0);
      expect(ctx.ptrackingUrl,
          'https://music.youtube.com/watch?v=deadbeef');
    });

    test('reportWatchtime sends ptracking + playback + watchtime + feedback',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((req) async {
        requests.add(req);
        final u = req.url.toString();

        // Session token extraction from YTM root page (path is '/' or empty).
        if (req.url.host == 'music.youtube.com' &&
            (req.url.path == '/' || req.url.path.isEmpty) &&
            req.method == 'GET') {
          return http.Response(
              '{"XSRF_TOKEN":"test-session-token"}',
              200);
        }

        // Player endpoint for watchtime context.
        if (u.contains('/player')) {
          return _envelope({
            'playbackTracking': {
              'videostatsWatchtimeUrl': {
                'baseUrl': 'https://music.youtube.com/api/stats/watchtime'
                    '?ei=bei&plid=bplid&of=bof&vm=bvm&len=60',
              },
              'ptrackingUrl': {
                'baseUrl': 'https://music.youtube.com/watch?v=ptrack',
              },
            },
            'videoDetails': {'lengthSeconds': '60'},
          });
        }

        // Beacon endpoints (ptracking GET, stats/* POST).
        if (u.contains('/api/stats/')) return http.Response('', 204);
        // ptracking pixel (best-effort GET).
        if (u.contains('/watch?v=')) return http.Response('', 404);
        // feedback endpoint.
        if (u.contains('/feedback')) return _envelope(<String, dynamic>{});
        return http.Response('', 404);
      });

      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
      );
      tube.authProvider = () async => const AuthSession(accessToken: 'tok');

      final ok = await tube.reportWatchtime(
        'deadbeef',
        'test-cpn-16char',
        0.0,
        5.0,
        'playing',
        60.0,
        null,
      );
      tube.close();

      expect(ok, isTrue);

      final urls = requests.map((r) => r.url.toString()).toList();
      expect(urls.any((u) => u.contains('/api/stats/playback')), isTrue);
      expect(urls.any((u) => u.contains('/api/stats/watchtime')), isTrue);
      expect(urls.any((u) => u == 'https://music.youtube.com/watch?v=ptrack'),
          isTrue);
      expect(urls.any((u) => u.contains('/feedback')), isTrue);

      // The watchtime beacon carries session params + state.
      final watchtimeUrl =
          urls.firstWhere((u) => u.contains('/api/stats/watchtime'));
      expect(watchtimeUrl, contains('ei=bei'));
      expect(watchtimeUrl, contains('plid=bplid'));
      expect(watchtimeUrl, contains('of=bof'));
      expect(watchtimeUrl, contains('vm=bvm'));
      expect(watchtimeUrl, contains('docid=deadbeef'));
      expect(watchtimeUrl, contains('state=playing'));
      expect(watchtimeUrl, contains('rtn='));
      expect(watchtimeUrl, contains('rti='));
      // First beacon has no final=1.
      expect(watchtimeUrl, isNot(contains('final=1')));

      // Beacon POSTs carry session_token in JSON body.
      final beaconPosts = requests
          .where((r) =>
              r.url.path.contains('/api/stats/') && r.method == 'POST')
          .toList();
      expect(beaconPosts, isNotEmpty);
      expect(beaconPosts.first.body, contains('session_token'));
      expect(_header(beaconPosts.first.headers, 'Content-Type'),
          contains('application/json'));
    });

    test("heartbeats reuse cached context and don't re-fetch player",
        () async {
      final playerCalls = <String>[];
      final client = MockClient((req) async {
        final u = req.url.toString();
        if (req.url.host == 'music.youtube.com' &&
            (req.url.path == '/' || req.url.path.isEmpty) &&
            req.method == 'GET') {
          return http.Response('{"XSRF_TOKEN":"tok"}', 200);
        }
        if (u.contains('/player')) {
          playerCalls.add(u);
          return _envelope({
            'playbackTracking': {
              'videostatsWatchtimeUrl': {
                'baseUrl': 'https://music.youtube.com/api/stats/watchtime'
                    '?ei=E2&plid=P2&of=O2&vm=V2&len=120',
              },
              'ptrackingUrl': {
                'baseUrl': 'https://music.youtube.com/watch?v=ptrack',
              },
            },
            'videoDetails': {'lengthSeconds': '120'},
          });
        }
        if (u.contains('/api/stats/')) return http.Response('', 204);
        if (u.contains('/feedback')) return _envelope({});
        return http.Response('', 404);
      });

      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
      );

      await tube.reportWatchtime(
          'vid1', 'cpn-1', 0.0, 1.0, 'playing', 120.0, null);
      // Two more heartbeats.
      await tube.reportWatchtime(
          'vid1', 'cpn-1', 5.0, 10.0, 'playing', 120.0, null);
      await tube.reportWatchtime(
          'vid1', 'cpn-1', 10.0, 20.0, 'playing', 120.0, null);

      tube.close();
      // Context fetched once, cached for the cpn.
      expect(playerCalls.length, 1);
    });

    test('final=1 appended on pause', () async {
      final watchtimeUrls = <String>[];
      final client = MockClient((req) async {
        final u = req.url.toString();
        if (req.url.host == 'music.youtube.com' &&
            (req.url.path == '/' || req.url.path.isEmpty) &&
            req.method == 'GET') {
          return http.Response('{"XSRF_TOKEN":"tok"}', 200);
        }
        if (u.contains('/player')) {
          return _envelope({
            'playbackTracking': {
              'videostatsWatchtimeUrl': {
                'baseUrl': 'https://music.youtube.com/api/stats/watchtime'
                    '?ei=pei&plid=p&of=o&vm=v&len=30',
              },
              'ptrackingUrl': {
                'baseUrl': 'https://music.youtube.com/watch?v=pt',
              },
            },
            'videoDetails': {'lengthSeconds': '30'},
          });
        }
        if (u.contains('/api/stats/watchtime')) {
          watchtimeUrls.add(u);
          return http.Response('', 204);
        }
        if (u.contains('/api/stats/')) return http.Response('', 204);
        if (u.contains('/feedback')) return _envelope({});
        return http.Response('', 404);
      });

      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
      );

      await tube.reportWatchtime(
          'v', 'c-1', 0.0, 2.0, 'playing', 30.0, null);
      await tube.reportWatchtime(
          'v', 'c-1', 2.0, 5.0, 'paused', 30.0, null);

      tube.close();
      // First call (playing) and second (paused → final=1).
      expect(watchtimeUrls.length, 2);
      expect(watchtimeUrls[0], isNot(contains('final=1')));
      expect(watchtimeUrls[1], contains('final=1'));
      // rtn incremented between heartbeats.
      final firstRtn = RegExp(r'rtn=(\d+)').firstMatch(watchtimeUrls[0])!
          .group(1)!;
      final secondRtn = RegExp(r'rtn=(\d+)').firstMatch(watchtimeUrls[1])!
          .group(1)!;
      expect(int.parse(secondRtn), greaterThan(int.parse(firstRtn)));
    });

    test('anonymous session still fires feedback (no beacon candidates)',
        () async {
      final statsCalled = <String>[];
      final client = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('/api/stats/')) {
          statsCalled.add(u);
          return http.Response('', 204);
        }
        if (u.contains('/feedback')) return _envelope({});
        return http.Response('', 404);
      });

      final tube = InnerTube(httpClient: client);
      // No cookie → fetchSessionToken returns null → no beacon candidates.
      final ok = await tube.reportWatchtime(
          'v', 'c-2', 0.0, 1.0, 'playing', 30.0, null);
      tube.close();

      // feedback POST always fires and returns true.
      expect(ok, isTrue);
      // No stats beacons sent without auth candidates.
      expect(statsCalled, isEmpty);
    });
  });
}