// Tests for the sleep inhibitor: the lock is held exactly while the
// player reports playing, released on pause, released on dispose, and
// a failing backend never breaks playback state handling. The runner
// seam keeps real `systemd-inhibit` processes out of tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sleep_inhibit.dart';


class _FakeLock implements SleepInhibitHandle {
  var released = false;

  @override
  Future<void> release() async {
    released = true;
  }
}

Future<PlayerController> _player() async {
  final dir = Directory.systemTemp.createTempSync('nt-sleep-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 1),
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  return player;
}

Track _track(String id) => Track(videoId: id, title: 'T$id', durationSec: 200);

void main() {
  test('lock held while playing, released on pause', () async {
    final player = await _player();
    final locks = <_FakeLock>[];
    final svc = SleepInhibitService(
      controller: player,
      runner: () async {
        final lock = _FakeLock();
        locks.add(lock);
        return lock;
      },
    );
    await svc.start();
    // Idle: nothing taken.
    expect(locks, isEmpty);
    player.playTracks([_track('a'), _track('b')]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(player.state.playing, isTrue);
    expect(locks, hasLength(1));
    expect(locks.single.released, isFalse);
    // Paused: the one lock releases; pausing again is a no-op.
    player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(player.state.playing, isFalse);
    expect(locks.single.released, isTrue);
    player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(locks, hasLength(1));
    await svc.dispose();
  });

  test('dispose releases a held lock', () async {
    final player = await _player();
    final locks = <_FakeLock>[];
    final svc = SleepInhibitService(
      controller: player,
      runner: () async {
        final lock = _FakeLock();
        locks.add(lock);
        return lock;
      },
    );
    await svc.start();
    player.playTracks([_track('a'), _track('b')]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(locks, hasLength(1));
    await svc.dispose();
    expect(locks.single.released, isTrue);
  });

  test('backend failure never breaks state handling', () async {
    final player = await _player();
    final svc = SleepInhibitService(
      controller: player,
      runner: () async => throw Exception('no systemd-inhibit'),
    );
    await svc.start();
    player.playTracks([_track('a'), _track('b')]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(player.state.playing, isTrue);
    player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await svc.dispose();
  });
}
