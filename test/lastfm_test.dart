// Last.fm scrobbling unit tests: MD5 signing, the web-auth handshake, the
// enable/session gating, and the now-playing / scrobble threshold logic
// driven through player-state updates.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show md5;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/sys_config.dart';

import 'mock_dio.dart';

const _key = 'apikey123';
const _secret = 'sharedsecret456';

void main() {
  late Directory dir;
  late List<RequestOptions> calls;
  late SysConfig config;
  late LastFmService service;

  void startService({
    bool enabled = true,
    bool session = true,
    Future<(int, Object)> Function(RequestOptions)? handler,
  }) {
    calls = [];
    config = SysConfig(configPath: '${dir.path}/config.properties');
    config.lastfmApiKey = _key;
    config.lastfmSecret = _secret;
    config.lastfmSessionKey = session ? 'sessionkey789' : '';
    config.lastfmUsername = 'testuser';
    config.lastfmEnabled = enabled;
    final client = mockDio((options) async {
      calls.add(options);
      return handler != null ? handler(options) : (200, '{}');
    });
    service = LastFmService(config: config, dio: client);
    addTearDown(service.dispose);
  }

  Map<String, String> form(RequestOptions r) =>
      Map<String, String>.from(r.data as Map);

  List<RequestOptions> callsFor(String method) => calls
      .where(
        (r) =>
            // GETs carry the method in the query string; POSTs in the body.
            r.uri.queryParameters['method'] == method ||
            (r.data is Map && form(r)['method'] == method),
      )
      .toList();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt-lastfm-');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  test('auth.getToken is MD5-signed and parses the token', () async {
    startService(
      handler: (r) async => (200, jsonEncode({'token': 'token123'})),
    );
    final token = await service.requestToken();
    expect(token, 'token123');
    expect(calls, hasLength(1));
    final call = calls.first;
    expect(call.uri.toString(), lastfmApiUrl);
    final fields = form(call);
    expect(fields['method'], 'auth.getToken');
    expect(fields['api_key'], _key);
    expect(fields['format'], 'json');
    // api_sig = lowercase hex md5 of sorted "keyvalue" concat + secret.
    final base =
        'api_key$_key'
        'methodauth.getToken'
        '$_secret';
    expect(fields['api_sig'], md5.convert(utf8.encode(base)).toString());
  });

  test('built-in credentials are non-empty', () {
    expect(defaultLastfmApiKey.trim(), isNotEmpty);
    expect(defaultLastfmSecret.trim(), isNotEmpty);
  });

  test(
    'requestToken falls back to the built-in key when fields are empty',
    () async {
      startService(
        handler: (r) async => (200, jsonEncode({'token': 'token123'})),
      );
      config.lastfmApiKey = '';
      config.lastfmSecret = '';
      final token = await service.requestToken();
      expect(token, 'token123');
      expect(calls, hasLength(1));
      final fields = form(calls.first);
      // Built-in key sent, signed with the built-in secret.
      expect(fields['api_key'], defaultLastfmApiKey);
      expect(fields['api_key'], isNot(_key));
      final base =
          'api_key$defaultLastfmApiKey'
          'methodauth.getToken'
          '$defaultLastfmSecret';
      expect(fields['api_sig'], md5.convert(utf8.encode(base)).toString());
    },
  );

  test('custom credentials override the built-in key', () async {
    startService(
      handler: (r) async => (200, jsonEncode({'token': 'token123'})),
    );
    expect(config.lastfmApiKey, _key);
    final token = await service.requestToken();
    expect(token, 'token123');
    expect(form(calls.first)['api_key'], _key);
  });

  test('requestToken surfaces an API error', () async {
    startService(
      handler: (r) async =>
          (200, jsonEncode({'error': 4, 'message': 'Key not found'})),
    );
    final token = await service.requestToken();
    expect(token, isNull);
    expect(service.status, contains('Key not found'));
  });

  test('authorizeUrl builds the browser approval link', () async {
    startService();
    expect(
      service.authorizeUrl('tok'),
      '$lastfmAuthUrl?api_key=$_key&token=tok',
    );
  });

  test('completeAuth persists session key and username', () async {
    startService(
      session: false,
      handler: (r) async => (
        200,
        jsonEncode({
          'session': {'key': 'newsk', 'name': 'bob'},
        }),
      ),
    );
    expect(await service.completeAuth('tok'), isTrue);
    expect(config.lastfmSessionKey, 'newsk');
    expect(config.lastfmUsername, 'bob');
    expect(service.status, 'signed in as bob');
    expect(service.ready(), isTrue);
    final fields = form(calls.first);
    expect(fields['method'], 'auth.getSession');
    expect(fields['token'], 'tok');
  });

  test('completeAuth surfaces an API error and keeps session', () async {
    startService(
      handler: (r) async =>
          (200, jsonEncode({'error': 4, 'message': 'Unauthorized'})),
    );
    expect(await service.completeAuth('tok'), isFalse);
    expect(service.status, contains('Unauthorized'));
    // The prior session is untouched by a failed exchange.
    expect(config.lastfmSessionKey, 'sessionkey789');
  });

  test('logout clears the session, keeping key/secret', () async {
    startService();
    expect(service.ready(), isTrue);
    service.logout();
    expect(config.lastfmSessionKey, '');
    expect(config.lastfmUsername, '');
    expect(config.lastfmApiKey, _key);
    expect(service.status, 'signed out');
    expect(service.ready(), isFalse);
  });

  test('ready() gates on enabled and session (key always resolves)', () async {
    startService();
    expect(service.ready(), isTrue);
    config.lastfmEnabled = false;
    expect(service.ready(), isFalse);
    config.lastfmEnabled = true;
    // Empty fields fall back to the built-in key: still ready.
    config.lastfmApiKey = '';
    config.lastfmSecret = '';
    expect(service.ready(), isTrue);
    config.lastfmSessionKey = '';
    expect(service.ready(), isFalse);
  });

  test('refreshStatus reflects disabled, signed out and signed in', () async {
    startService();
    config.lastfmEnabled = false;
    service.refreshStatus();
    expect(service.status, 'disabled');
    config.lastfmEnabled = true;
    config.lastfmSessionKey = '';
    service.refreshStatus();
    expect(service.status, 'signed out');
    config.lastfmSessionKey = 'sk';
    service.refreshStatus();
    expect(service.status, 'signed in as testuser');
  });

  const track = Track(
    videoId: 'v1',
    title: 'Song',
    artists: [ArtistRef('Artist')],
    album: AlbumRef('Album'),
    durationSec: 200,
  );

  test('new track sends now-playing; scrobble fires once past half', () async {
    startService();
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 60000),
    );
    // Before half (100s): no scrobble yet.
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 99000),
    );
    expect(callsFor('track.scrobble'), isEmpty);
    // Past half: exactly one scrobble.
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 100000),
    );
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 120000),
    );
    final scrobbles = callsFor('track.scrobble');
    expect(scrobbles, hasLength(1));
    final fields = form(scrobbles.first);
    expect(fields['artist'], 'Artist');
    expect(fields['track'], 'Song');
    expect(fields['album'], 'Album');
    expect(fields['duration'], '200');
    expect(fields['sk'], 'sessionkey789');
    expect(int.tryParse(fields['timestamp'] ?? ''), greaterThan(0));
    // Now-playing fired on track start, before the scrobble.
    final nowPlayings = callsFor('track.updateNowPlaying');
    expect(nowPlayings, hasLength(1));
    expect(
      calls.indexOf(nowPlayings.first),
      lessThan(calls.indexOf(scrobbles.first)),
    );
    // No duplicate scrobble on later progress.
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 199000),
    );
    expect(callsFor('track.scrobble'), hasLength(1));
  });

  test('tracks under 30 seconds never scrobble', () async {
    startService();
    const short = Track(
      videoId: 's1',
      title: 'Short',
      artists: [ArtistRef('A')],
      durationSec: 20,
    );
    await service.update(
      PlayerState(current: short, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: short, playing: true, positionMs: 20000),
    );
    expect(callsFor('track.scrobble'), isEmpty);
  });

  test('long tracks scrobble at the 4-minute cap', () async {
    startService();
    const long = Track(
      videoId: 'l1',
      title: 'Long',
      artists: [ArtistRef('A')],
      durationSec: 600,
    );
    await service.update(
      PlayerState(current: long, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: long, playing: true, positionMs: 239000),
    );
    expect(callsFor('track.scrobble'), isEmpty);
    await service.update(
      PlayerState(current: long, playing: true, positionMs: 240000),
    );
    expect(callsFor('track.scrobble'), hasLength(1));
  });

  test('paused playback never scrobbles', () async {
    startService();
    await service.update(
      PlayerState(current: track, playing: false, positionMs: 0),
    );
    await service.update(
      PlayerState(current: track, playing: false, positionMs: 150000),
    );
    expect(callsFor('track.scrobble'), isEmpty);
  });

  test('backward seek before the threshold restarts the play', () async {
    startService();
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 60000),
    );
    // Big seek back: a new play (another now-playing), no scrobble yet.
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 5000),
    );
    expect(callsFor('track.scrobble'), isEmpty);
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 100000),
    );
    expect(callsFor('track.scrobble'), hasLength(1));
    // Two now-playings: the original start and the restart.
    expect(callsFor('track.updateNowPlaying'), hasLength(2));
  });

  test('primary artist is used, joined credit as fallback', () async {
    startService();
    const multi = Track(
      videoId: 'm1',
      title: 'Duet',
      artists: [ArtistRef('Primo'), ArtistRef('Secondo')],
      durationSec: 200,
    );
    await service.update(
      PlayerState(current: multi, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: multi, playing: true, positionMs: 100000),
    );
    expect(form(callsFor('track.scrobble').first)['artist'], 'Primo');
    expect(form(callsFor('track.updateNowPlaying').first)['artist'], 'Primo');

    const unlinked = Track(videoId: 'u1', title: 'Solo', durationSec: 200);
    await service.update(
      PlayerState(current: unlinked, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: unlinked, playing: true, positionMs: 100000),
    );
    // A track with no artist at all is never scrobbled (blank artist guard),
    // so the only scrobble still belongs to the duet.
    expect(callsFor('track.scrobble'), hasLength(1));
    expect(form(callsFor('track.scrobble').first)['artist'], 'Primo');
  });

  test('disabled scrobbling sends nothing', () async {
    startService(enabled: false);
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 120000),
    );
    expect(calls, isEmpty);
  });

  test('session-less scrobbling sends nothing', () async {
    startService(session: false);
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 120000),
    );
    expect(calls, isEmpty);
  });

  group('cleanScrobbleTitle', () {
    test('strips parenthesized and bare feature credits', () {
      expect(cleanScrobbleTitle('Song (feat. Artist)'), 'Song');
      expect(cleanScrobbleTitle('Song [feat. Artist]'), 'Song');
      expect(cleanScrobbleTitle('Song feat. Artist'), 'Song');
      expect(cleanScrobbleTitle('Song ft. Artist'), 'Song');
      expect(cleanScrobbleTitle('Song ft Artist'), 'Song');
      expect(cleanScrobbleTitle('Song featuring Artist'), 'Song');
      expect(cleanScrobbleTitle('Song w/ Artist'), 'Song');
    });

    test('is case-insensitive and keeps mid-title clauses', () {
      expect(cleanScrobbleTitle('Song (Feat. Artist)'), 'Song');
      expect(cleanScrobbleTitle('Song (FEATURING Artist)'), 'Song');
      // Mid-title clause is removed, the rest of the title survives.
      expect(cleanScrobbleTitle('Song (ft. X) Remix'), 'Song Remix');
    });

    test('leaves titles without a credit untouched', () {
      expect(cleanScrobbleTitle('Song'), 'Song');
      expect(cleanScrobbleTitle('Song (Live)'), 'Song (Live)');
      expect(cleanScrobbleTitle('Song feat.'), 'Song feat.');
      expect(cleanScrobbleTitle('Song featuring'), 'Song featuring');
    });
  });

  test('scrobbler sends the clean title and the first artist only', () async {
    startService();
    const ft = Track(
      videoId: 'f1',
      title: 'Anthem (feat. Special Guest)',
      artists: [ArtistRef('Headline'), ArtistRef('Other')],
      durationSec: 200,
    );
    await service.update(
      PlayerState(current: ft, playing: true, positionMs: 0),
    );
    await service.update(
      PlayerState(current: ft, playing: true, positionMs: 100000),
    );
    final nowPlaying = form(callsFor('track.updateNowPlaying').first);
    expect(nowPlaying['track'], 'Anthem');
    expect(nowPlaying['artist'], 'Headline');
    final scrobbled = form(callsFor('track.scrobble').first);
    expect(scrobbled['track'], 'Anthem');
    expect(scrobbled['artist'], 'Headline');
  });

  group('cleanInfoTitle', () {
    test('strips trailing playback-noise tags', () {
      expect(cleanInfoTitle('Engravings (Official Video)'), 'Engravings');
      expect(cleanInfoTitle('Engravings (Official Music Video)'), 'Engravings');
      expect(cleanInfoTitle('Song [Lyrics]'), 'Song');
      expect(cleanInfoTitle('Song (HD)'), 'Song');
      expect(cleanInfoTitle('Song (M/V)'), 'Song');
      expect(cleanInfoTitle('Song 4K'), 'Song 4K');
    });

    test('keeps musical versions and ordinary parentheses', () {
      expect(cleanInfoTitle('Song (Remastered 2011)'), 'Song (Remastered 2011)');
      expect(cleanInfoTitle('Song (Live)'), 'Song (Live)');
      expect(cleanInfoTitle('Song (feat. X)'), 'Song (feat. X)');
      expect(cleanInfoTitle('Song'), 'Song');
      expect(cleanInfoTitle('(Official) Song'), '(Official) Song');
    });
  });

  group('trackInfo', () {
    // The handler route is by method, so the query string headers in
    // queryParameters carry the request's identifying parameter set.
    test('direct lookup uses the cleaned title and autocorrect', () async {
      startService(
        handler: (r) async {
          expect(r.uri.queryParameters['method'], 'track.getInfo');
          expect(r.uri.queryParameters['track'], 'Engravings');
          expect(r.uri.queryParameters['autocorrect'], '1');
          return (
            200,
            jsonEncode({
              'track': {'name': 'Engravings', 'playcount': '100'},
            })
          );
        },
      );
      final res = await service.trackInfo(
        'Ethan Bortnick',
        'Engravings (Official Video)',
      );
      expect(res, isNotNull);
      expect(res!['name'], 'Engravings');
    });

    test('falls back to a scored search and resolves by MBID', () async {
      startService(
        handler: (r) async {
          switch (r.uri.queryParameters['method']) {
            case 'track.search':
              return (
                200,
                jsonEncode({
                  'results': {
                    'trackmatches': {
                      'track': [
                        // Right song but no MBID, duration off enough that
                        // the scored candidate below wins.
                        {
                          'name': 'Engravings',
                          'artist': 'Ethan Bortnick',
                          'mbid': '',
                          'duration': '300',
                        },
                        {
                          'name': 'Engravings',
                          'artist': 'Ethan Bortnick',
                          'mbid': 'mb-1',
                          'duration': '250',
                        },
                        {
                          'name': 'Other Song',
                          'artist': 'Someone Else',
                          'mbid': 'mb-2',
                          'duration': '250',
                        },
                      ],
                    },
                  },
                })
              );
            case 'track.getInfo':
              if (r.uri.queryParameters['mbid'] == 'mb-1') {
                return (
                  200,
                  jsonEncode({
                    'track': {'name': 'Engravings', 'listeners': '5'},
                  })
                );
              }
              return (
                200,
                jsonEncode({'error': '6', 'message': 'The track you requested could not be found'}),
              );
            default:
              fail('unexpected call ${r.uri}');
          }
        },
      );
      final res = await service.trackInfo(
        'Ethan Bortnick',
        'Engravings',
        durationSec: 250,
      );
      expect(res, isNotNull);
      expect(res!['listeners'], '5');
      expect(callsFor('track.getInfo'), hasLength(2));
    });

    test('skips unrelated search candidates entirely', () async {
      startService(
        handler: (r) async {
          switch (r.uri.queryParameters['method']) {
            case 'track.search':
              return (
                200,
                jsonEncode({
                  'results': {
                    'trackmatches': {
                      'track': [
                        {
                          'name': 'Totally Different',
                          'artist': 'Someone Else',
                          'mbid': 'mb-9',
                          'duration': '90',
                        },
                      ],
                    },
                  },
                })
              );
            case 'track.getInfo':
              return (
                200,
                jsonEncode({'error': '6', 'message': 'The track you requested could not be found'}),
              );
            default:
              fail('unexpected call ${r.uri}');
          }
        },
      );
      expect(
        await service.trackInfo('Mia Wray', 'What I Want', durationSec: 200),
        isNull,
      );
    });

    test('rejects a title-only match without verifiable signals', () async {
      // Same song title, another artist, no duration — exactly the case
      // where Last.fm search returns the wrong track first.
      startService(
        handler: (r) async {
          switch (r.uri.queryParameters['method']) {
            case 'track.search':
              return (
                200,
                jsonEncode({
                  'results': {
                    'trackmatches': {
                      'track': [
                        {
                          'name': 'Engravings',
                          'artist': 'Some Other Composer',
                          'mbid': 'mb-9',
                        },
                      ],
                    },
                  },
                })
              );
            case 'track.getInfo':
              return (
                200,
                jsonEncode({'error': '6', 'message': 'not found'}),
              );
            default:
              fail('unexpected call ${r.uri}');
          }
        },
      );
      expect(
        await service.trackInfo('Ethan Bortnick', 'Engravings', durationSec: 148),
        isNull,
      );
    });
  });

  group('artistTags', () {
    test('returns the artist tag names', () async {
      startService(
        handler: (r) async {
          expect(r.uri.queryParameters['method'], 'artist.getTopTags');
          return (
            200,
            jsonEncode({
              'toptags': {
                'tag': [
                  {'name': 'pop'},
                  {'name': 'indie pop'},
                  'not a map',
                ],
              },
            })
          );
        },
      );
      expect(await service.artistTags('Some Artist'), ['pop', 'indie pop']);
    });

    test('returns empty when the artist is unknown or the call fails',
        () async {
      startService(
        handler: (r) async => (
          200,
          jsonEncode({'error': '6', 'message': 'not found'}),
        ),
      );
      expect(await service.artistTags('Unknown Artist'), isEmpty);
    });

    test('returns empty for a blank artist', () async {
      startService();
      expect(await service.artistTags(''), isEmpty);
      expect(calls, isEmpty);
    });
  });
}
