// Regression test for the lyric highlight animation: moving the
// active line must update rows in place so the swell plays. Keying
// only the active row remounts two rows per line change and the
// animation never runs — caught here via element identity.

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/lyrics_list.dart';

class _IdleEngine implements PlayerEngine {
  @override
  Future<String?> play(String url, {String? nextUrl}) async => null;
  @override
  Future<void> setNext(String? url) async {}
  @override
  Future<void> promoteNext() async {}
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

void main() {
  testWidgets('active line changes update rows in place', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-lyrics-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: _IdleEngine(),
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
    const lines = [
      LyricLine(timeMs: 0, text: 'first line'),
      LyricLine(timeMs: 60000, text: 'second line'),
      LyricLine(timeMs: 120000, text: 'third line'),
    ];
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    Widget buildAt(int positionMs) => ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: LyricsList(
            ctrl: ctrl,
            lyrics: lines,
            positionMs: positionMs,
            state: state,
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildAt(0));
    final second = tester.element(find.text('second line'));

    // Advance past line two: its row must update in place (same
    // Element), not remount, or the swell animation never plays.
    await tester.pumpWidget(buildAt(61000));
    final secondAfter = tester.element(find.text('second line'));
    expect(identical(second, secondAfter), isTrue);

    // The highlight itself moved to the second line (nearest
    // AnimatedDefaultTextStyle ancestor carries the row style).
    AnimatedDefaultTextStyle styleOf(String text) => tester.widget(
      find
          .ancestor(
            of: find.text(text),
            matching: find.byType(AnimatedDefaultTextStyle),
          )
          .first,
    );
    expect(
      styleOf('second line').style.color,
      isNot(styleOf('third line').style.color),
    );
    // Settle the follow-scroll animation before teardown.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('nothing highlights before the first line is sung', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-lyrics-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: _IdleEngine(),
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
    const lines = [
      LyricLine(timeMs: 5000, text: 'first line'),
      LyricLine(timeMs: 60000, text: 'second line'),
    ];
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    Widget buildAt(int positionMs) => ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: LyricsList(
            ctrl: ctrl,
            lyrics: lines,
            positionMs: positionMs,
            state: state,
          ),
        ),
      ),
    );
    AnimatedDefaultTextStyle styleOf(String text) => tester.widget(
      find
          .ancestor(
            of: find.text(text),
            matching: find.byType(AnimatedDefaultTextStyle),
          )
          .first,
    );

    // Intro: both rows share the inactive style.
    await tester.pumpWidget(buildAt(0));
    expect(
      styleOf('first line').style.fontSize,
      styleOf('second line').style.fontSize,
    );
    expect(
      styleOf('first line').style.color,
      styleOf('second line').style.color,
    );

    // First line's turn: only it highlights. The metrics stay put —
    // only the colour and the scale move — so the two rows keep one
    // size and the sung line cannot re-wrap.
    await tester.pumpWidget(buildAt(5000));
    expect(
      styleOf('first line').style.color,
      isNot(styleOf('second line').style.color),
    );
    expect(
      styleOf('first line').style.fontSize,
      styleOf('second line').style.fontSize,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('off-tab advances never page back to lyrics', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-lyrics-tab');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: _IdleEngine(),
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
    // Tall enough to scroll: the follow-scroll has somewhere to go.
    final lines = [
      for (var i = 0; i < 30; i++)
        LyricLine(timeMs: i * 60000, text: 'line $i'),
    ];
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    late TabController tabs;
    Widget buildAt(int positionMs) => ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: DefaultTabController(
          length: 3,
          initialIndex: 0,
          child: Builder(
            builder: (context) {
              tabs = DefaultTabController.of(context);
              return Scaffold(
                body: LyricsList(
                  ctrl: ctrl,
                  lyrics: lines,
                  positionMs: positionMs,
                  state: state,
                  visibleTabIndex: 1,
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildAt(0));
    expect(tabs.index, 0);
    // Advance deep into the list: rows highlight, but the tab strip
    // must not page back to the lyrics tab.
    await tester.pumpWidget(buildAt(20 * 60000));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tabs.index, 0);
    // Same advance while ON the lyrics tab still follows.
    tabs.animateTo(1);
    await tester.pumpAndSettle();
    expect(tabs.index, 1);
    await tester.pumpWidget(buildAt(25 * 60000));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(ctrl.offset, greaterThan(0));
  });

  testWidgets('switching tabs keeps the lyrics scroll position', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-lyrics-tabs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: _IdleEngine(),
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
    final lines = [
      for (var i = 0; i < 30; i++)
        LyricLine(timeMs: i * 60000, text: 'line $i'),
    ];
    // Mirrors the Now Playing tab strip: the controller and the
    // remembered offset live above the pages, so they survive the page
    // disposal a tab switch causes.
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    var offset = 0.0;
    ctrl.addListener(() {
      if (ctrl.hasClients) offset = ctrl.offset;
    });
    late TabController tabs;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: DefaultTabController(
            length: 3,
            initialIndex: 1,
            child: Builder(
              builder: (context) {
                tabs = DefaultTabController.of(context);
                return Scaffold(
                  body: TabBarView(
                    children: [
                      const SizedBox.shrink(),
                      LyricsList(
                        ctrl: ctrl,
                        lyrics: lines,
                        positionMs: 0,
                        state: state,
                        visibleTabIndex: 1,
                        restoreOffset: () => offset,
                      ),
                      const SizedBox.shrink(),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Scroll the lyrics by hand.
    ctrl.jumpTo(400);
    await tester.pump();
    expect(offset, greaterThan(0));

    // Away and back: the list must not jump.
    tabs.animateTo(0);
    await tester.pumpAndSettle();
    tabs.animateTo(1);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    expect(ctrl.offset, closeTo(400, 1));
  });

  testWidgets('a row keeps its height when it becomes the active line', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-lyrics-size');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: _IdleEngine(),
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
    // Long enough to wrap once it is laid out in the active style: the
    // interesting case is a line that needs a second row only when sung.
    const long =
        'and the words that were one line in the quiet part of the song '
        'now need somewhere else to go';
    const lines = [
      LyricLine(timeMs: 0, text: 'first line'),
      LyricLine(timeMs: 60000, text: long),
    ];
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    Widget buildAt(int positionMs) => ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: LyricsList(
            ctrl: ctrl,
            lyrics: lines,
            positionMs: positionMs,
            state: state,
          ),
        ),
      ),
    );

    double rowHeight(String text) => tester
        .getSize(
          find
              .ancestor(of: find.text(text), matching: find.byType(InkWell))
              .first,
        )
        .height;

    // The line's own layout: where its words break and how tall the
    // paragraph is. This is the form that must not change.
    Size textSize(String text) => tester.getSize(find.text(text));

    // Line one is sung, the long line is not.
    await tester.pumpWidget(buildAt(0));
    final idleRow = rowHeight(long);
    final idleText = textSize(long);

    // The long line becomes the active one. Let the style animation
    // finish: the highlight is colour and scale, so neither the row nor
    // the paragraph may have taken a different shape — an extra wrapped
    // row here would shove every line below it down on each change.
    await tester.pumpWidget(buildAt(61000));
    await tester.pump(const Duration(milliseconds: 400));
    expect(rowHeight(long), closeTo(idleRow, 0.5));
    expect(textSize(long), idleText);

    await tester.pump(const Duration(seconds: 1));
  });
}
