// Stream resolution tests: VISIONOS is the default client; Android VR and
// authenticated WEB_REMIX provide native InnerTube fallbacks.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/js_challenge_solver.dart';
import 'package:nixietube/core/innertube/player_presolver.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';

import 'mock_dio.dart';

const _visitorPage = '<script>"VISITOR_DATA":"visitor-1"</script>';

String? _header(RequestOptions options, String name) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value?.toString();
    }
  }
  return null;
}

Map<String, dynamic> _body(RequestOptions options) =>
    jsonDecode(options.data as String) as Map<String, dynamic>;

Map<String, dynamic> _okPlayer(String url, {int bitrate = 128000}) => {
  'playabilityStatus': {'status': 'OK'},
  'videoDetails': {'lengthSeconds': '201'},
  'streamingData': {
    'adaptiveFormats': [
      {'mimeType': 'audio/webm; codecs="opus"', 'bitrate': bitrate, 'url': url},
      {
        'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
        'bitrate': bitrate - 1,
        'url': 'https://example.com/lower',
      },
      {
        'mimeType': 'video/mp4; codecs="avc1"',
        'bitrate': bitrate + 100000,
        'url': 'https://example.com/video',
      },
    ],
  },
};

Map<String, dynamic> _status(String status) => {
  'playabilityStatus': {'status': status},
};

Map<String, dynamic> _hlsPlayer(String url) => {
  'playabilityStatus': {'status': 'OK'},
  'videoDetails': {'lengthSeconds': '201'},
  'streamingData': {'hlsManifestUrl': url},
};

