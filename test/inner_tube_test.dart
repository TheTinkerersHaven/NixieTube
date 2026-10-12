// Transport tests for the InnerTube client: auth fallback order, the
// broken-bearer memo, feedback priority, and the client version shape.
// Responses are scripted; no network involved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';

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
          return _envelope({'error': {'code': 401}});
        }
        return _envelope({
          'contents': <String, dynamic>{}
        });
      });
      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
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
        return _envelope({'error': {'code': 401}});
      });
      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        dio: client,
      );
      await tube.post(
          'browse', {'browseId': 'FEmusic_library_landing'});
      expect(calls, 1);
      tube.close();
    });

    test('broken bearer is skipped on later calls', () async {
      final seen = <Map<String, dynamic>>[];
      final client = mockDio((options) async {
        seen.add(Map.of(options.headers));
        if (_header(options.headers, 'authorization') != null) {
          return _envelope({'error': {'code': 400}});
        }
        return _envelope({
          'contents': <String, dynamic>{}
        });
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
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        dio: client,
      );
      tube.authProvider =
          () async => const AuthSession(accessToken: 'tok');
      await tube.post('feedback', {});
      expect(seen.length, 1);
      expect(_header(seen[0], 'authorization'), startsWith('Bearer '));
      expect(_header(seen[0], 'cookie'), isNull);
      tube.close();
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
}
