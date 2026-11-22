// The bar under fullscreen lyrics follows the window, not the build:
// a phone renders the compact transport (no volume button), a desktop
// window keeps the full one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/player_bar_mobile.dart';

/// Boots a real [AppState] on fullscreen lyrics at [size], returning the
/// player so the caller can cancel its prefetch timer before teardown.
Future<({AppState state, PlayerController player})> _pumpFullscreenLyrics(
  WidgetTester tester,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final dir = Directory.systemTemp.createTempSync('nt-fullscreen-bar');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  final state = AppState(
    tube: tube,
    player: player,
    art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  state.player.playTracks([
    const Track(videoId: 'v1', title: 'Song', durationSec: 200),
  ], 0);
  state.expandLyrics();
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return (state: state, player: player);
}

void main() {
  testWidgets('phone: fullscreen lyrics draws the compact bar without volume', (
    tester,
  ) async {
    final env = await _pumpFullscreenLyrics(tester, const Size(400, 900));

    expect(find.byType(PlayerBarMobile), findsOneWidget);
    expect(find.byTooltip('Previous'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    expect(find.byTooltip('Volume'), findsNothing);

    env.player.dispose();
    await tester.pump();
    env.state.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    // Past the artwork tile's one delayed retry (5s), which outlives the
    // bar's own disposal.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('desktop: fullscreen lyrics keeps the volume button', (
    tester,
  ) async {
    final env = await _pumpFullscreenLyrics(tester, const Size(1400, 900));

    expect(find.byType(PlayerBarMobile), findsNothing);
    expect(find.byTooltip('Volume'), findsOneWidget);

    env.player.dispose();
    await tester.pump();
    env.state.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    // Past the artwork tile's one delayed retry (5s), which outlives the
    // bar's own disposal.
    await tester.pump(const Duration(seconds: 6));
  });
}