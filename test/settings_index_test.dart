// Settings index widget tests: each category is one tappable segment,
// with no chevron, and the tap works across the segment's whole surface
// rather than only over its text.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/settings_screen.dart';

void main() {
  late Directory dir;

  Future<void> pumpIndex(WidgetTester tester) async {
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
    final mpris = MprisService(controller: player);
    addTearDown(mpris.dispose);
    final discord = DiscordPresence();
    addTearDown(discord.dispose);
    final lastfm = LastFmService(config: state.config);
    addTearDown(lastfm.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider.value(value: mpris),
          ChangeNotifierProvider.value(value: discord),
          ChangeNotifierProvider.value(value: lastfm),
        ],
        child: MaterialApp(home: Scaffold(body: SettingsScreen())),
      ),
    );
    await tester.pump();
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt-settings-index-');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  testWidgets('the index draws no chevrons', (tester) async {
    await pumpIndex(tester);

    expect(find.text('Playback'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('a tap on the segment surface opens the category',
      (tester) async {
    await pumpIndex(tester);

    // The row's own padding used to be outside the hit area: aim there,
    // a few pixels inside the segment's right edge.
    final segment = find
        .ancestor(
          of: find.text('Playback'),
          matching: find.byType(InkWell),
        )
        .first;
    final rect = tester.getRect(segment);
    await tester.tapAt(Offset(rect.right - 6, rect.center.dy));
    await tester.pumpAndSettle();

    expect(find.text('Keep audio on disk'), findsOneWidget);
  });

  testWidgets('the whole list is one segmented group', (tester) async {
    await pumpIndex(tester);

    final list = tester.widget<M3ESegmentedList>(
      find.byType(M3ESegmentedList),
    );
    expect(list.onTap, isNotNull);
    expect(list.itemCount, greaterThan(3));
  });
}
