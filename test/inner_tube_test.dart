// Transport tests for the InnerTube client: auth fallback order, the
// broken-bearer memo, feedback priority, and the client version shape.
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
  group('auth fallback', () {
    test('cookie first, then anonymous fallback on search', () async {
      final seen = <Map<String, String>>[];
      final client = MockClient((req) async {
        seen.add(Map.of(req.headers));
        if (_header(req.headers, 'cookie') != null) {
          return _envelope({'error': {'code': 401}});
        }
        return _envelope({
          'contents': <String, dynamic>{}
        });
      });
      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
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
      final client = MockClient((req) async {
        calls++;
        return _envelope({'error': {'code': 401}});
      });
      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
      );
      await tube.post(
          'browse', {'browseId': 'FEmusic_library_landing'});
      expect(calls, 1);
      tube.close();
    });

    test('broken bearer is skipped on later calls', () async {
      final seen = <Map<String, String>>[];
      final client = MockClient((req) async {
        seen.add(Map.of(req.headers));
        if (_header(req.headers, 'authorization') != null) {
          return _envelope({'error': {'code': 400}});
        }
        return _envelope({
          'contents': <String, dynamic>{}
        });
      });
      final tube = InnerTube(httpClient: client);
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
      final seen = <Map<String, String>>[];
      final client = MockClient((req) async {
        seen.add(Map.of(req.headers));
        return _envelope(<String, dynamic>{});
      });
      final tube = InnerTube(
        auth: const AuthSession(
            cookie: 'SID=x; SAPISID=y', sapisidHash: '1_abc'),
        httpClient: client,
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
}
