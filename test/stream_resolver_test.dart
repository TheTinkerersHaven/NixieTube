// Stream resolution tests: VISIONOS is the default client; when it returns
// a login or age-restriction status, yt-dlp is used as a fallback.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  test(
    'visionos resolve uses the VISIONOS client',
    () async {
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
        (r) => r.method == 'POST' && r.uri.host == 'www.youtube.com',
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
    },
  );

  test(
    'visionos login-required status falls back to yt-dlp',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') return (200, _visitorPage);
        if (options.method == 'POST' && options.uri.host == 'www.youtube.com') {
          return (200, jsonEncode(_status('LOGIN_REQUIRED')));
        }
        return (200, '');
      });
      final resolver = StreamResolver(dio: dio);

      final stream = await resolver.resolve('vid');

      expect(stream, isNull);

      resolver.close();
    },
  );

  test(
    'visionos age-verification-required status falls back to yt-dlp',
    () async {
      final requests = <RequestOptions>[];
      final dio = mockDio((options) async {
        requests.add(options);
        if (options.method == 'GET') return (200, _visitorPage);
        if (options.method == 'POST' && options.uri.host == 'www.youtube.com') {
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

  test(
    'anonymous resolve never retries on unrelated errors',
    () async {
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
    },
  );

  test(
    'a track unplayable for both clients resolves to null',
    () async {
      final dio = mockDio((options) async {
        if (options.method == 'GET') return (200, _visitorPage);
        return (200, jsonEncode(_status('LOGIN_REQUIRED')));
      });
      final resolver = StreamResolver(dio: dio);
      expect(await resolver.resolve('vid'), isNull);

      resolver.close();
    },
  );
}

const _visionosUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';
