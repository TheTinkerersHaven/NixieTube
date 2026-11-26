// PO-token tests: the watch-page parsing, the interpreter allow-list and
// the BotGuard exchange that turns a challenge into a stream token.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/po_token.dart';

import 'mock_dio.dart';

const _interpreterUrl =
    '//www.google.com/js/th/OBn0-lcK2heSsQvwZqBdYDSSLon5TOClfDI9QSdpnEY.js';

String _challengeJson({String? interpreterUrl}) => jsonEncode({
  'bgChallenge': {
    'interpreterUrl': {
      'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
          interpreterUrl ?? _interpreterUrl,
    },
    'interpreterHash': 'OBn0-lcK2heSsQvwZqBdYDSSLon5TOClfDI9QSdpnEY',
    'program': 'program-body',
    'globalName': 'bgVm',
  },
});

/// The watch page wraps the challenge in a JS string with `\x` escapes,
/// and the first `ytAtN` occurrence is only the promise shim.
String _watchPage({String? interpreterUrl}) {
  final escaped = _challengeJson(interpreterUrl: interpreterUrl)
      .replaceAll('"', r'\x22')
      .replaceAll('/', r'\/');
  return '<html><script>window.ytAtP = new Promise(res => window.ytAtN = res);'
      '</script><script>ytcfg.set({"EVENT_ID":"event-1","OTHER":1});</script>'
      '<script>window.ytAtN({R:\'$escaped\'});</script></html>';
}

void main() {
  test('the challenge is read past the promise shim', () {
    final challenge = extractBotGuardChallenge(_watchPage());

    expect(challenge, isNotNull);
    expect(challenge!['program'], 'program-body');
    expect(challenge['globalName'], 'bgVm');
    expect(extractEventId(_watchPage()), 'event-1');
  });

  test('a page without a challenge yields null', () {
    expect(extractBotGuardChallenge('<html></html>'), isNull);
    expect(extractEventId('<html></html>'), isNull);
  });

  test('only Google-hosted interpreters are trusted', () {
    final challenge = extractBotGuardChallenge(_watchPage())!;
    expect(trustedInterpreterUrl(challenge), 'https:$_interpreterUrl');

    for (final url in [
      'https://evil.example/js/th/OBn0-lcK2heSsQvwZqBdYDSSLon5TOClfDI9QSdpnEY.js',
      'http://www.google.com/js/th/OBn0-lcK2heSsQvwZqBdYDSSLon5TOClfDI9QSdpnEY.js',
      'https://www.google.com/evil.js',
      'https://www.gstatic.com/js/th/OBn0-lcK2heSsQvwZqBdYDSSLon5TOClfDI9QSdpnEY.js',
    ]) {
      final bad = extractBotGuardChallenge(_watchPage(interpreterUrl: url))!;
      expect(
        () => trustedInterpreterUrl(bad),
        throwsA(isA<PoTokenException>()),
        reason: url,
      );
    }
  });

  test('token bytes become unpadded base64url', () {
    expect(base64UrlFromBytes('0,1,250,255'), 'AAH6_w');
    expect(base64UrlFromBytes(''), '');
    expect(() => base64UrlFromBytes('256'), throwsA(isA<PoTokenException>()));
  });

  test('the minter exchanges a challenge for both tokens', () async {
    final requests = <String>[];
    final dio = mockDio((options) async {
      requests.add('${options.method} ${options.uri.host}${options.uri.path}');
      if (options.uri.path == '/watch') return (200, _watchPage());
      if (options.uri.host == 'www.google.com') return (200, 'interpreter();');
      if (options.uri.path == '/api/jnn/v1/GenerateIT') {
        return (
          200,
          jsonEncode([
            base64Encode([1, 2, 3]),
            43200,
          ]),
        );
      }
      return (404, '');
    });
    // Stands in for the WebView: the driver is asked to run, then each
    // async step reports ready with the value the real VM would produce.
    final scripts = <String>[];
    Future<String> evaluate(String script) async {
      scripts.add(script);
      if (script.contains('JSON.stringify(globalThis.__ntPoSnapshot')) {
        return jsonEncode({'state': 'ready', 'value': 'snapshot'});
      }
      if (script.contains('JSON.stringify(globalThis.__ntPoMinter')) {
        return jsonEncode({'state': 'ready', 'value': 'ready'});
      }
      if (script.contains('JSON.stringify(globalThis.__ntPoToken')) {
        return jsonEncode({'state': 'ready', 'value': '0,1,250,255'});
      }
      return '"started"';
    }

    final minter = PoTokenMinter(
      dio: dio,
      evaluate: evaluate,
      userAgent: 'test-agent',
    );
    addTearDown(minter.close);

    final tokens = await minter.mint(
      videoId: 'vid',
      visitorData: 'visitor-1',
      cookie: 'SID=x',
    );

    expect(tokens, isNotNull);
    expect(tokens!.playerRequest, 'AAH6_w');
    expect(tokens.streamingData, 'AAH6_w');
    expect(tokens.expired, isFalse);
    expect(requests, [
      'GET www.youtube.com/watch',
      'GET www.google.com/js/th/OBn0-lcK2heSsQvwZqBdYDSSLon5TOClfDI9QSdpnEY.js',
      'POST www.youtube.com/api/jnn/v1/GenerateIT',
    ]);
    // The driver is installed once, and the identifier is passed as bytes.
    expect(scripts.where((s) => s.contains('function runBotGuard')).length, 1);
    expect(
      scripts.where((s) => s.contains('obtainPoToken(new Uint8Array(')).length,
      2,
    );
  });

  test('a second track reuses the BotGuard session', () async {
    var watchReads = 0;
    final dio = mockDio((options) async {
      if (options.uri.path == '/watch') {
        watchReads++;
        return (200, _watchPage());
      }
      if (options.uri.host == 'www.google.com') return (200, 'interpreter();');
      return (
        200,
        jsonEncode([
          base64Encode([1, 2, 3]),
          43200,
        ]),
      );
    });
    final minter = PoTokenMinter(
      dio: dio,
      evaluate: (script) async {
        if (script.contains('__ntPoSnapshot')) {
          return jsonEncode({'state': 'ready', 'value': 'snapshot'});
        }
        if (script.contains('__ntPoMinter')) {
          return jsonEncode({'state': 'ready', 'value': 'ready'});
        }
        if (script.contains('__ntPoToken')) {
          return jsonEncode({'state': 'ready', 'value': '1,2,3'});
        }
        return '"started"';
      },
      userAgent: 'test-agent',
    );
    addTearDown(minter.close);

    await minter.mint(videoId: 'one', visitorData: 'visitor-1');
    await minter.mint(videoId: 'two', visitorData: 'visitor-1');

    expect(watchReads, 1);
  });

  test('a failing engine yields no token instead of throwing', () async {
    final dio = mockDio((options) async {
      if (options.uri.path == '/watch') return (200, _watchPage());
      if (options.uri.host == 'www.google.com') return (200, 'interpreter();');
      return (
        200,
        jsonEncode([
          base64Encode([1, 2, 3]),
          43200,
        ]),
      );
    });
    final minter = PoTokenMinter(
      dio: dio,
      evaluate: (script) async => throw const PoTokenException('no engine'),
      userAgent: 'test-agent',
    );
    addTearDown(minter.close);

    expect(await minter.mint(videoId: 'vid', visitorData: 'visitor-1'), isNull);
  });
}
