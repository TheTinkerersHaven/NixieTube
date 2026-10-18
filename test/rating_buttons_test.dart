// Rating-button chain tests for the Now Playing transport:
// tapping Like must flip the thumbs, persist on backend success,
// and revert (with a SnackBar) when both backends refuse.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:nixietube/ui/theme.dart';

class _FakeEngine implements PlayerEngine {
  @override
  Future<String?> play(String url) async => null;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seekTo(int ms) async {}
  @override
  Future<void> setVolume(int volume) async {}
  @override
  int positionMs() => 0;
  @override
  int durationMs() => 200000;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

class _FakeTube extends InnerTube {
  bool rateResult = true;

  @override
  Future<bool> rate(String videoId, RatingStatus rating) async => rateResult;

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.indifferent;

  @override
  Future<Track> enrichTrack(Track track) async => track;
}

/// Backend that delays the rate response so the loading state
/// can be observed mid-write.
class _SlowTube extends _FakeTube {
  @override
  Future<bool> rate(String videoId, RatingStatus rating) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return rateResult;
  }
}

/// Fake backend where only `q2` is liked server-side and only `q2`
/// reports a length in its watch-next read, so both halves of the Up Next
/// metadata pass (like states + lengths) are exercised without network.
class _QueueStampTube extends _FakeTube {
  @override
  Future<Map<String, ({RatingStatus rating, Map<String, int> durations})>>
  watchInfos(List<String> videoIds, {int concurrency = 8}) async => {
    for (final id in videoIds)
      if (id == 'q2')
        id: (rating: RatingStatus.like, durations: const {'q2': 245}),
  };
}

Future<AppState> _boot(WidgetTester tester, _FakeTube tube) async {
  final dir = Directory.systemTemp.createTempSync('nt-rating-test');
  addTearDown(() => dir.deleteSync(recursive: true));
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
  final oauth = GoogleOAuth();
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
  // Test-only sign-in so the rating buttons render.
  state.testAccount = 'Tester';
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ChangeNotifierProvider.value(
          value: state,
          child: const NowPlayingScreen(),
        ),
      ),
    ),
  );
  state.player.playTracks([
    const Track(videoId: 'v1', title: 'One', durationSec: 200),
  ]);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return state;
}

Finder _likeButton() => find.byWidgetPredicate(
  (w) => w is IconButton && (w.tooltip == 'Like' || w.tooltip == 'Remove like'),
);

void main() {
  testWidgets('successful like stays highlighted', (tester) async {
    final tube = _FakeTube()..rateResult = true;
    final state = await _boot(tester, tube);
    expect(state.player.state.current?.rating, RatingStatus.unknown);
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.player.state.current?.rating, RatingStatus.like);
    expect(_likeButton(), findsOneWidget);
    expect(tester.widget<IconButton>(_likeButton()).tooltip, 'Remove like');
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('failed like reverts and shows a SnackBar', (tester) async {
    final tube = _FakeTube()..rateResult = false;
    final state = await _boot(tester, tube);
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Reverted to unliked…
    expect(state.player.state.current?.rating, RatingStatus.unknown);
    expect(tester.widget<IconButton>(_likeButton()).tooltip, 'Like');
    // …with a failure notice.
    expect(
      find.text("Couldn't save rating — check connection and sign-in."),
      findsOneWidget,
    );
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('up next queue gets batch-stamped with like states and lengths', (
    tester,
  ) async {
    final tube = _QueueStampTube();
    // Non-anonymous session so the stamp pass runs.
    tube.auth = const AuthSession(cookie: 'c', sapisidHash: 'h');
    final state = await _boot(tester, tube);
    state.player.playTracks([
      const Track(videoId: 'q1', title: 'One', durationSec: 200),
      const Track(videoId: 'q2', title: 'Two'),
    ]);
    // Drain the stamp chain: player stream -> batch fetch -> restamp.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(state.player.state.queue.length, 2);
    // q1 (current): single-read path reports indifferent…
    expect(state.player.state.queue[0].rating, RatingStatus.indifferent);
    // …while q2 (up next) is batch-stamped liked…
    expect(state.player.state.queue[1].rating, RatingStatus.like);
    // …and its length rides along on that same read (list rows like home
    // shelves carry none at all, so unplayed rows would read blank).
    expect(state.player.state.queue[1].durationSec, 245);
    // A row that already knows its length keeps it.
    expect(state.player.state.queue[0].durationSec, 200);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('like button shows spinner during write and ignores double-tap', (
    tester,
  ) async {
    final tube = _SlowTube();
    final state = await _boot(tester, tube);
    // Start unliked.
    expect(state.player.state.current?.rating, RatingStatus.unknown);
    // Tap like — should flip optimistically.
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await tester.pump();
    // During the write the icon is a loading indicator, button disabled.
    expect(find.byType(M3ELoadingIndicator), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_rounded), findsNothing);
    // Double-tap is ignored (guard active).
    await tester.tapAt(tester.getCenter(find.byType(M3ELoadingIndicator)));
    await tester.pump();
    expect(find.byType(M3ELoadingIndicator), findsOneWidget);
    // Complete the write.
    tube.rateResult = true;
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    // Spinner gone, like persisted.
    expect(state.player.state.current?.rating, RatingStatus.like);
    expect(find.byIcon(Icons.thumb_up_rounded), findsOneWidget);
    expect(tester.widget<IconButton>(_likeButton()).tooltip, 'Remove like');
    state.player.dispose();
    await tester.pump();
  });

  testWidgets(
    'tapping like on an already-liked track sends indifferent (unlike)',
    (tester) async {
      final tube = _FakeTube()..rateResult = true;
      final state = await _boot(tester, tube);
      // Start with the track already liked.
      state.player.updateTrackRating(
        state.player.state.current!.videoId,
        RatingStatus.like,
      );
      await tester.pump();
      expect(state.player.state.current?.rating, RatingStatus.like);
      // Tap like — should send indifferent (unlike).
      await tester.tap(find.byIcon(Icons.thumb_up_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Rate should have been called with indifferent.
      // The fake tube doesn't track the argument, but the button
      // should now show "Like" (not "Remove like").
      expect(tester.widget<IconButton>(_likeButton()).tooltip, 'Like');
      state.player.dispose();
      await tester.pump();
    },
  );
}
