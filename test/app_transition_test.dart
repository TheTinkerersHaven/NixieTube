// Tests for the app-shell screen transition: switching views slides
// the incoming screen in over a fade (outgoing drops at once, so
// lists never double-mount), settling on the new screen. Pushes come
// from the right, back pops and down-rail jumps from the left.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/main.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/screens/home_screen.dart';
import 'package:nixietube/ui/screens/search_screen.dart';

class _FakeEngine implements PlayerEngine {
  @override
  Future<bool> play(String url) async => true;
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
  int durationMs() => 0;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

Future<AppState> _bootShell(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('nt-apptrans-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final oauth = GoogleOAuth(storePath: '${dir.path}/oauth.properties');
  addTearDown(oauth.close);
  final config = SysConfig(configPath: '${dir.path}/config.properties');
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
    config: config,
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  final mpris = MprisService(controller: player, artworkStore: art);
  addTearDown(mpris.dispose);
  final discord = DiscordPresence();
  addTearDown(discord.dispose);
  final lastfm = LastFmService(config: config);

  await tester.pumpWidget(
    NixieTubeApp(
      state: state,
      mpris: mpris,
      discord: discord,
      lastfm: lastfm,
    ),
  );
  // Bounded pumps only: the loading home shimmers forever, so the
  // tree never settles while skeletons show.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return state;
}

/// Mid-flight vertical offsets of the switcher's slide above the
/// incoming [screen] (nested slides inside screens may exist; the
/// switcher is the one still animating right after navigation).
List<double> _slideDy(WidgetTester tester, Type screen) => tester
    .widgetList<SlideTransition>(
      find.ancestor(
        of: find.byType(screen),
        matching: find.byType(SlideTransition),
      ),
    )
    .map((s) => s.position.value.dy)
    .toList();

void main() {
  testWidgets('screen switches fade the new view in', (tester) async {
    final state = await _bootShell(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    state.go(Screen.search);
    await tester.pump(const Duration(milliseconds: 50));
    // Incoming screen mounted and still fading in; the outgoing one
    // is already gone (fade-in only, never double-mounted).
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.byType(SearchScreen),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades.any((f) => f.opacity.value < 1.0), isTrue);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SearchScreen), findsOneWidget);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('pushes rise from the bottom', (tester) async {
    final state = await _bootShell(tester);
    // Any push: incoming offset starts positive (below).
    state.go(Screen.search);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(
      _slideDy(tester, SearchScreen).any((dy) => dy > 0),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 300));
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('back pops sink from above', (tester) async {
    final state = await _bootShell(tester);
    state.go(Screen.search);
    await tester.pump(const Duration(milliseconds: 300));

    state.goBack();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(
      _slideDy(tester, HomeScreen).any((dy) => dy < 0),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 300));
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('detail drill-downs rise too', (tester) async {
    final state = await _bootShell(tester);
    state.go(
      Screen.detail,
      detail: const BrowseItem(
        title: 'Artist',
        subtitle: '',
        browseId: 'UC123',
        thumbnails: [],
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      _slideDy(tester, DetailScreen).any((dy) => dy > 0),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 300));
    state.player.dispose();
    await tester.pump();
  });
}
