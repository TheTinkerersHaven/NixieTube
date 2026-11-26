// Regression: a cold start through a deep link arrives from the platform
// as a pushed route with no generator, which used to throw
// "Could not find a generator for route". The app must show home and pop
// the stray route instead of crashing.

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Navigator, NavigatorState;

import 'fakes.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/main.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app.dart';
import 'package:nixietube/ui/app_state.dart';

void main() {
  testWidgets('an unknown route push shows home instead of crashing', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-deeplink-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: FakeEngine(),
      tube: tube,
      configDirPath: dir.path,
    );
    addTearDown(player.dispose);
    final state = AppState(
      tube: tube,
      player: player,
      art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      openUrl: (_) async {},
    );
    addTearDown(state.dispose);
    final mpris = MprisService(controller: player, supported: false);
    addTearDown(mpris.dispose);
    final DiscordPresenceBase discord = DiscordPresence();
    addTearDown(discord.dispose);
    final lastfm = LastFmService(config: state.config);
    addTearDown(lastfm.dispose);

    await tester.pumpWidget(
      NixieTubeApp(
        state: state,
        mpris: mpris,
        discord: discord,
        lastfm: lastfm,
      ),
    );
    await tester.pump();

    // The platform pushed "/callback?code=…" as a route in the crash;
    // pushing an unknown name reproduces the exact failure path.
    // pushNamed's future completes only when the route pops, so don't
    // await it.
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .pushNamed('/callback?code=abc&state=xyz'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // The stray route popped itself; exactly one home remains.
    expect(find.byType(AppShell), findsOneWidget);
  });
}
