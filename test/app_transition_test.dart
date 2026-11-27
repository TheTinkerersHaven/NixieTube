// Tests for the app's screen navigation.
//
// The shell renders the navigation stack as routes: a push mounts a page
// over the current one, a pop returns to the page that was left (still
// loaded, offstage all along), and a system back press walks the same
// stack. The motion itself comes from the theme, so the platform's page
// transition — including Android's predictive back — drives it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';
import 'mock_dio.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/main.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/navigation.dart';
import 'package:nixietube/ui/screens/home_screen.dart';
import 'package:nixietube/ui/screens/search_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/page_swap.dart';

Future<AppState> _bootShell(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('nt-apptrans-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  // No network: a detail page's load answers at once instead of leaving
  // request timers pending at the end of the test.
  final tube = InnerTube(dio: mockDio((_) async => (404, '{}')));
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final config = SysConfig(configPath: '${dir.path}/config.properties');
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    config: config,
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  final mpris = MprisService(controller: player, artworkStore: art);
  addTearDown(mpris.dispose);
  final DiscordPresenceBase discord = DiscordPresence();
  addTearDown(discord.dispose);
  final lastfm = LastFmService(config: config);

  await tester.pumpWidget(
    NixieTubeApp(state: state, mpris: mpris, discord: discord, lastfm: lastfm),
  );
  // Bounded pumps only: the loading home shimmers forever, so the
  // tree never settles while skeletons show.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return state;
}

/// The navigation entry of the page on top, which is the one the user is
/// looking at even while the page it covers is still mounted under it.
NavEntry _shownEntry(WidgetTester tester) =>
    tester.widget<NavScreenView>(find.byType(NavScreenView).last).entry;

/// The route of the page that shows [screen].
ModalRoute<dynamic> _routeOf(WidgetTester tester, Type screen) =>
    ModalRoute.of(tester.element(find.byType(screen)))!;

/// Whether a page of [screen] is still in the tree, painted or not.
bool _mounted(Type screen) =>
    find.byType(screen, skipOffstage: false).evaluate().isNotEmpty;

/// Finishes a page transition. The first frame builds the new page and
/// starts its animation, the second runs the platform's 450 ms
/// transition out, and the third drops the page it covered.
Future<void> _settlePage(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

const _artist = BrowseItem(
  title: 'Artist',
  subtitle: '',
  browseId: 'UC123',
  thumbnails: [],
);

const _album = BrowseItem(
  title: 'Album',
  subtitle: '',
  browseId: 'MPRE456',
  thumbnails: [],
);

void main() {
  testWidgets('a push mounts the new page over the current one', (
    tester,
  ) async {
    final state = await _bootShell(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    final homePage = tester.element(
      find.byType(HomeScreen, skipOffstage: false),
    );
    state.go(Screen.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Both pages are in the tree while the new one comes in, and the new
    // one is its own route, still animating.
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
    final route = _routeOf(tester, SearchScreen);
    expect(route.isCurrent, isTrue);
    expect(route.animation!.value, lessThan(1.0));
    expect(_shownEntry(tester).screen, Screen.search);

    await _settlePage(tester);
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(_routeOf(tester, SearchScreen).isCurrent, isTrue);
    // The page below is still mounted under the new one rather than
    // rebuilt, which is what makes going back instant.
    expect(
      identical(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
        homePage,
      ),
      isTrue,
    );
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('back returns to the page left underneath', (tester) async {
    final state = await _bootShell(tester);
    state.go(Screen.search);
    await _settlePage(tester);

    final homePage = tester.element(
      find.byType(HomeScreen, skipOffstage: false),
    );
    state.goBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(_routeOf(tester, SearchScreen).animation!.value, lessThan(1.0));

    await _settlePage(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    // The page coming back is the same element instance the user left,
    // so its scroll position and loaded rows are still there.
    expect(identical(tester.element(find.byType(HomeScreen)), homePage), isTrue);
    expect(_mounted(SearchScreen), isFalse);
    expect(state.screen, Screen.home);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('a system back press pops a page', (tester) async {
    final state = await _bootShell(tester);
    state.go(Screen.search);
    await _settlePage(tester);
    expect(state.canGoBack, isTrue);

    // What Android sends for the back button, and what its gesture
    // commits to.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    await _settlePage(tester);

    expect(state.screen, Screen.home);
    expect(state.canGoBack, isFalse);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(_mounted(SearchScreen), isFalse);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('an overlay over the page keeps it from popping', (
    tester,
  ) async {
    final state = await _bootShell(tester);
    state.go(Screen.search);
    await _settlePage(tester);

    state.openNow();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    await _settlePage(tester);
    // The player covers the page: back must not throw the page away
    // behind it.
    expect(state.screen, Screen.search);

    state.closeNow();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    await _settlePage(tester);
    expect(state.screen, Screen.home);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('detail pages keep their own item under the next one', (
    tester,
  ) async {
    final state = await _bootShell(tester);
    state.go(Screen.detail, detail: _artist);
    await _settlePage(tester);
    expect(_shownEntry(tester).detail?.browseId, 'UC123');

    state.go(Screen.detail, detail: _album);
    await _settlePage(tester);
    expect(_shownEntry(tester).detail?.browseId, 'MPRE456');

    // Stepping back shows the artist page again — its own item, not the
    // album the page above it was opened for.
    state.goBack();
    await _settlePage(tester);
    expect(_shownEntry(tester).detail?.browseId, 'UC123');
    expect(state.detailItem?.browseId, 'UC123');
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('navigating to the page already showing is not a push', (
    tester,
  ) async {
    final state = await _bootShell(tester);
    state.go(Screen.home);
    state.go(Screen.home);
    expect(state.canGoBack, isFalse);

    // A detail page is identified by its item, so a different one is a
    // real push even though the screen is the same.
    state.go(Screen.detail, detail: _artist);
    await tester.pump();
    state.go(Screen.detail, detail: _artist);
    expect(state.navPages.length, 2);
    state.go(Screen.detail, detail: _album);
    expect(state.navPages.length, 3);
    await _settlePage(tester);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('the page motion follows the platform', (tester) async {
    final theme = buildTheme();
    final builders = theme.pageTransitionsTheme.builders;
    // Android's own predictive-back transition, which the system drives
    // with the gesture; the desktop keeps the app's rise.
    expect(
      builders[TargetPlatform.android],
      isA<PredictiveBackPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.linux],
      isA<NixiePageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.windows],
      isA<NixiePageTransitionsBuilder>(),
    );
  });
}
