// App smoke test: boots the real AppState/AppShell with a fake engine and
// temp dirs, verifying the home loading state renders.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/main.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';


void main() {
  testWidgets('boots the app shell', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-app-test');
    addTearDown(() => dir.delete(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: FakeEngine(),
      tube: tube,
      configDirPath: dir.path,
    );
    addTearDown(player.dispose);
    final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
    addTearDown(art.close);
    final state = AppState(
      tube: tube,
      player: player,
      art: art,
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      openUrl: (_) async {},
    );
    addTearDown(state.dispose);
    final mpris = MprisService(controller: player);
    addTearDown(mpris.dispose);
    final discord = DiscordPresence();
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
    // Home shows the loading skeleton before the feed arrives.
    expect(find.byWidgetPredicate((w) => w is Skeletonizer), findsWidgets);
    expect(find.text('Search for music to start playing'), findsOneWidget);
  });

  testWidgets('playback errors surface a SnackBar, MPV cache noise does not', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-err-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: FakeEngine(),
      tube: tube,
      configDirPath: dir.path,
    );
    addTearDown(player.dispose);
    final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
    addTearDown(art.close);
    final state = AppState(
      tube: tube,
      player: player,
      art: art,
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      openUrl: (_) async {},
    );
    addTearDown(state.dispose);
    final mpris = MprisService(controller: player);
    addTearDown(mpris.dispose);
    final discord = DiscordPresence();
    addTearDown(discord.dispose);
    final lastfm = LastFmService(config: state.config);
    addTearDown(lastfm.dispose);
    const advice =
        'Playback failed — check your network connection or '
        'restart the app.';
    await tester.pumpWidget(
      NixieTubeApp(
        state: state,
        mpris: mpris,
        discord: discord,
        lastfm: lastfm,
      ),
    );
    await tester.pump();

    // Benign MPV cache notice: no SnackBar.
    await player.handleEngineError(
      'MPV: [error] mkv: Failed to create file cache.',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(advice), findsNothing);

    // A real failure: advise checking network or restarting.
    player.clearError();
    await tester.pump();
    await player.handleEngineError('No playable stream');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(advice), findsOneWidget);
    // Let the SnackBar dismiss so no timer is pending at teardown.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    player.dispose();
    await tester.pump();
  });
}
