// Appearance settings widget tests: the theme card renders
// the source toggle, the seed row only for the custom source,
// and persisting seed/override picks (plus Auto reset) to config.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/mpris.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/settings_screen.dart';
import 'package:nixietube/ui/theme.dart';

class _FakeEngine implements PlayerEngine {
  @override
  Future<bool> play(String url) async => true;
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

/// Boots the real [AppState] with temp dirs and a fake engine,
/// then pumps the settings screen with the same providers the
/// app root registers.
Future<({AppState state, String configPath})> _pumpSettings(
  WidgetTester tester,
) async {
  final dir = Directory.systemTemp.createTempSync('nt-theme-settings');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final oauth = GoogleOAuth(storePath: '${dir.path}/oauth.properties');
  addTearDown(oauth.close);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
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
          child: const SettingsScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
  return (state: state, configPath: '${dir.path}/config.properties');
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('appearance card switches source and picks seed colors', (
    tester,
  ) async {
    final (:state, :configPath) = await _pumpSettings(tester);
    await _scrollTo(tester, find.text('Appearance'));

    // Default: custom source with the YTM-red seed picked.
    expect(state.config.themeSource, 'custom');
    final seedBlue = find.byKey(const ValueKey('theme-seed-ff2196f3'));
    expect(seedBlue, findsOneWidget);

    // System source hides the seed row (labels mount twice —
    // label + checkedLabel — so toggle by button position).
    await _scrollTo(tester, find.byType(M3EToggleButton).first);
    await tester.tap(find.byType(M3EToggleButton).at(0));
    await tester.pumpAndSettle();
    expect(state.config.themeSource, 'system');
    expect(find.byKey(const ValueKey('theme-seed-ff2196f3')), findsNothing);

    // Back to custom: the seed row returns, and picking a
    // swatch persists it.
    await tester.tap(find.byType(M3EToggleButton).at(1));
    await tester.pumpAndSettle();
    expect(state.config.themeSource, 'custom');
    await _scrollTo(tester, seedBlue);
    await tester.tap(seedBlue);
    await tester.pumpAndSettle();
    expect(state.config.themeSeedColor, 0xff2196f3);
    expect(SysConfig(configPath: configPath).themeSeedColor, 0xff2196f3);
  });

  testWidgets('manual overrides apply per role and reset to Auto', (
    tester,
  ) async {
    final (:state, :configPath) = await _pumpSettings(tester);
    await _scrollTo(tester, find.text('Manual overrides'));
    expect(state.config.themePrimaryOverride, isNull);

    final primaryBlue = find.byKey(const ValueKey('theme-primary-ff2196f3'));
    await _scrollTo(tester, primaryBlue);
    await tester.tap(primaryBlue);
    await tester.pumpAndSettle();
    expect(state.config.themePrimaryOverride, 0xff2196f3);
    // Untouched roles stay on Auto.
    expect(state.config.themeSecondaryOverride, isNull);

    await tester.tap(find.byKey(const ValueKey('theme-primary-auto')));
    await tester.pumpAndSettle();
    expect(state.config.themePrimaryOverride, isNull);
    expect(SysConfig(configPath: configPath).themePrimaryOverride, isNull);
  });
}
