// Tests for single/radio playback and home-loader hardening.
//
// - Tapping a single (search result, one-track release) plays it at once
//   and lands its radio mix behind it, instead of a one-song queue or a
//   queue of unrelated search results.
// - Starting a song's radio while it plays appends the mix without
//   restarting the song (the engine must not be asked to play again).
// - Concurrent/slow home loads can't stick the spinner: stale loads are
//   ignored and failures surface as an error with Retry.
//
// Lyrics enrichment fires real LRCLIB requests in the background, so
// playback tests drain before teardown; the drain only covers local
// teardown ordering, assertions never depend on it.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

class _FakeEngine implements PlayerEngine {
  final List<PlayerEngineListener> listeners = [];
  final List<String> playedUrls = [];
  int pos = 0;

  @override
  Future<bool> play(String url) async {
    playedUrls.add(url);
    return true;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    pos = 0;
  }

  @override
  Future<void> seekTo(int ms) async {
    pos = ms;
  }

  @override
  Future<void> setVolume(int volume) async {}

  @override
  int positionMs() => pos;

  @override
  int durationMs() => 0;

  @override
  bool isPlaying() => playedUrls.isNotEmpty;

  @override
  Future<void> release() async {}

  @override
  void addListener(PlayerEngineListener listener) {
    listeners.add(listener);
  }
}

/// InnerTube double with scripted radio mixes and metadata stubs, so no
/// test touches the network except the app's own fire-and-forget lyrics
/// fetch (drained before teardown).
class _FakeRadioTube extends InnerTube {
  Map<String, List<Track>> mixes = {};

  /// Held mixes: upNext waits for the gate before answering.
  Map<String, Completer<List<Track>>> mixGates = {};
  Future<List<Shelf>> Function()? homeHook;
  int homeCalls = 0;

  /// Scripted Explore shelves; [exploreHook] overrides (and can throw).
  List<Shelf> exploreShelves = const [];
  Future<List<Shelf>> Function()? exploreHook;

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async {
    final gate = mixGates[videoId];
    if (gate != null) return gate.future;
    return List.of(mixes[videoId] ?? []);
  }

  @override
  Future<Track> enrichTrack(Track track) async => track;

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;

  @override
  Future<({List<String> moods, List<Shelf> shelves})> home() async {
    homeCalls++;
    final hook = homeHook;
    if (hook != null) {
      return (shelves: await hook(), moods: <String>[]);
    }
    return (shelves: <Shelf>[], moods: <String>[]);
  }

  @override
  Future<List<Shelf>> explore() async {
    final hook = exploreHook;
    if (hook != null) return hook();
    return exploreShelves;
  }

  /// Scripted Charts read (country label + worldwide chart); [chartsHook]
  /// overrides (and can throw).
  ({String? country, List<Track> tracks}) chartsFeed = (
    country: null,
    tracks: const <Track>[],
  );
  Future<({String? country, List<Track> tracks})> Function()? chartsHook;

  @override
  Future<({String? country, List<Track> tracks})> charts() async {
    final hook = chartsHook;
    if (hook != null) return hook();
    return chartsFeed;
  }
}

Track _track(String id) => Track(
  videoId: id,
  title: 'Title $id',
  artists: [ArtistRef('Artist $id')],
  durationSec: 200,
  radioPlaylistId: 'RDAMVM$id',
);

