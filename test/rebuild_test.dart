// Regression test for the rebuild split: position-only player ticks must
// bump progressTick without notifying (and rebuilding) screen watchers,
// while real changes (pause, track switch) still rebuild.

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:nixietube/ui/widgets/artwork_image.dart';
import 'package:nixietube/ui/widgets/player_bar.dart';

class _FakeEngine implements PlayerEngine {
  bool playing = false;

  @override
  Future<bool> play(String url) async {
    playing = true;
    return true;
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
  }

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
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

const _t1 = Track(videoId: 'v1', title: 'One', durationSec: 200);

void main() {
  testWidgets('position ticks skip screen rebuilds', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-rebuild-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: _FakeEngine(),
      tube: tube,
      resolveStream: (id) async =>
          ResolvedStream(url: 'https://x/$id', bitrate: 1),
      configDirPath: dir.path,
    );
    addTearDown(player.dispose);
    final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
    addTearDown(art.close);
    final oauth = GoogleOAuth(storePath: '${dir.path}/oauth.properties');
    addTearDown(oauth.close);
    final state = AppState(
      tube: tube,
      player: player,
      art: art,
      oauth: oauth,
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      openUrl: (_) async {},
    );
    addTearDown(state.dispose);

    var builds = 0;
    var ticks = 0;
    state.progressTick.addListener(() => ticks++);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: Builder(builder: (context) {
          context.watch<AppState>();
          builds++;
          return const SizedBox.shrink();
        }),
      ),
    );
    expect(builds, 1);
    state.playSongs([_t1], 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final afterPlay = builds;
    expect(afterPlay, greaterThan(1));

    // Five ticker windows of pure position updates.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(ticks, greaterThanOrEqualTo(5));
    expect(builds, afterPlay,
        reason: 'position ticks must not rebuild watchers');

    // A real change (pause) rebuilds exactly.
    state.player.togglePlayPause();
    await tester.pump();
    expect(builds, afterPlay + 1);
    player.dispose();
    await tester.pump();
  });

  group('selective rebuilds', () {
    ({AppState state, PlayerController player, _QuietTube tube})
    buildApp({ArtworkStore? art}) {
      final dir = Directory.systemTemp.createTempSync('nt-select-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tube = _QuietTube();
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 1),
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final store = art ?? ArtworkStore(cacheDirPath: '${dir.path}/art');
      addTearDown(store.close);
      final state = AppState(
        tube: tube,
        player: player,
        art: store,
        oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      return (state: state, player: player, tube: tube);
    }

    testWidgets('player bar surface tap opens Now Playing', (tester) async {
      final env = buildApp();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: env.state,
          child: const MaterialApp(
            home: Scaffold(body: PlayerBar()),
          ),
        ),
      );
      env.player.playTracks([
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Uno')],
          durationSec: 200,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(env.state.nowOpen, isFalse);
      // The surface tap (title text, away from the buttons).
      await tester.tap(find.text('One'));
      await tester.pump();
      expect(env.state.nowOpen, isTrue);
      // Let the transition hold timer fire so no timer pends.
      await tester.pump(const Duration(milliseconds: 500));
      env.player.dispose();
      await tester.pump();
    });

    testWidgets('non-tappable bar ignores surface taps, keeps controls',
        (tester) async {
      final env = buildApp();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: env.state,
          child: const MaterialApp(
            home: Scaffold(body: PlayerBar(tappable: false)),
          ),
        ),
      );
      env.player.playTracks([
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Uno')],
          durationSec: 200,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('One'));
      await tester.pump();
      expect(env.state.nowOpen, isFalse);
      // Inner transport controls stay live.
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      expect(env.player.state.playing, isFalse);
      env.player.dispose();
      await tester.pump();
    });

    testWidgets('player bar follows track, merges and transport state',
        (tester) async {
      final env = buildApp();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: env.state,
          child: const MaterialApp(
            home: Scaffold(body: PlayerBar()),
          ),
        ),
      );
      expect(
        find.text('Search for music to start playing'),
        findsOneWidget,
      );

      // Hold the background metadata merge back so the assertions
      // below run against a deterministic queue state.
      env.tube.enrichGate = Completer<Track>();
      env.player.playTracks([
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Uno')],
          durationSec: 200,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Uno'), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      // Release the enrichment with a fixed credit: the merge replaces
      // the track object, and the bar's track select must fire for it.
      env.tube.enrichGate!.complete(
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Boom Kitty', browseId: 'UCBK')],
          durationSec: 200,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Boom Kitty'), findsOneWidget);
      expect(find.text('Uno'), findsNothing);

      env.player.togglePlayPause();
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      env.player.dispose();
      await tester.pump();
    });

    testWidgets('artwork resolves once per url across parent rebuilds',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('nt-art-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Minimal valid PNG so Image.file takes the loaded path.
      const png = [
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0,
        0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73,
        68, 65, 84, 120, 156, 99, 96, 24, 5, 163, 96, 20, 140, 2, 0, 0,
        118, 0, 1, 147, 243, 233, 240, 0, 0, 0, 0, 73, 69, 78, 68, 174,
        66, 96, 130,
      ];
      final file = File('${dir.path}/a.png')
        ..writeAsBytesSync(png);
      final store = _CountingStore(
        cacheDirPath: '${dir.path}/art',
        result: file,
      );
      final env = buildApp(art: store);
      // Swap the real store for the counting one.
      String? url = 'https://x/a.png';
      late StateSetter setOuter;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: env.state,
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return Scaffold(body: ArtworkImage(url, size: 48));
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.calls, 1);
      expect(find.byType(Image), findsOneWidget);
      // No per-frame builder in the tree: parent rebuilds below must
      // not re-run a future builder for the resolved file.
      expect(find.byType(FutureBuilder), findsNothing);

      // Same-url parent rebuilds must not refetch.
      setOuter(() {});
      await tester.pump();
      setOuter(() {});
      await tester.pump();
      expect(store.calls, 1);

      // A new url refetches exactly once.
      url = 'https://x/b.png';
      setOuter(() {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.calls, 2);
      env.player.dispose();
      await tester.pump();
    });

    testWidgets('missing artwork shows a placeholder without refetching',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('nt-art-null');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _CountingStore(
        cacheDirPath: '${dir.path}/art',
        result: null,
      );
      final env = buildApp(art: store);
      String? url = 'https://x/missing.png';
      late StateSetter setOuter;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: env.state,
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return Scaffold(body: ArtworkImage(url, size: 48));
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.calls, 1);
      expect(find.byIcon(Icons.album_rounded), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      setOuter(() {});
      await tester.pump();
      expect(store.calls, 1);
      // Unmount to cancel the delayed retry before the test ends.
      url = null;
      setOuter(() {});
      await tester.pumpWidget(const SizedBox.shrink());
      env.player.dispose();
      await tester.pump();
    });
  });

  group('overlay staging', () {
    testWidgets('tabs wait for the slide while transport shows at once',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('nt-stage-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tube = _QuietTube();
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 1),
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final state = AppState(
        tube: tube,
        player: player,
        art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
        oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(body: NowPlayingScreen()),
          ),
        ),
      );
      player.playTracks([
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Uno')],
          durationSec: 200,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Transport is up immediately, tabs stay out pre-transition.
      expect(find.text('One'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);

      state.openNow();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TabBar), findsNothing);

      // Past the 250ms slide + hold: tab content stages in.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TabBar), findsOneWidget);
      player.dispose();
      await tester.pump();
    });
  });

  group('volume isolation', () {
    test('volume-only detection', () {
      const track = Track(videoId: 'v', title: 'T');
      final base = PlayerState(
        current: track,
        playing: true,
        volume: 80,
        positionMs: 1000,
      );
      final quieter = base.copyWith(volume: 60);
      expect(isVolumeOnlyUpdate(base, quieter), isTrue);
      expect(isProgressOnlyUpdate(base, quieter), isFalse);
      // Position movement is progress, not volume.
      final moved = base.copyWith(positionMs: 2000);
      expect(isVolumeOnlyUpdate(base, moved), isFalse);
      expect(isProgressOnlyUpdate(base, moved), isTrue);
      // Combined changes still take the full notify path.
      final both = quieter.copyWith(playing: false);
      expect(isVolumeOnlyUpdate(base, both), isFalse);
      expect(isProgressOnlyUpdate(base, both), isFalse);
    });

    testWidgets('volume drags tick instead of rebuilding watchers',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('nt-volume-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tube = _QuietTube();
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 1),
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final state = AppState(
        tube: tube,
        player: player,
        art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
        oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      var builds = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Builder(builder: (context) {
                    context.watch<AppState>();
                    builds++;
                    return const SizedBox.shrink();
                  }),
                  const Expanded(child: NowPlayingScreen()),
                ],
              ),
            ),
          ),
        ),
      );
      player.playTracks([
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Uno')],
          durationSec: 200,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final afterPlay = builds;
      expect(afterPlay, greaterThan(1));

      player.setVolume(50);
      await tester.pump();
      expect(state.volumeTick.value, greaterThan(0));
      expect(builds, afterPlay,
          reason: 'volume drags must not rebuild watchers');
      // The slider itself follows via volumeTick: one of the two
      // sliders (seek + volume) now reads 50.
      final values = tester
          .widgetList<Slider>(find.byType(Slider))
          .map((s) => s.value)
          .toList();
      expect(values, contains(50.0));
      player.dispose();
      await tester.pump();
    });
  });

  group('fullscreen lyrics', () {
    testWidgets('expand shows bar + lyrics, collapse and close restore',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('nt-full-lyrics');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tube = _QuietTube();
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 1),
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final state = AppState(
        tube: tube,
        player: player,
        art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
        oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(body: NowPlayingScreen()),
          ),
        ),
      );
      player.playTracks([
        const Track(
          videoId: 'v1',
          title: 'One',
          artists: [ArtistRef('Uno')],
          durationSec: 200,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Standard two-column view: no mini bar, no collapse control.
      expect(find.text('One'), findsWidgets);
      expect(find.byType(PlayerBar), findsNothing);
      expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);

      // Tabs stage in past the transition hold; the expand control
      // lives in the Lyrics tab header.
      state.openNow();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TabBar), findsOneWidget);
      await tester.tap(find.text('Lyrics'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pump();
      expect(state.lyricsFull, isTrue);
      expect(find.byType(PlayerBar), findsOneWidget);
      expect(
        find.byIcon(Icons.fullscreen_exit_rounded),
        findsOneWidget,
      );
      expect(find.text('No lyrics found'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.fullscreen_exit_rounded));
      await tester.pump();
      expect(state.lyricsFull, isFalse);
      expect(find.byType(PlayerBar), findsNothing);

      // Closing from fullscreen always lands back on standard view.
      state.expandLyrics();
      await tester.pump();
      expect(find.byType(PlayerBar), findsOneWidget);
      state.closeNow();
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.lyricsFull, isFalse);
      expect(state.nowOpen, isFalse);
      expect(find.byType(PlayerBar), findsNothing);
      player.dispose();
      await tester.pump();
    });
  });
}

/// InnerTube double with inert metadata so widget tests stay offline.
class _QuietTube extends InnerTube {
  /// Held enrichment: tests release the background metadata merge
  /// deterministically instead of racing it.
  Completer<Track>? enrichGate;

  @override
  Future<Track> enrichTrack(Track track) async {
    final gate = enrichGate;
    if (gate != null) return gate.future;
    return track;
  }

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}

/// ArtworkStore double counting file resolutions.
class _CountingStore extends ArtworkStore {
  _CountingStore({required super.cacheDirPath, this.result});

  File? result;
  int calls = 0;

  @override
  Future<File?> file(String url) {
    calls++;
    return Future.value(result);
  }
}
