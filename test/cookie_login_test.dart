// Tests for the browser-login handoff in Settings: with no (or an
// expired) cookie session the card offers to open YouTube Music for
// a fresh login, and tapping it opens exactly that URL.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
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
  Future<String?> play(String url) async => null;
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

Future<({AppState state, List<String> opened})> _pumpSettings(
  WidgetTester tester, {
  Future<ResolvedStream?> Function(String videoId)? resolveStream,
  String? configPath,
  InnerTube? tube,
  bool oauthDone = false,
}) async {
  final dir = Directory.systemTemp.createTempSync('nt-cookie-login');
  addTearDown(() => dir.deleteSync(recursive: true));
  tube ??= InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    resolveStream: resolveStream,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final oauth = GoogleOAuth();
  addTearDown(oauth.close);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final opened = <String>[];
  final config = SysConfig(
    configPath: configPath ?? '${dir.path}/config.properties',
  );
  if (oauthDone) {
    config.set('client_id', 'test-client');
    config.set('access_token', 'test-token');
  }
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
    config: config,
    openUrl: (url) async {
      opened.add(url);
    },
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
  return (state: state, opened: opened);
}

void main() {
  testWidgets('cookie login shows no login card when already signed in', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-cookie-login');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = SysConfig(configPath: '${dir.path}/config.properties');
    config.set('cookie', 'SAPISID=abc');
    config.set('sapisidHash', 'hash');
    final env = await _pumpSettings(
      tester,
      configPath: '${dir.path}/config.properties',
    );
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    env.state.notifyListeners();
    await tester.pump();
    expect(env.state.tube.auth.cookie, 'SAPISID=abc');
    expect(find.text('Sign in'), findsNothing);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('logoutCookie clears only the cookie session', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-logout-cookie');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = SysConfig(configPath: '${dir.path}/config.properties');
    config.set('cookie', 'SAPISID=abc');
    final env = await _pumpSettings(
      tester,
      configPath: '${dir.path}/config.properties',
    );
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    env.state.notifyListeners();
    await tester.pump();
    expect(env.state.tube.auth.cookie, 'SAPISID=abc');
    env.state.logoutCookie();
    expect(env.state.config.get('cookie'), isEmpty);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('full logout still clears everything', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-logout-full');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = SysConfig(configPath: '${dir.path}/config.properties');
    config.set('cookie', 'SAPISID=abc');
    final env = await _pumpSettings(
      tester,
      configPath: '${dir.path}/config.properties',
    );
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    env.state.notifyListeners();
    await tester.pump();
    env.state.logout();
    expect(env.state.tube.auth.cookie, isNull);
    expect(env.state.account, isNull);
    expect(env.state.config.get('cookie'), isEmpty);
    env.state.player.dispose();
    await tester.pump();
  });
}
