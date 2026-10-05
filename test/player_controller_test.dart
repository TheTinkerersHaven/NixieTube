// PlayerController tests with a fake engine and scripted stream/radio
// resolution: queue flow, shuffle/repeat, seeks, session round-trip, and
// metadata merges. No network, no audio.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/core/player/player_state.dart';

class FakeEngine implements PlayerEngine {
  final List<PlayerEngineListener> listeners = [];
  bool playResult = true;

  /// Overrides play when set (e.g. a never-completing future to
  /// simulate a hung backend open).
  Future<bool> Function(String url)? playHook;

  /// Scripted per-call play outcomes (consumed in order); falls back to
  /// [playResult] when empty.
  final List<bool> playScript = [];
  final List<String> playedUrls = [];
  String? lastUrl;
  int pos = 0;
  int dur = 0;
  bool playing = false;
  int volume = 80;
  bool released = false;

  @override
  Future<bool> play(String url) async {
    if (playHook != null) return playHook!(url);
    lastUrl = url;
    playedUrls.add(url);
    final ok =
        playScript.isNotEmpty ? playScript.removeAt(0) : playResult;
    if (ok) playing = true;
    return ok;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> resume() async {
    playing = true;
  }

  @override
  Future<void> stop() async {
    playing = false;
    pos = 0;
  }

  @override
  Future<void> seekTo(int ms) async {
    pos = ms;
  }

  @override
  Future<void> setVolume(int volume) async {
    this.volume = volume;
  }

  @override
  int positionMs() => pos;

  @override
  int durationMs() => dur;

  @override
  bool isPlaying() => playing;

  @override
  Future<void> release() async {
    released = true;
  }

  @override
  void addListener(PlayerEngineListener listener) {
    listeners.add(listener);
  }

  void finish() {
    for (final l in List.of(listeners)) {
      l.onFinished();
    }
  }

  void fail(String message) {
    for (final l in List.of(listeners)) {
      l.onError(message);
    }
  }
}

class FakeTube extends InnerTube {
  List<Track> upcoming = [];

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async {
    return List.of(upcoming);
  }
}

Track _track(String id, {int secs = 200, String artist = 'A'}) => Track(
      videoId: id,
      title: 'Title $id',
      artists: [ArtistRef(artist)],
      durationSec: secs,
    );

PlayerController _controller(
  FakeEngine engine, {
  Map<String, ResolvedStream?>? streams,
  List<Track>? radio,
  String? configDir,
  int Function()? onRefresh,
  int Function(String id)? onResolve,
}) {
  final tube = FakeTube();
  if (radio != null) tube.upcoming = radio;
  final c = PlayerController(
    engine: engine,
    tube: tube,
    resolveStream: (id) async {
      onResolve?.call(id);
      return streams == null
          ? ResolvedStream(url: 'https://x/$id', bitrate: 128000)
          : streams[id];
    },
    refreshStream: onRefresh == null
        ? null
        : () async {
            onRefresh();
          },
    configDirPath: configDir ??
        Directory.systemTemp.createTempSync('nt-player-test').path,
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('starting', () {
    test('playTracks resolves and plays', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2')]);
      expect(c.state.loading, isTrue);
      expect(c.state.current?.videoId, 'v1');
      await _settle();
      expect(engine.lastUrl, 'https://x/v1');
      expect(c.state.playing, isTrue);
      expect(c.state.loading, isFalse);
    });

    test('unresolvable stream surfaces an error', () async {
      final engine = FakeEngine();
      final c = _controller(engine, streams: {});
      c.playTracks([_track('v9')]);
      await _settle();
      expect(c.state.playing, isFalse);
      expect(c.state.error, contains('No playable stream'));
    });

    test('engine refusal surfaces an error', () async {
      final engine = FakeEngine()..playResult = false;
      final c = _controller(engine);
      c.playTracks([_track('v1')]);
      await _settle();
      expect(c.state.error, contains('Playback failed to start'));
    });

    test('dead open URL retries under a fresh resolve context', () async {
      final engine = FakeEngine()..playScript.addAll([false, true]);
      var refreshes = 0;
      var resolves = 0;
      final tube = FakeTube();
      final c = PlayerController(
        engine: engine,
        tube: tube,
        resolveStream: (id) async {
          resolves++;
          return ResolvedStream(
              url: 'https://x/$id#$resolves', bitrate: 128000);
        },
        refreshStream: () async {
          refreshes++;
        },
        configDirPath:
            Directory.systemTemp.createTempSync('nt-player-test').path,
      );
      addTearDown(c.dispose);
      c.playTracks([_track('v1')]);
      await _settle();
      // One forced refresh, then the retry plays the re-resolved URL.
      expect(refreshes, 1);
      expect(engine.playedUrls,
          ['https://x/v1#1', 'https://x/v1#2']);
      expect(c.state.playing, isTrue);
      expect(c.state.error, isNull);
    });

    test('mid-stream failure refreshes and resumes', () async {
      final engine = FakeEngine();
      var refreshes = 0;
      final tube = FakeTube();
      final c = PlayerController(
        engine: engine,
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 128000),
        refreshStream: () async {
          refreshes++;
        },
        configDirPath:
            Directory.systemTemp.createTempSync('nt-player-test').path,
      );
      addTearDown(c.dispose);
      c.playTracks([_track('v1')]);
      await _settle();
      expect(c.state.playing, isTrue);
      engine.fail('stream died');
      await _settle();
      expect(refreshes, 1);
      expect(c.state.playing, isTrue);
      expect(c.state.error, isNull);
    });

    test('empty queue is ignored', () {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([]);
      expect(c.state.current, isNull);
      expect(engine.lastUrl, isNull);
    });
  });

