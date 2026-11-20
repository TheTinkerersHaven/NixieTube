// ListenBrainz scrobbling tests: ready state, playing-now payload,
// scrobble threshold and token headers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/listenbrainz.dart';
import 'package:nixietube/sys/sys_config.dart';

import 'mock_dio.dart';

SysConfig _config() {
  final dir = Directory.systemTemp.createTempSync('nt-listenbrainz-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final config = SysConfig(configPath: '${dir.path}/config.properties');
  config.listenbrainzEnabled = true;
  config.listenbrainzToken = 'tok';
  return config;
}

void main() {
  test('ready follows the toggle and token', () async {
    final config = _config();
    final service = ListenBrainzService(
      config: config,
      dio: mockDio((_) async => (200, '{}')),
    );
    addTearDown(service.dispose);
    expect(service.status, 'token set');
    expect(service.ready(), isTrue);

    config.listenbrainzEnabled = false;
    service.refreshStatus();
    expect(service.status, 'disabled');
    expect(service.ready(), isFalse);

    config.listenbrainzEnabled = true;
    service.logout();
    expect(service.status, 'token needed');
    expect(service.ready(), isFalse);
  });

  test('a track emits playing_now then one scrobble', () async {
    final requests = <Map<String, dynamic>>[];
    final service = ListenBrainzService(
      config: _config(),
      dio: mockDio((options) async {
        expect(options.headers['Authorization'], 'Token tok');
        requests.add(
          jsonDecode(options.data as String) as Map<String, dynamic>,
        );
        return (200, '{}');
      }),
    );
    addTearDown(service.dispose);

    const track = Track(
      videoId: 'v1',
      title: 'One',
      artists: [ArtistRef('Act')],
      album: AlbumRef('Rec'),
      durationSec: 200,
    );
    await service.update(PlayerState(current: track, playing: true));

    expect(requests, hasLength(1));
    expect(requests.first['listen_type'], 'playing_now');
    final meta = requests.first['payload'][0]['track_metadata'];
    expect(meta['artist_name'], 'Act');
    expect(meta['track_name'], 'One');
    expect(meta['release_name'], 'Rec');
    expect(meta['additional_info']['origin_url'], 'https://youtu.be/v1');

    // Half of 200s is 100s: the threshold for this track.
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 100000),
    );
    expect(requests, hasLength(2));
    expect(requests[1]['listen_type'], 'single');
    expect(requests[1]['payload'][0]['listened_at'], isA<int>());
    expect(requests[1]['payload'][0]['track_metadata']['track_name'], 'One');

    // No second scrobble for the same play.
    await service.update(
      PlayerState(current: track, playing: true, positionMs: 150000),
    );
    expect(requests, hasLength(2));
  });

  test('short tracks are not scrobbled', () async {
    final requests = <Map<String, dynamic>>[];
    final service = ListenBrainzService(
      config: _config(),
      dio: mockDio((options) async {
        requests.add(
          jsonDecode(options.data as String) as Map<String, dynamic>,
        );
        return (200, '{}');
      }),
    );
    addTearDown(service.dispose);

    const short = Track(videoId: 's', title: 'Short', durationSec: 20);
    await service.update(PlayerState(current: short, playing: true));
    await service.update(
      PlayerState(current: short, playing: true, positionMs: 15000),
    );
    expect(requests, hasLength(1));
    expect(requests.first['listen_type'], 'playing_now');
  });
}
