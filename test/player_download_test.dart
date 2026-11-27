// Download-ahead: how many queue rows the controller asks the cache to
// keep, and that the Settings value is what decides it. No audio, no
// network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';

import 'fakes.dart';

Track _track(String id) => Track(
  videoId: id,
  title: 'Song $id',
  artists: const [ArtistRef('Artist')],
  album: const AlbumRef('Album'),
  durationSec: 200,
);

/// Waits until [check] holds, up to about a second.
Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 50 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late List<String> downloads;
  late int ahead;
  late PlayerController controller;

  void build() {
    final dir = Directory.systemTemp.createTempSync('nt-download');
    addTearDown(() => dir.deleteSync(recursive: true));
    downloads = [];
    controller = PlayerController(
      engine: FakeEngine(),
      tube: FakeTube(),
      resolveStream: (id) async =>
          ResolvedStream(url: 'https://x/$id', bitrate: 128000),
      downloadTrack: (videoId) async {
        downloads.add(videoId);
      },
      downloadAhead: () => ahead,
      configDirPath: dir.path,
    );
    addTearDown(controller.dispose);
  }

  List<Track> queue(int count) =>
      [for (var i = 1; i <= count; i++) _track('v$i')];

  test('the setting decides how many rows past the current one download',
      () async {
    build();
    ahead = 5;

    controller.playTracks(queue(10));

    await _until(() => downloads.length >= 5);
    // Never the track being played: the proxy captures that one.
    expect(downloads, ['v2', 'v3', 'v4', 'v5', 'v6']);
  });

  test('a count below one still downloads the immediate next row', () async {
    build();
    ahead = 0;

    controller.playTracks(queue(4));

    await _until(() => downloads.isNotEmpty);
    expect(downloads, ['v2']);
  });

  test('a runaway count stops at the slider ceiling', () async {
    build();
    ahead = 40;

    controller.playTracks(queue(20));

    await _until(() => downloads.length >= 10);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(downloads, hasLength(10));
    expect(downloads.last, 'v11');
  });
}