  group('queue flow', () {
    test('next/previous walk linearly', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2'), _track('v3')]);
      await _settle();
      c.next();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
      c.previous();
      await _settle();
      expect(c.state.current?.videoId, 'v1');
    });

    test('previous restarts past 3s', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2')]);
      await _settle();
      c.next();
      await _settle();
      c.seekTo(5000);
      c.previous();
      expect(c.state.current?.videoId, 'v2');
      expect(engine.pos, 0);
    });

    test('repeat all wraps, repeat one replays on finish', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2')]);
      await _settle();
      c.setRepeat(RepeatMode.all);
      c.next();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
      c.next();
      await _settle();
      expect(c.state.current?.videoId, 'v1');
      c.setRepeat(RepeatMode.one);
      engine.finish();
      await _settle();
      expect(c.state.current?.videoId, 'v1');
    });

    test('duplicate finish events advance only once', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2'), _track('v3')]);
      await _settle();
      engine.finish();
      engine.finish();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
    });

    test('shuffle never repeats itself and backtracks', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2'), _track('v3')]);
      await _settle();
      c.setShuffle(true);
      final first = c.state.current?.videoId;
      c.next();
      await _settle();
      expect(c.state.current?.videoId, isNot(first));
      c.previous();
      await _settle();
      expect(c.state.current?.videoId, first);
    });

    test('queue end with autoplay off stops', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1')]);
      await _settle();
      c.toggleAutoplay();
      c.next();
      await _settle();
      expect(c.state.playing, isFalse);
    });

    test('queue end with autoplay continues radio', () async {
      final engine = FakeEngine();
      final c = _controller(engine, radio: [_track('rx')]);
      c.playTracks([_track('v1')]);
      await _settle();
      c.next();
      await _settle();
      expect(c.state.queue.length, 2);
      expect(c.state.current?.videoId, 'rx');
    });

    test('togglePlayPause pauses and resumes', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1')]);
      await _settle();
      c.togglePlayPause();
      expect(c.state.playing, isFalse);
      c.togglePlayPause();
      expect(c.state.playing, isTrue);
    });

    test('stop clears and deletes the session', () async {
      final engine = FakeEngine();
      final dir = Directory.systemTemp.createTempSync('nt-stop').path;
      final c = _controller(engine, configDir: dir);
      c.playTracks([_track('v1')]);
      await _settle();
      expect(File('$dir/playback-session.json').existsSync(), isTrue);
      c.stop();
      expect(c.state.stopped, isTrue);
      expect(File('$dir/playback-session.json').existsSync(), isFalse);
    });

    test('engine error retries once then surfaces', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1')]);
      await _settle();
      engine.playResult = false;
      engine.fail('boom');
      await _settle();
      // First failure retries with a fresh URL (engine still refuses).
      engine.fail('boom');
      await _settle();
      engine.fail('boom');
      await _settle();
      expect(c.state.error, 'boom');
      expect(c.state.playing, isFalse);
    });
  });

  group('seeks and volume', () {
    test('seek clamps to duration and bumps the epoch', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1', secs: 200)]);
      await _settle();
      final epoch = c.state.seekEpoch;
      c.seekTo(999999);
      expect(c.state.positionMs, 200000);
      expect(c.state.seekEpoch, epoch + 1);
      c.seekTo(-5);
      expect(c.state.positionMs, 0);
    });

    test('volume clamps to 0..100', () {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.setVolume(150);
      expect(c.state.volume, 100);
      c.setVolume(-3);
      expect(c.state.volume, 0);
    });
  });

  group('session', () {
    test('save/restore round-trips paused', () async {
      final dir = Directory.systemTemp.createTempSync('nt-sess').path;
      final engine = FakeEngine();
      final c = _controller(engine, configDir: dir);
      c.playTracks([_track('v1', secs: 200), _track('v2')]);
      await _settle();
      c.next();
      await _settle();
      c.seekTo(30000);
      c.togglePlayPause();
      await c.flushSession();
      final engine2 = FakeEngine();
      final c2 = _controller(engine2, configDir: dir);
      expect(c2.restoreSession(), isTrue);
      expect(c2.state.current?.videoId, 'v2');
      expect(c2.state.index, 1);
      expect(c2.state.positionMs, 30000);
      expect(c2.state.playing, isFalse);
      expect(engine2.lastUrl, isNull);
    });

    test('restore fails without a session', () {
      final engine = FakeEngine();
      final c = _controller(engine);
      expect(c.restoreSession(), isFalse);
    });
  });

  group('track updates', () {
    test('rating updates queue and current', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2')]);
      await _settle();
      c.updateTrackRating('v2', RatingStatus.like);
      expect(c.state.queue[1].rating, RatingStatus.like);
      c.updateTrackRating('v1', RatingStatus.dislike);
      expect(c.state.current?.rating, RatingStatus.dislike);
    });

    test('stats never overwrite known counts with -1', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1')]);
      await _settle();
      c.updateTrackStats('v1', 100, 5);
      expect(c.state.current?.likeCount, 100);
      c.updateTrackStats('v1', -1, -1);
      expect(c.state.current?.likeCount, 100);
      expect(c.state.current?.dislikeCount, 5);
    });

    test('metadata replaces generic artists and merges thumbs', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([
        const Track(videoId: 'v1', title: 'T', artists: [ArtistRef('Release')])
      ]);
      await _settle();
      c.updateTrackMetadata(
        'v1',
        artists: const [ArtistRef('Real', browseId: 'UC1')],
        album: const AlbumRef('R', kind: ReleaseKind.single),
        thumbnails: const [Thumbnail('https://x/a.jpg')],
        title: ' T ',
      );
      final t = c.state.current!;
      expect(t.artistNames(), 'Real');
      expect(t.album?.kind, ReleaseKind.single);
      expect(t.thumbnails.map((e) => e.url), ['https://x/a.jpg']);
    });

    test('album kind merges, incoming name wins when set', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([
        const Track(
          videoId: 'v1',
          title: 'T',
          album: AlbumRef('Kept'),
        ),
      ]);
      await _settle();
      c.updateTrackMetadata(
        'v1',
        album: const AlbumRef('Other', kind: ReleaseKind.ep, year: '2024'),
      );
      final t = c.state.current!;
      expect(t.album?.name, 'Other');
      expect(t.album?.kind, ReleaseKind.ep);
      expect(t.album?.year, '2024');
      // Blank incoming name keeps the existing one (kind already known
      // stays untouched).
      c.updateTrackMetadata(
        'v1',
        album: const AlbumRef('', kind: ReleaseKind.album),
      );
      expect(c.state.current?.album?.name, 'Other');
      expect(c.state.current?.album?.kind, ReleaseKind.ep);
    });

    test('cycleRepeat walks OFF ALL ONE', () {
      final engine = FakeEngine();
      final c = _controller(engine);
      expect(c.state.repeat, RepeatMode.off);
      c.cycleRepeat();
      expect(c.state.repeat, RepeatMode.all);
      c.cycleRepeat();
      expect(c.state.repeat, RepeatMode.one);
      c.cycleRepeat();
      expect(c.state.repeat, RepeatMode.off);
    });
  });

  group('replaceUpcoming', () {
    test('swaps the tail, keeps history, index and playback', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('h0'), _track('cur'), _track('stale')]);
      c.playAt(1);
      await _settle();
      final plays = engine.playedUrls.length;
      final queued = c.replaceUpcoming([_track('cur'), _track('n1')]);
      expect(queued, 1);
      expect(
        c.state.queue.map((t) => t.videoId),
        ['h0', 'cur', 'n1'],
      );
      expect(c.state.index, 1);
      expect(c.state.current?.videoId, 'cur');
      expect(engine.playedUrls.length, plays);
    });

    test('nothing new keeps the tail', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('a'), _track('b')]);
      c.playAt(1);
      await _settle();
      // Mix of only already-played tracks: nothing to swap in.
      expect(c.replaceUpcoming([_track('a'), _track('b')]), 0);
      expect(
        c.state.queue.map((t) => t.videoId),
        ['a', 'b'],
      );
      expect(c.state.index, 1);
    });
  });

  group('backend restart recovery', () {
    /// Controller with a failing first engine, a factory minting fresh
    /// engines, and counted resolve/reset hooks.
    (
      PlayerController,
      FakeEngine,
      List<FakeEngine>,
      Map<String, int>,
    ) build({
      required FakeEngine first,
      bool failFresh = false,
      Future<ResolvedStream?> Function(String id)? resolve,
    }) {
      final made = <FakeEngine>[];
      final calls = <String, int>{};
      var resolves = 0;
      final c = PlayerController(
        engine: first,
        tube: FakeTube(),
        resolveStream: (id) async {
          calls['resolve'] = (calls['resolve'] ?? 0) + 1;
          resolves++;
          if (resolve != null) return resolve(id);
          return ResolvedStream(
              url: 'https://x/$id#$resolves', bitrate: 128000);
        },
        resetStream: () async {
          calls['reset'] = (calls['reset'] ?? 0) + 1;
        },
        createEngine: () {
          final e = FakeEngine()..playResult = !failFresh;
          made.add(e);
          return e;
        },
        configDirPath:
            Directory.systemTemp.createTempSync('nt-restart-test').path,
      );
      addTearDown(c.dispose);
      return (c, first, made, calls);
    }

    test('dead resolve family recovers after reset + fresh engine', () async {
      final first = FakeEngine();
      var n = 0;
      final (c, _, made, calls) = build(
        first: first,
        resolve: (id) async {
          n++;
          // First family is dead (edge rejects it); post-reset mint works.
          if (n == 1) return null;
          return ResolvedStream(url: 'https://x/$id#fresh', bitrate: 128000);
        },
      );
      c.playTracks([_track('v1')]);
      await _settle();
      await _settle();
      expect(c.state.playing, isTrue);
      expect(c.state.error, isNull);
      expect(made, hasLength(1));
      expect(first.released, isTrue);
      expect(calls['reset'], 1);
      expect(first.playedUrls, isEmpty);
      expect(made.single.playedUrls, ['https://x/v1#fresh']);
    });

    test('dead engine opens recycle once, then play on the new handle',
        () async {
      final first = FakeEngine()..playResult = false;
      final (c, _, made, _) = build(first: first);
      c.playTracks([_track('v1')]);
      await _settle();
      await _settle();
      expect(c.state.playing, isTrue);
      expect(made, hasLength(1));
      // Initial open + same-handle retry both failed; the new handle
      // played exactly once.
      expect(first.playedUrls, hasLength(2));
      expect(made.single.playedUrls, hasLength(1));
    });

    test('a recycled backend that still fails surfaces the error once',
        () async {
      final first = FakeEngine()..playResult = false;
      final (c, _, made, _) = build(first: first, failFresh: true);
      c.playTracks([_track('v1')]);
      await _settle();
      await _settle();
      expect(c.state.playing, isFalse);
      expect(c.state.error, contains('Playback failed to start'));
      // One restart per episode: no recycle loop on a hopeless track.
      expect(made, hasLength(1));
    });

    test('mid-stream failure resumes on the new handle', () async {
      final first = FakeEngine();
      final (c, _, made, _) = build(first: first);
      c.playTracks([_track('v1')]);
      await _settle();
      c.seekTo(42000);
      await _settle();
      first.playScript.add(false);
      first.fail('boom');
      await _settle();
      await _settle();
      expect(c.state.playing, isTrue);
      expect(c.state.error, isNull);
      expect(made, hasLength(1));
      expect(first.released, isTrue);
      // Resumed where the old handle died, not from zero.
      expect(made.single.pos, 42000);
    });

    test('hung engine open times out instead of wedging the track',
        () async {
      final first = FakeEngine()
        ..playHook = (_) => Completer<bool>().future;
      final c = PlayerController(
        engine: first,
        tube: FakeTube(),
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 128000),
        playTimeout: const Duration(milliseconds: 200),
        configDirPath:
            Directory.systemTemp.createTempSync('nt-hang-test').path,
      );
      addTearDown(c.dispose);
      c.playTracks([_track('v1')]);
      // Two hung opens (initial + same-handle retry) at 200ms each,
      // then the error surfaces instead of spinning forever.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(c.state.playing, isFalse);
      expect(c.state.loading, isFalse);
      expect(c.state.error, contains('Playback failed to start'));
    });
  });
}
