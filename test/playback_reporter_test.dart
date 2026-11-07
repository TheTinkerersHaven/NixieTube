// Tests for the watchtime reporter's beacon sequence: the pause that
// closes a track, the play that opens the next one, the play/pause
// transitions of the same track and the steady-playback heartbeat.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/playback_reporter.dart';

/// A beacon the reporter sent, as (videoId, state).
typedef Beacon = (String, String);

class _RecordingTube extends InnerTube {
  final List<Beacon> beacons = [];

  @override
  Future<bool> reportWatchtime(WatchtimeBeacon beacon) async {
    beacons.add((beacon.videoId, beacon.state.wireName));
    return true;
  }
}

PlayerState _state({
  String? videoId,
  bool playing = false,
  bool stopped = false,
  int positionMs = 0,
  int durationMs = 60000,
}) => PlayerState(
  current: videoId == null
      ? null
      : Track(videoId: videoId, title: 'Track $videoId'),
  playing: playing,
  stopped: stopped,
  positionMs: positionMs,
  durationMs: durationMs,
);

void main() {
  group('playback reporter', () {
    late _RecordingTube tube;
    late PlaybackReporter reporter;

    setUp(() {
      tube = _RecordingTube();
      addTearDown(tube.close);
      final dir = Directory.systemTemp.createTempSync('nt-report-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      reporter = PlaybackReporter(
        tube: tube,
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        notify: () {},
      );
    });

    test('the first track opens with a playing beacon', () async {
      await reporter.report(_state(videoId: 'a', playing: true));

      expect(tube.beacons, [('a', 'playing')]);
    });

    test(
      'a track switch pauses the old track before playing the new one',
      () async {
        await reporter.report(_state(videoId: 'a', playing: true));
        await reporter.report(_state(videoId: 'b', playing: true));

        expect(tube.beacons, [
          ('a', 'playing'),
          ('a', 'paused'),
          ('b', 'playing'),
        ]);
      },
    );

    test('pausing the same track emits one paused beacon', () async {
      await reporter.report(_state(videoId: 'a', playing: true));
      await reporter.report(_state(videoId: 'a', playing: false));

      expect(tube.beacons, [('a', 'playing'), ('a', 'paused')]);
    });

    test('resuming the same track emits one playing beacon', () async {
      await reporter.report(_state(videoId: 'a', playing: true));
      await reporter.report(_state(videoId: 'a', playing: false));
      await reporter.report(_state(videoId: 'a', playing: true));

      expect(tube.beacons, [
        ('a', 'playing'),
        ('a', 'paused'),
        ('a', 'playing'),
      ]);
    });

    test('a stop emits a paused beacon and no further ones', () async {
      await reporter.report(_state(videoId: 'a', playing: true));
      await reporter.report(_state(videoId: 'a', stopped: true));
      await reporter.report(_state(videoId: 'a', stopped: true));

      expect(tube.beacons, [('a', 'playing'), ('a', 'paused')]);
    });

    test('a steady track heartbeats on the second report', () async {
      await reporter.report(_state(videoId: 'a', playing: true));
      await reporter.report(_state(videoId: 'a', playing: true));

      expect(tube.beacons, [('a', 'playing'), ('a', 'playing')]);
    });
  });
}
