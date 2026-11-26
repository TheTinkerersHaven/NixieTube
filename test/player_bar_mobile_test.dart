// Mobile player bar transport: previous sits beside play/pause and next,
// and the volume control stays off the bar entirely.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/player_bar_mobile.dart';
import 'package:nixietube/ui/widgets/volume_slider.dart';

/// Boots an [AppState] and pumps [child] under it at phone width.
Future<AppState> _pumpBar(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final dir = Directory.systemTemp.createTempSync('nt-player-bar');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
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
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ChangeNotifierProvider.value(value: state, child: child),
      ),
    ),
  );
  await tester.pump();
  return state;
}

void main() {
  testWidgets('the mobile bar offers previous beside play/pause and next', (
    tester,
  ) async {
    await _pumpBar(tester, const PlayerBarMobile());

    expect(find.byTooltip('Previous'), findsOneWidget);
    expect(find.byTooltip('Play/pause'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    // The three sit in that order: previous, play/pause, next.
    final previousX = tester.getCenter(find.byTooltip('Previous')).dx;
    final playX = tester.getCenter(find.byTooltip('Play/pause')).dx;
    final nextX = tester.getCenter(find.byTooltip('Next')).dx;
    expect(previousX, lessThan(playX));
    expect(playX, lessThan(nextX));
  });

  testWidgets('the mobile bar never draws a volume slider', (tester) async {
    await _pumpBar(tester, const PlayerBarMobile());

    expect(find.byType(VolumeSlider), findsNothing);
    expect(find.byTooltip('Volume'), findsNothing);
  });
}
