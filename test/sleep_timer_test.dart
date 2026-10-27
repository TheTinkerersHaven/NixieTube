// Sleep timer widget tests: the Now Playing clock button opens the
// option sheet, arming shows the mode label, and cancelling hides it.
// Firing behavior lives in player_controller_test.dart; no real
// waiting happens here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:nixietube/ui/theme.dart';


Future<AppState> _boot(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('nt-sleep-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 1),
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

Finder _clockButton() => find.byWidgetPredicate(
  (w) =>
      w is IconButton &&
      (w.tooltip == 'Sleep timer' || w.tooltip == 'Sleep timer on'),
);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(_clockButton());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _openHeaderMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert_rounded));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sheet offers every option', (tester) async {
    final state = await _boot(tester);
    expect(_clockButton(), findsOneWidget);
    await _openSheet(tester);
    for (final label in [
      'In 15 minutes',
      'In 30 minutes',
      'In 45 minutes',
      'In 1 hour',
      'End of track',
      'End of queue',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // No timer armed: no cancel option.
    expect(find.text('Cancel timer'), findsNothing);
    await tester.tap(find.text('In 15 minutes'));
    await tester.pump();
    await tester.pump();
    expect(state.player.state.sleepTimerMode, SleepTimerMode.duration);
    // Active clock indicator; exact remaining time in the menu.
    expect(find.byTooltip('Sleep timer on'), findsOneWidget);
    await _openHeaderMenu(tester);
    expect(
      find.textContaining(RegExp(r'Sleep timer \(\d+:\d\d left\)')),
      findsOneWidget,
    );
    state.player.cancelSleepTimer();
    await tester.pump();
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('header menu shows the unarmed entry', (tester) async {
    final state = await _boot(tester);
    await _openHeaderMenu(tester);
    expect(find.text('Sleep timer'), findsOneWidget);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('end of track arms and shows in the menu', (tester) async {
    final state = await _boot(tester);
    await _openSheet(tester);
    await tester.tap(find.text('End of track'));
    await tester.pump();
    await tester.pump();
    expect(state.player.state.sleepTimerMode, SleepTimerMode.endOfTrack);
    expect(find.byTooltip('Sleep timer on'), findsOneWidget);
    await _openHeaderMenu(tester);
    expect(find.text('Sleep timer (end of track)'), findsOneWidget);
    // Static mode owns no timer; plain teardown is clean.
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('cancel timer hides the state', (tester) async {
    final state = await _boot(tester);
    state.player.setSleepTimerEndOfQueue();
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Sleep timer on'), findsOneWidget);
    await _openSheet(tester);
    expect(find.text('Cancel timer'), findsOneWidget);
    await tester.tap(find.text('Cancel timer'));
    await tester.pump();
    await tester.pump();
    expect(state.player.state.sleepTimerMode, SleepTimerMode.off);
    expect(find.byTooltip('Sleep timer'), findsOneWidget);
    state.player.dispose();
    await tester.pump();
  });
}
