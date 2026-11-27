// The rolling two-entry window: the track that comes next is queued inside
// the same player instead of a second engine, so the backend can reach it
// without closing the audio device. No audio, no network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';

import 'fakes.dart';

Track _track(String id) => Track(
  videoId: id,
  title: 'Song $id',
  artists: const [ArtistRef('Artist')],
  album: const AlbumRef('Album'),
  durationSec: 200,
);

/// Records what the controller asked the player to do with its playlist.
class _Engine implements PlayerEngine {
  final List<PlayerEngineListener> listeners = [];
  final List<String> played = [];
  final List<String?> windows = [];

  /// URL of the entry last queued behind the playing one.
  String? queued;
  int promotes = 0;
  int resumes = 0;
  bool playing = false;


  @override
  void addListener(PlayerEngineListener listener) => listeners.add(listener);

  @override
  Future<String?> play(String url, {String? nextUrl}) async {
    played.add(url);
    queued = nextUrl;
    playing = true;
    return null;
  }

  @override
  Future<void> setNext(String? url) async {
    windows.add(url);
    queued = url;
  }

  @override
  Future<void> promoteNext() async {
    promotes++;
    queued = null;
  }

  @override
  Future<void> resume() async {
    resumes++;
    playing = true;
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> stop() async => playing = false;

  @override
  Future<void> seekTo(int ms) async {}

  @override
  Future<void> setVolume(int volume) async {}

  @override
  int positionMs() => 0;

  @override
  int durationMs() => 200000;

  @override
  bool isPlaying() => playing;

  @override
  Future<void> release() async => playing = false;

  /// The backend moving into the queued entry on its own, at a boundary.
  void advance() {
    for (final l in List.of(listeners)) {
      l.onAdvanced();
    }
  }
}

/// Waits until [check] holds, up to about a second.
Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 50 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late _Engine engine;
  late PlayerController controller;

  void build() {
    final dir = Directory.systemTemp.createTempSync('nt-window');
    addTearDown(() => dir.deleteSync(recursive: true));
    engine = _Engine();
    controller = PlayerController(
      engine: engine,
      tube: FakeTube(),
      resolveStream: (id) async =>
          ResolvedStream(url: 'https://x/$id', bitrate: 128000),
      configDirPath: dir.path,
    );
    addTearDown(controller.dispose);
  }

  test('the next queue row is queued inside the same player', () async {
    build();
    controller.playTracks([_track('v1'), _track('v2'), _track('v3')]);

    await _until(() => engine.queued == 'https://x/v2');

    // One player, one open: the second track never gets a stream of its
    // own, it rides along behind the first.
    expect(engine.played, ['https://x/v1']);
    expect(engine.queued, 'https://x/v2');
  });

  test('skipping opens the row it names, not the queued entry', () async {
    build();
    controller.playTracks([_track('v1'), _track('v2'), _track('v3')]);
    await _until(() => engine.queued == 'https://x/v2');

    controller.next();

    // A skip replaces the window instead of jumping into it: the queued
    // entry can belong to a playlist an open has since replaced, and a
    // seek into that one lands on a track the screen does not name.
    await _until(() => controller.state.current?.videoId == 'v2');
    expect(controller.state.current?.videoId, 'v2');
    expect(controller.state.index, 1);
    expect(controller.state.positionMs, 0);
    expect(engine.played, ['https://x/v1', 'https://x/v2']);
    // The window refills with the track after the one opened.
    await _until(() => engine.queued == 'https://x/v3');
    expect(engine.queued, 'https://x/v3');
  });

  test('a natural handover adopts the queued row without reopening', () async {
    build();
    controller.playTracks([_track('v1'), _track('v2'), _track('v3')]);
    await _until(() => engine.queued == 'https://x/v2');

    engine.advance();

    await _until(() => controller.state.current?.videoId == 'v2');
    final s = controller.state;
    expect(s.current?.title, 'Song v2');
    expect(s.index, 1);
    expect(s.playing, isTrue);
    expect(s.loading, isFalse);
    expect(s.positionMs, 0);
    expect(engine.played, ['https://x/v1']);
    // The finished entry is dropped and the following track queued.
    expect(engine.promotes, 1);
    await _until(() => engine.queued == 'https://x/v3');
    expect(engine.queued, 'https://x/v3');
  });

  test('nothing is queued at the end of the queue', () async {
    build();
    controller.playTracks([_track('v1')]);

    await _until(() => engine.played.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(engine.queued, isNull);
  });

  test('shuffle queues nothing, because the handoff is undecided', () async {
    build();
    controller.playTracks([_track('v1'), _track('v2'), _track('v3')]);
    await _until(() => engine.queued == 'https://x/v2');

    controller.toggleShuffle();

    await _until(() => engine.queued == null);
    expect(engine.queued, isNull);
  });

  test('a handover report with nothing queued changes nothing', () async {
    build();
    controller.playTracks([_track('v1'), _track('v2')]);
    await _until(() => engine.queued == 'https://x/v2');

    // Nothing follows the current track any more, so the window is
    // dropped. A move reported after that names no track this queue can
    // adopt: acting on it would skip a row, so it is ignored.
    controller.clearQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    engine.advance();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(controller.state.current?.videoId, 'v1');
    expect(controller.state.index, 0);
    expect(engine.played, ['https://x/v1']);
  });
}