void main() {
  test('visionos resolve uses the VISIONOS client', () async {
    final requests = <RequestOptions>[];
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET') return (200, _visitorPage);
      return (200, jsonEncode(_okPlayer('https://example.com/visionos')));
    });
    final resolver = StreamResolver(dio: dio);

    final stream = await resolver.resolve('vid');

    expect(stream, isNotNull);
    expect(stream!.url, 'https://example.com/visionos');
    expect(stream.bitrate, 128000);
    expect(stream.codec, 'opus');
    expect(stream.durationSec, 201);

    final player = requests.singleWhere(
      (r) => r.method == 'POST' && r.uri.host == 'music.youtube.com',
    );
    expect(_header(player, 'x-youtube-client-name'), '101');
    expect(_header(player, 'x-youtube-client-version'), '1.02');
    expect(_header(player, 'user-agent'), _visionosUserAgent);

    final body = _body(player);
    expect(body['videoId'], 'vid');
    expect(body['contentCheckOk'], isTrue);
    expect(body['racyCheckOk'], isTrue);
    final context = body['context'] as Map<String, dynamic>;
    expect(
      (context['client'] as Map<String, dynamic>)['clientName'],
      'VISIONOS',
    );
    expect((context['user'] as Map<String, dynamic>), isEmpty);

    resolver.close();
  });

  test('HLS manifest is usable as a direct resolved stream', () async {
    final dio = mockDio((options) async {
      if (options.method == 'GET') return (200, _visitorPage);
      return (200, jsonEncode(_hlsPlayer('https://example.com/manifest.m3u8')));
    });
    final resolver = StreamResolver(dio: dio);

    final stream = await resolver.resolve('vid');

    expect(stream, isNotNull);
    expect(stream!.url, 'https://example.com/manifest.m3u8');
    expect(stream.codec, 'hls');
    expect(stream.durationSec, 201);

    resolver.close();
  });

  test(
    'Android VR 1.65.10 fallback uses direct audio without yt-dlp',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') return (200, _visitorPage);
        final body = _body(options);
        if (body['context']['client']['clientName'] == 'VISIONOS') {
          return (200, jsonEncode(_status('LOGIN_REQUIRED')));
        }
        if (body['context']['client']['clientVersion'] == '1.65.10') {
          return (200, jsonEncode(_okPlayer('https://example.com/android-vr')));
        }
        return (200, jsonEncode(_status('UNPLAYABLE')));
      });
      final resolver = StreamResolver(dio: dio);

      final stream = await resolver.resolve('vid');

      expect(stream, isNotNull);
      expect(stream!.url, 'https://example.com/android-vr');
      final player = requests.singleWhere(
        (r) =>
            r.method == 'POST' &&
            _body(r)['context']['client']['clientVersion'] == '1.65.10',
      );
      expect(_header(player, 'x-youtube-client-name'), '28');
      expect(
        (_body(player)['context']['client'] as Map)['deviceModel'],
        'Quest 3',
      );

      resolver.close();
    },
  );

  test(
    'authenticated WEB_REMIX fallback sends cookie and SAPISIDHASH',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') {
          if (options.uri.path == '/watch') {
            return (200, '<script src="/s/player/test/base.js"></script>');
          }
          if (options.uri.path == '/s/player/test/base.js') {
            return (200, 'signatureTimestamp:20774');
          }
          return (200, _visitorPage);
        }
        final body = _body(options);
        final client = body['context']['client'] as Map<String, dynamic>;
        if (client['clientName'] == 'WEB_REMIX') {
          return (
            200,
            jsonEncode(_okPlayer('https://example.com/authenticated')),
          );
        }
        return (200, jsonEncode(_status('LOGIN_REQUIRED')));
      });
      final resolver = StreamResolver(
        dio: dio,
        auth: const AuthSession(
          cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
          sapisidHash: '1234_deadbeef',
        ),
      );

      final stream = await resolver.resolve('vid');

      expect(stream, isNotNull);
      expect(stream!.url, 'https://example.com/authenticated');
      final webRemix = requests.singleWhere(
        (r) =>
            r.method == 'POST' &&
            (_body(r)['context']['client'] as Map)['clientName'] == 'WEB_REMIX',
      );
      expect(
        _header(webRemix, 'cookie'),
        'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
      );
      expect(_header(webRemix, 'authorization'), 'SAPISIDHASH 1234_deadbeef');
      expect(
        _body(
          webRemix,
        )['playbackContext']['contentPlaybackContext']['signatureTimestamp'],
        20774,
      );

      resolver.close();
    },
  );

  test(
    'authenticated ANDROID_VR serves age-restricted tracks directly',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') {
          if (options.uri.path == '/watch') {
            return (200, '<script>"signatureTimestamp":20774</script>');
          }
          return (200, _visitorPage);
        }
        final client = _body(options)['context']['client'] as Map;
        if (client['clientName'] == 'WEB_REMIX') {
          // Cipher-only: no direct URL, exactly what age-restricted
          // WEB_REMIX answers with. The resolver must not hand this to
          // the player.
          return (
            200,
            jsonEncode({
              'playabilityStatus': {'status': 'OK'},
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 131000,
                    'signatureCipher': 's=abc',
                  },
                ],
              },
            }),
          );
        }
        if (client['clientName'] == 'ANDROID_VR') {
          return (200, jsonEncode(_okPlayer('https://example.com/vr-direct')));
        }
        return (200, jsonEncode(_status('LOGIN_REQUIRED')));
      });
      final resolver = StreamResolver(
        dio: dio,
        auth: const AuthSession(
          cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
          sapisidHash: '1234_deadbeef',
        ),
      );

      final stream = await resolver.resolve('vid');

      expect(stream, isNotNull);
      expect(stream!.url, 'https://example.com/vr-direct');
      final vr = requests.singleWhere(
        (r) =>
            r.method == 'POST' &&
            (_body(r)['context']['client'] as Map)['clientName'] ==
                'ANDROID_VR',
      );
      expect(_header(vr, 'cookie'), contains('__Secure-3PAPISID=test-sapisid'));
      expect(_header(vr, 'authorization'), 'SAPISIDHASH 1234_deadbeef');
      // The Android client is a YouTube client; the music endpoint
      // rejects it with HTTP 400.
      expect(vr.uri.host, 'www.youtube.com');
      // A signature timestamp belongs to the WEB clients only; sending
      // one to a native client makes the player reject the request.
      expect(_body(vr)['playbackContext'], isNull);

      resolver.close();
    },
  );

  test('signed-in resolve still uses the anonymous VISIONOS URL', () async {
    final requests = <RequestOptions>[];
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET') return (200, _visitorPage);
      final client = _body(options)['context']['client'] as Map;
      // Every client would answer; VISIONOS is the one whose URLs serve
      // arbitrary ranges, so a normal track must not go past it.
      if (client['clientName'] == 'VISIONOS') {
        return (200, jsonEncode(_okPlayer('https://example.com/visionos')));
      }
      return (200, jsonEncode(_okPlayer('https://example.com/other')));
    });
    final resolver = StreamResolver(
      dio: dio,
      auth: const AuthSession(
        cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
        sapisidHash: '1234_deadbeef',
      ),
    );

    final stream = await resolver.resolve('vid');

    expect(stream!.url, 'https://example.com/visionos');
    expect(stream.rangeLimited, isFalse);
    final player = requests.singleWhere((r) => r.method == 'POST');
    expect(_header(player, 'cookie'), isNull);

    resolver.close();
  });

  test('a cipher-only WEB_REMIX response is solved and played', () async {
    final requests = <RequestOptions>[];
    final cipher = Uri(
      queryParameters: {
        'url': 'https://example.com/videoplayback?expire=1&n=n-challenge',
        's': 's-challenge',
        'sp': 'sig',
      },
    ).query;
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET') {
        if (options.uri.path == '/watch') {
          return (
            200,
            '<script>"signatureTimestamp":20774</script>'
                '<script src="/s/player/test/base.js"></script>',
          );
        }
        if (options.uri.path == '/s/player/test/base.js') {
          return (200, 'var player = 1;');
        }
        return (200, _visitorPage);
      }
      final client = _body(options)['context']['client'] as Map;
      if (client['clientName'] == 'WEB_REMIX') {
        return (
          200,
          jsonEncode({
            'playabilityStatus': {'status': 'OK'},
            'videoDetails': {'lengthSeconds': '200'},
            'streamingData': {
              'adaptiveFormats': [
                {
                  'mimeType': 'audio/webm; codecs="opus"',
                  'bitrate': 160000,
                  'signatureCipher': cipher,
                },
              ],
            },
          }),
        );
      }
      return (200, jsonEncode(_status('LOGIN_REQUIRED')));
    });
    final solver = _FakeChallengeSolver({
      's-challenge': 'solved-signature',
      'n-challenge': 'solved-n',
    });
    final resolver = StreamResolver(
      dio: dio,
      auth: const AuthSession(
        cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
        sapisidHash: '1234_deadbeef',
      ),
      challengeSolver: solver,
    );

    final stream = await resolver.resolve('vid');

    expect(stream, isNotNull);
    expect(stream!.bitrate, 160000);
    final url = Uri.parse(stream.url);
    expect(url.queryParameters['sig'], 'solved-signature');
    expect(url.queryParameters['n'], 'solved-n');
    expect(solver.playerJs, 'var player = 1;');
    expect(solver.preprocessedPlayer, isNull);
    expect(solver.sigChallenges, ['s-challenge']);
    expect(solver.nChallenges, ['n-challenge']);

    resolver.close();
  });

  test('a published pre-solved player replaces the local AST pass', () async {
    final playerCache = Directory.systemTemp.createTempSync('presolved');
    addTearDown(() => playerCache.deleteSync(recursive: true));
    final requests = <RequestOptions>[];
    final cipher = Uri(
      queryParameters: {
        'url': 'https://example.com/videoplayback?expire=1&n=n-challenge',
        's': 's-challenge',
        'sp': 'sig',
      },
    ).query;
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET' && options.uri.path == '/watch') {
        return (
          200,
          '<script>"signatureTimestamp":20774</script>'
              '<script src="/s/player/b485e332/player_es6.vflset/en_US/'
              'base.js"></script>',
        );
      }
      if (options.method == 'GET' && options.uri.path.endsWith('base.js')) {
        return (200, 'var player = 1;');
      }
      if (options.method == 'GET') return (200, _visitorPage);
      final client = _body(options)['context']['client'] as Map;
      if (client['clientName'] == 'WEB_REMIX') {
        return (
          200,
          jsonEncode({
            'playabilityStatus': {'status': 'OK'},
            'videoDetails': {'lengthSeconds': '200'},
            'streamingData': {
              'adaptiveFormats': [
                {
                  'mimeType': 'audio/webm; codecs="opus"',
                  'bitrate': 160000,
                  'signatureCipher': cipher,
                },
              ],
            },
          }),
        );
      }
      return (200, jsonEncode(_status('LOGIN_REQUIRED')));
    });
    final artifactRequests = <Uri>[];
    final presolved = PresolvedPlayers(
      dir: playerCache.path,
      dio: mockDio((options) async {
        artifactRequests.add(options.uri);
        return (200, _artifact);
      }),
    );
    final solver = _FakeChallengeSolver({
      's-challenge': 'solved-signature',
      'n-challenge': 'solved-n',
    });
    final resolver = StreamResolver(
      dio: dio,
      auth: const AuthSession(
        cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
        sapisidHash: '1234_deadbeef',
      ),
      challengeSolver: solver,
      presolvedPlayers: presolved,
    );

    final stream = await resolver.resolve('vid');

    expect(stream, isNotNull);
    final url = Uri.parse(stream!.url);
    expect(url.queryParameters['sig'], 'solved-signature');
    expect(url.queryParameters['n'], 'solved-n');
    // The solver ran on the published artifact: the 2.6 MB player script
    // was never downloaded, which is the point of publishing it.
    expect(solver.preprocessedPlayer, _artifact.trim());
    expect(solver.playerJs, isNull);
    expect(artifactRequests.single.path, endsWith('/b485e332.js'));
    expect(
      requests.where((r) => r.uri.path.endsWith('base.js')),
      isEmpty,
      reason: 'the raw player script must not be fetched',
    );

    resolver.close();
  });

  test('a response with neither cipher nor `n` fetches no script', () async {
    final playerCache = Directory.systemTemp.createTempSync('presolved-unused');
    addTearDown(() => playerCache.deleteSync(recursive: true));
    final requests = <RequestOptions>[];
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET' && options.uri.path == '/watch') {
        return (
          200,
          '<script>"signatureTimestamp":20774</script>'
              '<script src="/s/player/b485e332/base.js"></script>',
        );
      }
      if (options.method == 'GET') return (200, _visitorPage);
      final client = _body(options)['context']['client'] as Map;
      if (client['clientName'] == 'WEB_REMIX') {
        return (200, jsonEncode(_okPlayer('https://example.com/plain-url')));
      }
      return (200, jsonEncode(_status('LOGIN_REQUIRED')));
    });
    final resolver = StreamResolver(
      dio: dio,
      auth: const AuthSession(
        cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
        sapisidHash: '1234_deadbeef',
      ),
      challengeSolver: _FakeChallengeSolver(const {}),
      presolvedPlayers: PresolvedPlayers(
        dir: playerCache.path,
        dio: mockDio((options) async => (404, 'not found')),
      ),
    );

    final stream = await resolver.resolve('vid');

    expect(stream!.url, 'https://example.com/plain-url');
    expect(
      requests.where(
        (r) =>
            r.uri.path.endsWith('base.js') ||
            r.uri.host == 'raw.githubusercontent.com',
      ),
      isEmpty,
      reason: 'nothing to solve, so no script is needed',
    );

    resolver.close();
  });

  test(
    'authenticated TVHTML5 downgrade fallback uses cookie session',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') {
          if (options.uri.path == '/watch') {
            return (200, '<script>"signatureTimestamp":20774</script>');
          }
          return (200, _visitorPage);
        }
        final body = _body(options);
        final client = body['context']['client'] as Map<String, dynamic>;
        if (client['clientName'] == 'TVHTML5') {
          return (200, jsonEncode(_okPlayer('https://example.com/tv-html5')));
        }
        return (200, jsonEncode(_status('LOGIN_REQUIRED')));
      });
      final resolver = StreamResolver(
        dio: dio,
        auth: const AuthSession(
          cookie: 'VISITOR_INFO1_LIVE=x; __Secure-3PAPISID=test-sapisid',
          sapisidHash: '1234_deadbeef',
        ),
      );

      final stream = await resolver.resolve('vid');

      expect(stream, isNotNull);
      expect(stream!.url, 'https://example.com/tv-html5');
      final tvPlayer = requests.singleWhere(
        (r) =>
            r.method == 'POST' &&
            (_body(r)['context']['client'] as Map)['clientName'] == 'TVHTML5',
      );
      expect(_header(tvPlayer, 'x-youtube-client-name'), '7');
      expect(_header(tvPlayer, 'cookie'), isNotEmpty);
      expect(_header(tvPlayer, 'authorization'), 'SAPISIDHASH 1234_deadbeef');
      expect(
        (_body(tvPlayer)['context']['client'] as Map)['userAgent'],
        'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
      );

      resolver.close();
    },
  );

  test('visionos login-required status falls back to Android VR', () async {
    final requests = <RequestOptions>[];
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET') return (200, _visitorPage);
      if (options.method == 'POST' && options.uri.host == 'music.youtube.com') {
        return (200, jsonEncode(_status('LOGIN_REQUIRED')));
      }
      return (200, '');
    });
    final resolver = StreamResolver(dio: dio);

    final stream = await resolver.resolve('vid');

    expect(stream, isNull);

    resolver.close();
  });

  test(
    'visionos age-verification-required status falls back to Android VR',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') return (200, _visitorPage);
        if (options.method == 'POST' &&
            options.uri.host == 'music.youtube.com') {
          return (200, jsonEncode(_status('AGE_VERIFICATION_REQUIRED')));
        }
        return (200, '');
      });
      final resolver = StreamResolver(dio: dio);

      final stream = await resolver.resolve('vid');

      expect(stream, isNull);

      resolver.close();
    },
  );

  test('anonymous resolve never retries on unrelated errors', () async {
    final requests = <RequestOptions>[];
    final dio = mockDio((options) async {
      requests.add(options);
      if (options.method == 'GET') return (200, _visitorPage);
      return (200, jsonEncode(_status('UNPLAYABLE')));
    });
    final resolver = StreamResolver(dio: dio);

    final stream = await resolver.resolve('vid');

    expect(stream, isNull);

    resolver.close();
  });

  test('a track unplayable for both clients resolves to null', () async {
    final dio = mockDio((options) async {
      if (options.method == 'GET') return (200, _visitorPage);
      return (200, jsonEncode(_status('LOGIN_REQUIRED')));
    });
    final resolver = StreamResolver(dio: dio);
    expect(await resolver.resolve('vid'), isNull);

    resolver.close();
  });
}

const _visionosUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';

/// A stand-in for what `tool/ejs_presolve.js` publishes: player code that
/// fills `_result` with the two challenge entry points, long enough to
/// pass the artifact check.
final _artifact =
    'if (typeof globalThis.XMLHttpRequest === "undefined") {}\n'
    '${'var a = 1;\n' * 400}'
    '_result.n = n;\n'
    '_result.sig = sig;\n';

/// Records what the resolver asked and answers from [answers].
class _FakeChallengeSolver implements ChallengeSolver {
  _FakeChallengeSolver(this.answers);

  final Map<String, String> answers;
  String? playerJs;
  String? preprocessedPlayer;
  List<String> sigChallenges = const [];
  List<String> nChallenges = const [];

  @override
  Future<void> warmUp() async {}

  @override
  Future<Map<String, String>> solve({
    String? playerJs,
    String? preprocessedPlayer,
    List<String> sigChallenges = const [],
    List<String> nChallenges = const [],
  }) async {
    this.playerJs = playerJs;
    this.preprocessedPlayer = preprocessedPlayer;
    this.sigChallenges = sigChallenges;
    this.nChallenges = nChallenges;
    return answers;
  }
}