({AppState state, _FakeEngine engine, _FakeRadioTube tube}) _app({
  bool playback = false,
}) {
  final dir = Directory.systemTemp.createTempSync('nt-radio-test');
  final tube = _FakeRadioTube();
  final engine = _FakeEngine();
  final player = PlayerController(
    engine: engine,
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 128000),
    configDirPath: dir.path,
  );
  final state = AppState(
    tube: tube,
    player: player,
    art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
    oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(() async {
    if (playback) {
      // Let the fire-and-forget lyrics fetch land while the state is
      // still alive; a post-dispose notify would throw into the zone.
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    player.dispose();
    state.dispose();
    tube.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return (state: state, engine: engine, tube: tube);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('appendRadio', () {
    test('appends unseen tracks without restarting playback', () async {
      final env = _app(playback: true);
      final player = env.state.player;
      player.playTracks([_track('a')]);
      await _settle();
      expect(env.engine.playedUrls, hasLength(1));

      player.appendRadio([_track('a'), _track('b'), _track('c')]);
      expect(player.state.queue.map((t) => t.videoId), ['a', 'b', 'c']);
      // The engine was not asked to play again: no restart.
      expect(env.engine.playedUrls, hasLength(1));
      expect(player.state.current?.videoId, 'a');
      expect(player.state.loading, isFalse);
    });

    test('empty or fully-known mixes leave the queue alone', () async {
      final env = _app(playback: true);
      final player = env.state.player;
      player.playTracks([_track('a')]);
      await _settle();

      player.appendRadio([]);
      player.appendRadio([_track('a')]);
      expect(player.state.queue.map((t) => t.videoId), ['a']);
      expect(env.engine.playedUrls, hasLength(1));
    });
  });

  group('playSingle', () {
    test('plays at once, then lands the radio mix without restart', () async {
      final env = _app(playback: true);
      env.tube.mixes['a'] = [_track('a'), _track('b'), _track('c')];

      await env.state.playSingle(_track('a'));
      expect(env.engine.playedUrls, ['https://x/a']);
      expect(env.state.player.state.queue.map((t) => t.videoId), [
        'a',
        'b',
        'c',
      ]);
      // One engine play for the single: the mix arrived via append.
      expect(env.engine.playedUrls, hasLength(1));
    });

    test('drops a stale mix when the user moved on meanwhile', () async {
      final env = _app(playback: true);
      final gate = Completer<List<Track>>();
      env.tube.mixGates['slow'] = gate;
      final pending = env.state.playSingle(_track('slow'));
      // Switch tracks before the mix lands.
      env.state.player.playTracks([_track('z')]);
      gate.complete([_track('x')]);
      await pending.timeout(const Duration(seconds: 5));
      await _settle();
      expect(env.state.player.state.queue.map((t) => t.videoId), ['z']);
    });

    test('playSongs with one track starts its radio', () async {
      final env = _app(playback: true);
      env.tube.mixes['a'] = [_track('b')];

      env.state.playSongs([_track('a')], 0);
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(env.state.player.state.queue.map((t) => t.videoId), ['a', 'b']);
      expect(env.engine.playedUrls, hasLength(1));
    });

    test('playSongs with several tracks keeps the given queue', () async {
      final env = _app(playback: true);
      env.tube.mixes['a'] = [_track('zzz')];

      env.state.playSongs([_track('a'), _track('b')], 1);
      await _settle();
      expect(env.state.player.state.queue.map((t) => t.videoId), ['a', 'b']);
      expect(env.state.player.state.current?.videoId, 'b');
    });
  });

  group('startRadio', () {
    test('same-track radio takes over Up next without restarting', () async {
      final env = _app(playback: true);
      final player = env.state.player;
      player.playTracks([_track('a')]);
      await _settle();
      expect(env.engine.playedUrls, hasLength(1));
      env.tube.mixes['a'] = [_track('a'), _track('b')];

      await env.state.startRadio(player.state.current!);
      expect(player.state.queue.map((t) => t.videoId), ['a', 'b']);
      // Still exactly one engine play: the song never restarted.
      expect(env.engine.playedUrls, hasLength(1));
      expect(player.state.current?.videoId, 'a');
      expect(player.state.loading, isFalse);
    });

    test('startRadio reports how many station tracks were queued', () async {
      final env = _app(playback: true);
      final player = env.state.player;
      player.playTracks([_track('a')]);
      await _settle();
      // Same track: one fresh mix track behind the seed.
      env.tube.mixes['a'] = [_track('a'), _track('b'), _track('c')];
      final first = await env.state.startRadio(player.state.current!);
      expect(first.loaded, isTrue);
      expect(first.queued, 2);
      // Repeating re-applies the identical station (freshness is
      // measured against the played head, not the replaced tail).
      final repeat = await env.state.startRadio(player.state.current!);
      expect(repeat, (queued: 2, loaded: true));
      expect(player.state.queue.map((t) => t.videoId), ['a', 'b', 'c']);
      // Fresh seed: seed filtered out of its own mix.
      env.tube.mixes['b'] = [_track('b'), _track('c')];
      final fresh = await env.state.startRadio(_track('b'));
      expect(fresh, (queued: 1, loaded: true));
    });

    test(
      'same-track radio replaces Up next, keeps history and position',
      () async {
        final env = _app(playback: true);
        final player = env.state.player;
        player.playTracks([
          _track('prev'),
          _track('a'),
          _track('old1'),
          _track('old2'),
        ]);
        player.playAt(1);
        await _settle();
        await _settle();
        expect(player.state.current?.videoId, 'a');
        final playsBefore = env.engine.playedUrls.length;
        env.tube.mixes['a'] = [_track('a'), _track('m1'), _track('m2')];

        final res = await env.state.startRadio(player.state.current!);
        expect(res, (queued: 2, loaded: true));
        // Played history stays; the stale tail is gone.
        expect(player.state.queue.map((t) => t.videoId), [
          'prev',
          'a',
          'm1',
          'm2',
        ]);
        expect(player.state.index, 1);
        expect(player.state.current?.videoId, 'a');
        // No engine replay: the song never restarted.
        expect(env.engine.playedUrls.length, playsBefore);
        expect(player.state.loading, isFalse);
      },
    );

    test('different seed starts a fresh station', () async {
      final env = _app(playback: true);
      final player = env.state.player;
      player.playTracks([_track('a')]);
      await _settle();
      env.tube.mixes['b'] = [_track('b'), _track('c')];

      await env.state.startRadio(_track('b'));
      await _settle();
      expect(player.state.queue.map((t) => t.videoId), ['b', 'c']);
      expect(player.state.current?.videoId, 'b');
      expect(env.engine.playedUrls.last, 'https://x/b');
    });
  });

  group('loadHome', () {
    test('stale loads are ignored, spinner always settles', () async {
      final env = _app();
      final gate = Completer<List<Shelf>>();
      env.tube.homeHook = () {
        // First load hangs; the retry answers at once.
        if (env.tube.homeCalls == 1) return gate.future;
        return Future.value([
          Shelf('Fresh', [SongItem(_track('f'))]),
        ]);
      };

      final first = env.state.loadHome();
      // Let the first load publish its spinner before retrying.
      await _settle();
      expect(env.state.home.loading, isTrue);
      final second = env.state.loadHome();
      await second;
      // The late first response must not clobber the fresh shelves.
      gate.complete([]);
      await first;
      expect(env.state.home.loading, isFalse);
      expect(env.state.home.error, isNull);
      expect(env.state.home.shelves.map((s) => s.title), ['Fresh']);
    });

    test('failures surface an error instead of sticking', () async {
      final env = _app();
      env.tube.homeHook = () => throw Exception('boom');

      await env.state.loadHome();
      expect(env.state.home.loading, isFalse);
      expect(env.state.home.error, contains('boom'));
      expect(env.state.home.shelves, isEmpty);
    });

    test('explore shelves load alongside the home feed', () async {
      final env = _app();
      env.tube.homeHook = () async => [
        Shelf('For you', [SongItem(_track('h'))]),
      ];
      env.tube.exploreShelves = [
        Shelf('New albums & singles', [SongItem(_track('n'))]),
        Shelf('Trending', [SongItem(_track('t'))]),
      ];

      await env.state.loadHome();
      expect(env.state.home.error, isNull);
      expect(env.state.home.shelves.map((s) => s.title), ['For you']);
      expect(env.state.home.explore.map((s) => s.title), [
        'New albums & singles',
        'Trending',
      ]);
    });

    test('a failing explore feed never sinks the home feed', () async {
      final env = _app();
      env.tube.homeHook = () async => [Shelf('For you', const [])];
      env.tube.exploreHook = () => throw Exception('explore down');

      await env.state.loadHome();
      expect(env.state.home.error, isNull);
      expect(env.state.home.shelves.map((s) => s.title), ['For you']);
      expect(env.state.home.explore, isEmpty);
    });

    test('charts country and worldwide chart land in the home state', () async {
      final env = _app();
      env.tube.homeHook = () async => [Shelf('For you', const [])];
      env.tube.chartsFeed = (
        country: 'Italy',
        tracks: [_track('g1'), _track('g2')],
      );

      await env.state.loadHome();
      expect(env.state.home.country, 'Italy');
      expect(env.state.home.globalTrending.map((t) => t.videoId), ['g1', 'g2']);
    });

    test('the worldwide chart row carries a preview, not the chart', () async {
      final env = _app();
      env.tube.homeHook = () async => [Shelf('For you', const [])];
      env.tube.chartsFeed = (
        country: null,
        tracks: [for (var i = 0; i < 100; i++) _track('g$i')],
      );

      await env.state.loadHome();
      expect(env.state.home.globalTrending, hasLength(25));
    });

    test('a failing charts feed never sinks the home feed', () async {
      final env = _app();
      env.tube.homeHook = () async => [Shelf('For you', const [])];
      env.tube.chartsHook = () => throw Exception('charts down');

      await env.state.loadHome();
      expect(env.state.home.error, isNull);
      expect(env.state.home.shelves.map((s) => s.title), ['For you']);
      expect(env.state.home.country, isNull);
      expect(env.state.home.globalTrending, isEmpty);
    });
  });
}
