// Phone-width shell: bottom navigation replaces the desktop rail.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:silky_scroll/silky_scroll.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart'
    show ResolvedStream;
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/main.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/app_shell_desktop.dart';
import 'package:nixietube/ui/app_shell_mobile.dart';
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/screens/now_playing_desktop.dart';
import 'package:nixietube/ui/screens/now_playing_mobile.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/album_panel.dart';
import 'package:nixietube/ui/widgets/album_panel_desktop.dart';
import 'package:nixietube/ui/widgets/album_panel_mobile.dart';
import 'package:nixietube/ui/widgets/player_bar_mobile.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets(
    'phone layout swaps the rail for a bottom bar and uses mobile shell',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.resetPhysicalSize);

      final dir = Directory.systemTemp.createTempSync('nt-mobile-test');
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

      await tester.pumpWidget(
        NixieTubeApp(
          state: state,
          mpris: mpris,
          discord: discord,
          lastfm: lastfm,
        ),
      );
      await tester.pump();
      final semantics = tester.ensureSemantics();
      await tester.pump();

      expect(find.byType(AppShellMobile), findsOneWidget);
      expect(find.byType(AppShellDesktop), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(PlayerBarMobile), findsOneWidget);
      expect(find.byTooltip('Settings'), findsNothing);

      state.go(Screen.settings);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.drag(
        find.byType(SilkySingleChildScrollView),
        const Offset(0, -600),
      );
      await tester.pump();
      semantics.dispose();
    },
  );

  testWidgets('phone layout swaps album panel to mobile stacked view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.resetPhysicalSize);

    final dir = Directory.systemTemp.createTempSync('nt-mobile-panel-test');
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: const AlbumPlaylistView(
              title: 'Test Album',
              subtitle: '2026',
              description: 'A test album description.',
              art: null,
              owner: null,
              tracks: [
                Track(videoId: 'v1', title: 'Song 1', durationSec: 180),
                Track(videoId: 'v2', title: 'Song 2', durationSec: 200),
              ],
              numbered: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlbumPlaylistViewMobile), findsOneWidget);
    expect(find.byType(AlbumPlaylistViewDesktop), findsNothing);
    expect(find.text('Test Album'), findsOneWidget);
    expect(find.text('Song 1'), findsOneWidget);
    // The sort control is one compact centered row; picking an option
    // from its menu updates the label.
    final trigger = tester.getRect(
      find.byWidgetPredicate((w) => w is M3EPopupMenuButton<int>),
    );
    expect((trigger.left + trigger.right) / 2, closeTo(200, 1));
    await tester.tap(find.text('Sort: Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(find.text('Sort: Title'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout swaps Now Playing to mobile view', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.resetPhysicalSize);

    final dir = Directory.systemTemp.createTempSync('nt-mobile-now-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
    final player = PlayerController(
      engine: FakeEngine(),
      tube: tube,
      resolveStream: (id) async =>
          ResolvedStream(url: 'https://x/$id', bitrate: 1),
      configDirPath: dir.path,
    );
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

    player.playTracks([
      const Track(
        videoId: 'np1',
        title: 'Now Playing Song',
        artists: [ArtistRef('Test Artist')],
        durationSec: 210,
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: const NowPlayingScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NowPlayingMobile), findsOneWidget);
    expect(find.byType(NowPlayingDesktop), findsNothing);
    expect(find.text('Now Playing Song'), findsOneWidget);
    expect(find.text('Test Artist'), findsOneWidget);

    player.dispose();
    await tester.pump();
  });

  testWidgets(
    'phone settings opens with a back button and hides desktop rows',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.resetPhysicalSize);

      final dir = Directory.systemTemp.createTempSync(
        'nt-mobile-settings-test',
      );
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

      await tester.pumpWidget(
        NixieTubeApp(
          state: state,
          mpris: mpris,
          discord: discord,
          lastfm: lastfm,
        ),
      );
      await tester.pump();

      state.go(Screen.library);
      await tester.pump();
      state.go(Screen.settings);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Settings'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // MPRIS and Discord are desktop integrations, not phone settings.
      expect(find.text('Desktop integrations'), findsNothing);
      // Settings belongs to the library tab it was opened from.
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.selectedIndex, 2);

      // The Android back gesture pops the in-app stack instead of
      // leaving the app from Settings.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.screen, Screen.library);

      // The title bar's back button does the same.
      state.go(Screen.settings);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.screen, Screen.library);
    },
  );

  testWidgets('desktop settings keeps its title and integration rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.resetPhysicalSize);

    final dir = Directory.systemTemp.createTempSync('nt-desktop-settings-test');
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

    await tester.pumpWidget(
      NixieTubeApp(
        state: state,
        mpris: mpris,
        discord: discord,
        lastfm: lastfm,
      ),
    );
    await tester.pump();

    state.go(Screen.settings);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.text('Desktop integrations'), findsOneWidget);
  });

  testWidgets('phone artist page keeps its back button below the status bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.resetPhysicalSize);

    final dir = Directory.systemTemp.createTempSync('nt-mobile-artist-test');
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
    state.detail = DetailUiState(
      loading: false,
      artist: const ArtistDetail(
        name: 'Test Artist',
        description: '',
        thumbnails: [],
        topSongs: [],
        albums: [],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            padding: EdgeInsets.only(top: 24),
            viewPadding: EdgeInsets.only(top: 24),
          ),
          child: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: const DetailScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The artist hero spans the status bar, so its back button has to be
    // pushed below it explicitly.
    final back = tester.getRect(find.byTooltip('Back'));
    expect(back.top, greaterThanOrEqualTo(24));
  });
}
