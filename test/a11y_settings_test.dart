// Accessibility settings widget tests: the Accessibility section
// renders all toggles, they persist to config, and reduced motion
// collapses the Now Playing transition duration to zero.

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
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:nixietube/ui/screens/settings_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/palette_backdrop.dart';


/// Boots the real [AppState] with temp dirs and a fake engine,
/// then pumps [child] under a MaterialApp with the same providers
/// the app root registers.
Future<({AppState state, String configPath})> _pumpWith(
  WidgetTester tester,
  Widget child,
) async {
  final dir = Directory.systemTemp.createTempSync('nt-a11y-settings');
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
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: state),
            ChangeNotifierProvider.value(value: mpris),
            ChangeNotifierProvider.value(value: discord),
            ChangeNotifierProvider.value(value: lastfm),
          ],
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
  return (state: state, configPath: '${dir.path}/config.properties');
}

/// InnerTube double with inert metadata: panel enrichment and
/// ratings resolve locally so no test triggers network.
class _NoopTube extends InnerTube {
  @override
  Future<Track> enrichTrack(Track track) async => track;

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}

/// Boots the real [AppState] with temp dirs and a fake engine,
/// then pumps the settings screen under a MaterialApp with the
/// same providers the app root registers.
Future<({AppState state, String configPath})> _pumpSettings(
  WidgetTester tester,
) => _pumpWith(tester, const SettingsScreen());

/// The switch inside the toggle row titled [title].
Finder _switchOf(String title) => find.descendant(
  of: find.widgetWithText(Row, title),
  matching: find.byType(Switch),
);

void main() {
  testWidgets('accessibility section renders and persists all toggles', (
    tester,
  ) async {
    final (:state, :configPath) = await _pumpSettings(tester);
    // The settings list builds lazily; scroll the toggles into view.
    await tester.scrollUntilVisible(
      find.text('Reduce motion'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('High contrast'), findsOneWidget);
    expect(find.text('Reduce motion'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Underline links'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Underline links'), findsOneWidget);
    // All off by default; the transition runs at full length.
    expect(state.config.highContrast, isFalse);
    expect(state.config.reducedMotion, isFalse);
    expect(state.config.underlineLinks, isFalse);
    expect(
      state.nowPlayingTransitionDuration,
      const Duration(milliseconds: 250),
    );

    // Toggling Reduce motion collapses the transition to zero
    // (scroll back: the underline check above moved it out of view).
    await tester.scrollUntilVisible(
      find.text('Reduce motion'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(_switchOf('Reduce motion'));
    await tester.pumpAndSettle();
    expect(state.config.reducedMotion, isTrue);
    expect(state.nowPlayingTransitionDuration, Duration.zero);

    // Toggling High contrast flips the theme flag. Scroll it into
    // view first — the list only revealed Reduce motion, so the
    // High contrast switch sits just above the viewport.
    await tester.scrollUntilVisible(
      find.text('High contrast'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(_switchOf('High contrast'));
    await tester.pumpAndSettle();
    expect(state.config.highContrast, isTrue);

    // Both persisted to disk.
    final reloaded = SysConfig(configPath: configPath);
    expect(reloaded.highContrast, isTrue);
    expect(reloaded.reducedMotion, isTrue);

    // Toggling Underline links persists too (default off).
    await tester.scrollUntilVisible(
      find.text('Underline links'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(_switchOf('Underline links'));
    await tester.pumpAndSettle();
    expect(state.config.underlineLinks, isTrue);
    expect(SysConfig(configPath: configPath).underlineLinks, isTrue);
  });

  testWidgets('reduce motion toggles off and restores the transition', (
    tester,
  ) async {
    final (:state, :configPath) = await _pumpSettings(tester);
    // Start from the enabled state so a single gesture turns
    // it back off (material_ui's Switch reliably toggles on
    // the first gesture of a test from either state).
    state.config.reducedMotion = true;
    state.refreshConfig();
    expect(state.nowPlayingTransitionDuration, Duration.zero);
    await tester.scrollUntilVisible(
      find.text('Reduce motion'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final switchFinder = _switchOf('Reduce motion');
    await tester.drag(switchFinder, const Offset(-500.0, 0.0));
    expect(state.config.reducedMotion, isFalse);
    expect(
      state.nowPlayingTransitionDuration,
      const Duration(milliseconds: 250),
    );
    final reloaded = SysConfig(configPath: configPath);
    expect(reloaded.reducedMotion, isFalse);
  });

  testWidgets('high contrast swaps the cover wash for a solid surface', (
    tester,
  ) async {
    const red = Color(0xFF5C0E0E);
    final result = await _pumpWith(
      tester,
      PaletteBackdrop(palette: List.filled(25, red)),
    );
    final state = result.state;
    DecoratedBox? gradientBox() => find
        .descendant(
          of: find.byType(PaletteBackdrop),
          matching: find.byType(DecoratedBox),
        )
        .evaluate()
        .map((e) => e.widget as DecoratedBox)
        .firstOrNull;
    // Full motion off, high contrast off: the gradient wash paints.
    expect(state.config.highContrast, isFalse);
    expect(gradientBox(), isNotNull);
    // Flipping high contrast swaps the wash for a solid surface
    // in place — no gradient, just the opaque surface fallback.
    state.config.highContrast = true;
    state.refreshConfig();
    await tester.pump();
    expect(gradientBox(), isNull);
    expect(
      find.descendant(
        of: find.byType(PaletteBackdrop),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color.a == 1.0,
        ),
      ),
      findsOneWidget,
    );
    // And back: the gradient returns when high contrast goes off.
    state.config.highContrast = false;
    state.refreshConfig();
    await tester.pump();
    expect(gradientBox(), isNotNull);
  });

  testWidgets('info tab links underline only when opted in', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-a11y-links');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = _NoopTube();
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
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              // ignore: avoid_print
              print('MATERIALAPP theme primary: ${Theme.of(ctx).colorScheme.primary}');
              return ChangeNotifierProvider.value(
                value: state,
                child: const NowPlayingScreen(),
              );
            },
          ),
        ),
      ),
    );
    state.player.playTracks([
      const Track(
        videoId: 'v1',
        title: 'One',
        artists: [ArtistRef('Some Artist', browseId: 'UC1')],
        durationSec: 200,
      ),
    ]);
    await tester.pump();
    // Tabs stage in after the overlay slide completes (a wall-clock
    // timer, not a ticker, so advance time explicitly).
    state.openNow();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    final onSurface = buildTheme().colorScheme.onSurface;
    Text artistLink() => tester.widget<Text>(
      find.byWidgetPredicate(
        (w) =>
            w is Text && w.data == 'Some Artist' && w.style?.color != onSurface,
      ),
    );
    // Off by default: plain primary-colored text, no underline.
    expect(state.config.underlineLinks, isFalse);
    expect(artistLink().style?.decoration, TextDecoration.none);
    // Opting in underlines the link in place.
    state.config.underlineLinks = true;
    state.refreshConfig();
    await tester.pumpAndSettle();
    expect(artistLink().style?.decoration, TextDecoration.underline);
    state.player.dispose();
    await tester.pump();
  });
}
