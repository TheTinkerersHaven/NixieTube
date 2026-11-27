// Playback settings widget tests: the two stepped sliders exist, show
// their current value, write the choice to config, and appear only
// while the audio cache is on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

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
  late SysConfig config;

  Future<AppState> pumpPlayback(WidgetTester tester) async {
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: FakeEngine(),
      tube: tube,
      configDirPath: dir.path,
    );
    addTearDown(player.dispose);
    config = SysConfig(configPath: '${dir.path}/config.properties');
    final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
    addTearDown(art.close);
    final state = AppState(
      tube: tube,
      player: player,
      art: art,
      config: config,
      openUrl: (_) async {},
    );
    addTearDown(state.dispose);
    final mpris = MprisService(controller: player);
    addTearDown(mpris.dispose);
    final discord = DiscordPresence();
    addTearDown(discord.dispose);
    final lastfm = LastFmService(config: config);
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
    await openSettingsCategory(tester, 'Playback');
    return state;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt-audio-settings-');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  testWidgets('the sliders show the stored values', (tester) async {
    await pumpPlayback(tester);

    expect(find.text('Cache size'), findsOneWidget);
    expect(find.text('512 MB'), findsOneWidget);
    expect(find.text('Songs downloaded ahead'), findsOneWidget);
    expect(find.text('3 songs'), findsOneWidget);
    expect(find.byType(M3ESlider), findsNWidgets(2));
  });

  testWidgets('a slider writes the step it snaps to', (tester) async {
    final state = await pumpPlayback(tester);
    final cacheSlider = find.byType(M3ESlider).first;

    // The top of the cache slider is the largest step.
    final rect = tester.getRect(cacheSlider);
    await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
    await tester.pumpAndSettle();

    expect(state.config.audioCacheMb, audioCacheMbSteps.last);
    expect(find.text('4 GB'), findsOneWidget);
  });

  testWidgets('the sliders go away with the cache', (tester) async {
    await pumpPlayback(tester);

    final toggle = find.descendant(
      of: find.widgetWithText(Row, 'Keep audio on disk'),
      matching: find.byType(Switch),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('Cache size'), findsNothing);
    expect(find.text('Songs downloaded ahead'), findsNothing);
    expect(config.audioCacheEnabled, isFalse);
  });
}
