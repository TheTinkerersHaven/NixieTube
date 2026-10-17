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
    final ok = playScript.isNotEmpty ? playScript.removeAt(0) : playResult;
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
    configDirPath:
        configDir ?? Directory.systemTemp.createTempSync('nt-player-test').path,
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
            url: 'https://x/$id#$resolves',
            bitrate: 128000,
          );
        },
        refreshStream: () async {
          refreshes++;
        },
        configDirPath: Directory.systemTemp
            .createTempSync('nt-player-test')
            .path,
      );
      addTearDown(c.dispose);
      c.playTracks([_track('v1')]);
      await _settle();
      // One forced refresh, then the retry plays the re-resolved URL.
      expect(refreshes, 1);
      expect(engine.playedUrls, ['https://x/v1#1', 'https://x/v1#2']);
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
        configDirPath: Directory.systemTemp
            .createTempSync('nt-player-test')
            .path,
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
      expect(await c2.restoreSession(), isTrue);
      expect(c2.state.current?.videoId, 'v2');
      expect(c2.state.index, 1);
      expect(c2.state.positionMs, 30000);
      expect(c2.state.playing, isFalse);
      expect(engine2.lastUrl, isNull);
    });

    test('restore fails without a session', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      expect(await c.restoreSession(), isFalse);
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

    test('bulk ratings restamp in one pass', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2')]);
      await _settle();
      final changed = c.updateTrackRatings({
        'v2': RatingStatus.like,
        'v9': RatingStatus.like,
      });
      expect(changed, 1);
      expect(c.state.queue[1].rating, RatingStatus.like);
      expect(c.state.current?.rating, isNot(RatingStatus.like));
      expect(c.updateTrackRatings({'v2': RatingStatus.like}), 0);
      expect(c.updateTrackRatings({}), 0);
    });

    test('bulk lengths fill only rows that have none', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1', secs: 0), _track('v2', secs: 0)]);
      await _settle();
      // The current row is also queue[0], so it tallies twice — the same
      // count bulk ratings report.
      final changed = c.updateTrackDurations({'v1': 145, 'v2': 222});
      expect(changed, 3);
      expect(c.state.current?.durationSec, 145);
      expect(c.state.queue[0].durationSec, 145);
      expect(c.state.queue[1].durationSec, 222);
      // Known lengths are never overwritten; junk and empties are no-ops.
      expect(c.updateTrackDurations({'v1': 55}), 0);
      expect(c.state.queue[0].durationSec, 145);
      expect(c.updateTrackDurations({'v1': 0, 'v2': -3, 'v9': 30}), 0);
      expect(c.updateTrackDurations(<String, int>{}), 0);
    });

    test('a resolved stream length lands on its queue row', () async {
      final engine = FakeEngine();
      final c = _controller(
        engine,
        streams: {
          'v1': const ResolvedStream(
            url: 'https://x/v1',
            bitrate: 128000,
            durationSec: 187,
          ),
        },
      );
      c.playTracks([_track('v1', secs: 0), _track('v2', secs: 0)]);
      await _settle();
      // Sources like home shelves ship no length, so the player response
      // is the only place this row's duration can come from.
      expect(c.state.current?.durationSec, 187);
      expect(c.state.queue[0].durationSec, 187);
      // A row that never resolved yet keeps its unknown length.
      expect(c.state.queue[1].durationSec, 0);
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
        const Track(videoId: 'v1', title: 'T', artists: [ArtistRef('Release')]),
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

    test('metadata backfills duration and ORs explicit', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([
        const Track(videoId: 'v1', title: 'T', durationSec: 0),
        const Track(videoId: 'v2', title: 'U', durationSec: 200),
      ]);
      await _settle();
      // Search rows carry no length: the panel duration fills it in.
      c.updateTrackMetadata('v1', durationSec: 178, explicit: true);
      expect(c.state.queue[0].durationSec, 178);
      expect(c.state.queue[0].explicit, isTrue);
      // Catalog durations win over later panel values.
      c.updateTrackMetadata('v2', durationSec: 178);
      expect(c.state.queue[1].durationSec, 200);
      // Explicit never unmarks.
      c.updateTrackMetadata('v1', durationSec: 178);
      expect(c.state.queue[0].explicit, isTrue);
    });

    test('album kind merges, incoming name wins when set', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([
        const Track(videoId: 'v1', title: 'T', album: AlbumRef('Kept')),
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
      expect(c.state.queue.map((t) => t.videoId), ['h0', 'cur', 'n1']);
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
      expect(c.state.queue.map((t) => t.videoId), ['a', 'b']);
      expect(c.state.index, 1);
    });
  });

  group('backend restart recovery', () {
    /// Controller with a failing first engine, a factory minting fresh
    /// engines, and counted resolve/reset hooks.
    (PlayerController, FakeEngine, List<FakeEngine>, Map<String, int>) build({
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
            url: 'https://x/$id#$resolves',
            bitrate: 128000,
          );
        },
        resetStream: () async {
          calls['reset'] = (calls['reset'] ?? 0) + 1;
        },
        createEngine: () {
          final e = FakeEngine()..playResult = !failFresh;
          made.add(e);
          return e;
        },
        configDirPath: Directory.systemTemp
            .createTempSync('nt-restart-test')
            .path,
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

    test(
      'dead engine opens recycle once, then play on the new handle',
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
      },
    );

    test(
      'a recycled backend that still fails surfaces the error once',
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
      },
    );

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

    test('hung engine open times out instead of wedging the track', () async {
      final first = FakeEngine()..playHook = (_) => Completer<bool>().future;
      final c = PlayerController(
        engine: first,
        tube: FakeTube(),
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 128000),
        playTimeout: const Duration(milliseconds: 200),
        configDirPath: Directory.systemTemp.createTempSync('nt-hang-test').path,
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

  group('queue edits', () {
    Future<PlayerController> playingQueue(
      FakeEngine engine,
      List<String> ids,
    ) async {
      final c = _controller(engine);
      c.playTracks(ids.map(_track).toList());
      await _settle();
      return c;
    }

    List<String> queueIds(PlayerController c) =>
        c.state.queue.map((t) => t.videoId).toList();

    test('moveQueue reorders and tracks the current song', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2', 'v3', 'v4']);
      // Drag v1 (index 0, current) down past v2/v3 (adjusted target).
      c.moveQueue(0, 2);
      expect(queueIds(c), ['v2', 'v3', 'v1', 'v4']);
      expect(c.state.index, 2);
      expect(c.state.current?.videoId, 'v1');
      // Drag the last song above the current one: the current index
      // shifts down to keep pointing at v1.
      c.moveQueue(3, 0);
      expect(queueIds(c), ['v4', 'v2', 'v3', 'v1']);
      expect(c.state.index, 3);
      expect(c.state.current?.videoId, 'v1');
    });

    test('moveQueue ignores identity and out-of-range moves', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2']);
      final before = queueIds(c);
      c.moveQueue(0, 0);
      c.moveQueue(5, 0);
      c.moveQueue(0, 9);
      expect(queueIds(c), before);
      expect(c.state.index, 0);
    });

    test('removeAt drops later songs without interrupting', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2', 'v3']);
      expect(c.removeAt(2), isTrue);
      expect(queueIds(c), ['v1', 'v2']);
      expect(c.state.index, 0);
      expect(c.state.current?.videoId, 'v1');
      expect(c.state.playing, isTrue);
      expect(c.removeAt(7), isFalse);
    });

    test('removeAt before the current song shifts the index', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2', 'v3']);
      c.playAt(2);
      await _settle();
      expect(c.removeAt(0), isTrue);
      expect(queueIds(c), ['v2', 'v3']);
      expect(c.state.index, 1);
      expect(c.state.current?.videoId, 'v3');
    });

    test('removeAt on the current song advances to what lands there', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2', 'v3']);
      expect(c.removeAt(0), isTrue);
      await _settle();
      expect(queueIds(c), ['v2', 'v3']);
      expect(c.state.index, 0);
      expect(c.state.current?.videoId, 'v2');
      expect(engine.lastUrl, 'https://x/v2');
    });

    test('removing the last song clears the queue and stops', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1']);
      expect(c.removeAt(0), isTrue);
      expect(c.state.queue, isEmpty);
      expect(c.state.index, -1);
      expect(c.state.current, isNull);
      expect(c.state.playing, isFalse);
    });

    test('fresh-start hold masks the old track ghost position', () async {
      final engine = FakeEngine()..dur = 200000;
      final c = await playingQueue(engine, ['v1', 'v2']);
      c.next();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
      expect(c.state.positionMs, 0);
      // The engine still reports the old track's position on the
      // first polls: held at 0 instead of teleporting the slider.
      engine.pos = 180000;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.state.positionMs, 0);
      // The engine restarts at 0: the hold releases and progress flows.
      engine.pos = 0;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      engine.pos = 2500;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.state.positionMs, 2500);
    });

    test('insertAt restores a removed song for undo', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2', 'v3']);
      c.playAt(1);
      await _settle();
      final removed = c.state.queue[2];
      expect(c.removeAt(2), isTrue);
      expect(queueIds(c), ['v1', 'v2']);
      c.insertAt(2, removed);
      expect(queueIds(c), ['v1', 'v2', 'v3']);
      expect(c.state.index, 1);
      expect(c.state.current?.videoId, 'v2');
    });

    test('clearQueue keeps the current song playing', () async {
      final engine = FakeEngine();
      final c = await playingQueue(engine, ['v1', 'v2']);
      c.playAt(1);
      await _settle();
      c.clearQueue();
      expect(queueIds(c), ['v2']);
      expect(c.state.index, 0);
      expect(c.state.current?.videoId, 'v2');
      expect(c.state.playing, isTrue);
      expect(c.state.stopped, isFalse);
    });
  });
  group('sleep timer', () {
    Future<PlayerController> playing(
      FakeEngine engine,
      List<String> ids,
    ) async {
      final c = _controller(engine);
      c.playTracks(ids.map(_track).toList());
      await _settle();
      expect(c.state.playing, isTrue);
      return c;
    }

    test('duration pauses and disarms, keeping the stream', () async {
      final engine = FakeEngine();
      final c = await playing(engine, ['v1']);
      c.setSleepTimerDuration(const Duration(milliseconds: 40));
      expect(c.state.sleepTimerMode, SleepTimerMode.duration);
      expect(c.state.sleepTimerEndsAtMs, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.state.playing, isFalse);
      expect(c.state.stopped, isFalse);
      expect(engine.playing, isFalse);
      expect(c.state.sleepTimerMode, SleepTimerMode.off);
      expect(c.state.sleepTimerEndsAtMs, isNull);
      // Stream kept loaded: resume continues instantly.
      c.play();
      expect(c.state.playing, isTrue);
    });

    test('cancel disarms the timer', () async {
      final engine = FakeEngine();
      final c = await playing(engine, ['v1']);
      c.setSleepTimerDuration(const Duration(milliseconds: 40));
      c.cancelSleepTimer();
      expect(c.state.sleepTimerMode, SleepTimerMode.off);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.state.playing, isTrue);
    });

    test('end of track pauses instead of advancing', () async {
      final engine = FakeEngine();
      final c = await playing(engine, ['v1', 'v2']);
      c.setSleepTimerEndOfTrack();
      engine.finish();
      await _settle();
      expect(c.state.current?.videoId, 'v1');
      expect(c.state.playing, isFalse);
      expect(c.state.sleepTimerMode, SleepTimerMode.off);
    });

    test('end of queue pauses at the tail without radio', () async {
      final engine = FakeEngine();
      final c = await playing(engine, ['v1', 'v2']);
      c.next();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
      c.setSleepTimerEndOfQueue();
      engine.finish();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
      expect(c.state.playing, isFalse);
      expect(c.state.sleepTimerMode, SleepTimerMode.off);
      // Queue untouched: no loop, no radio continuation.
      expect(c.state.queue.map((t) => t.videoId).toList(), ['v1', 'v2']);
    });

    test('end of queue mid-queue advances normally', () async {
      final engine = FakeEngine();
      final c = await playing(engine, ['v1', 'v2']);
      c.setSleepTimerEndOfQueue();
      engine.finish();
      await _settle();
      expect(c.state.current?.videoId, 'v2');
      expect(c.state.playing, isTrue);
      expect(c.state.sleepTimerMode, SleepTimerMode.endOfQueue);
    });

    test('setters ignore an empty player', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.setSleepTimerDuration(const Duration(minutes: 30));
      c.setSleepTimerEndOfTrack();
      c.setSleepTimerEndOfQueue();
      expect(c.state.sleepTimerMode, SleepTimerMode.off);
      expect(c.state.sleepTimerEndsAtMs, isNull);
    });

    test('stop clears an armed timer', () async {
      final engine = FakeEngine();
      final c = await playing(engine, ['v1']);
      c.setSleepTimerDuration(const Duration(milliseconds: 40));
      c.stop();
      expect(c.state.sleepTimerMode, SleepTimerMode.off);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.state.stopped, isTrue);
    });
  });

  group('missing audio backend', () {
    test('play refuses to start and explains, without the engine', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      // What a failed startup probe does before any play attempt.
      c.backendUnavailable = true;
      c.backendUnavailableReason = 'Install mpv, then restart.';
      c.playTracks([_track('v1')]);
      await _settle();
      expect(c.state.playing, isFalse);
      expect(c.state.loading, isFalse);
      expect(c.state.error, 'Install mpv, then restart.');
      // The engine is never touched: no open, no 20s hang.
      expect(engine.playedUrls, isEmpty);
    });

    test('a later play also fails fast while unavailable', () async {
      final engine = FakeEngine();
      final c = _controller(engine);
      c.playTracks([_track('v1'), _track('v2')]);
      await _settle();
      c.backendUnavailable = true;
      c.backendUnavailableReason = 'No backend.';
      c.next();
      await _settle();
      expect(c.state.playing, isFalse);
      expect(c.state.error, 'No backend.');
    });
  });
}
