// The Discord status-line chooser end to end: tapping a chip behind the
// integration row's cog must reach the live presence — change the mode,
// persist it, and re-push the activity under the new mode. The picker is
// a private widget, so this drives the real settings screen and dialog.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/core/player/player_state.dart';
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

/// Records every activity pushed, so the test can assert what Discord
/// would actually be sent.
class _RecordingRpc implements DiscordRpc {
  final List<DiscordActivity> pushed = [];
  bool connected = false;

  @override
  bool get isConnected => connected;

  @override
  Future<void> initialize(String appId) async {}

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> setActivity(DiscordActivity activity) async {
    pushed.add(activity);
  }

  @override
  Future<void> clearActivity() async {}

  @override
  Future<void> disconnect() async => connected = false;
}

const _track = Track(
  videoId: 'abc123',
  title: 'Song Title',
  artists: [ArtistRef('Artist Name')],
  album: AlbumRef('Album Name'),
  durationSec: 200,
);

PlayerState _playing() => PlayerState(
  current: _track,
  playing: true,
  positionMs: 30000,
  durationMs: 200000,
  queue: const [_track],
  index: 0,
);

Future<
  ({
    AppState state,
    DiscordPresence discord,
    _RecordingRpc rpc,
    String configPath,
  })
>
_pumpSettings(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('nt-discord-line');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final oauth = GoogleOAuth();
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
  final lastfm = LastFmService(config: state.config);
  addTearDown(lastfm.dispose);
  final rpc = _RecordingRpc();
  // Enabled with a track already playing, so the presence holds a
  // session the chip can re-push.
  final discord = DiscordPresence(
    enabled: true,
    statusText: DiscordStatusText.app,
    rpc: rpc,
    retryInterval: const Duration(days: 1),
  );
  addTearDown(discord.dispose);

  // Mirrors main.dart: the providers sit *above* the MaterialApp, which
  // is what lets the cog's showDialog route reach them.
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ChangeNotifierProvider.value(value: mpris),
        ChangeNotifierProvider.value(value: discord),
        ChangeNotifierProvider.value(value: lastfm),
      ],
      child: MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: SettingsScreen()),
      ),
    ),
  );
  await tester.pump();

  await discord.update(_playing());
  return (state: state, discord: discord, rpc: rpc, configPath: dir.path);
}

/// The cog on the Discord toggle row.
final _discordCog = find.descendant(
  of: find.widgetWithText(Row, 'Discord Rich Presence'),
  matching: find.byIcon(Icons.settings_rounded),
);

/// Opens the Discord cog dialog from wherever the row currently sits.
Future<void> _openDialog(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Discord Rich Presence'),
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  expect(_discordCog, findsOneWidget);
  await tester.tapAt(tester.getCenter(_discordCog));
  await tester.pumpAndSettle();
  expect(find.text('Discord application ID'), findsOneWidget);
}

void main() {
  testWidgets('the chooser moves the live presence off the app name', (
    tester,
  ) async {
    final harness = await _pumpSettings(tester);
    final discord = harness.discord;
    final rpc = harness.rpc;
    final configPath = harness.configPath;

    // App mode is what the user sees as a stuck "NixieTube" line.
    expect(discord.statusText, DiscordStatusText.app);
    expect(rpc.pushed.single.name, 'NixieTube');
    expect(rpc.pushed.single.state, 'Artist Name');

    await _openDialog(tester);
    expect(find.text('App Name'), findsOneWidget);
    expect(find.text('Song Title'), findsOneWidget);
    expect(find.text('Song Artist'), findsOneWidget);
    expect(find.text('Song Album'), findsOneWidget);

    // Pick "Song Artist": the chip selects, the mode changes, the
    // activity is re-pushed and the choice is written to disk.
    await tester.tapAt(tester.getCenter(find.text('Song Artist')));
    await tester.pumpAndSettle();

    expect(discord.statusText, DiscordStatusText.artists);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Song Artist'))
          .selected,
      isTrue,
    );
    expect(rpc.pushed, hasLength(2));
    expect(rpc.pushed.last.name, 'Artist Name');
    expect(rpc.pushed.last.details, 'Song Title');
    expect(rpc.pushed.last.state, 'Artist Name');

    final reloaded = SysConfig(configPath: '$configPath/config.properties');
    expect(reloaded.discordStatusText, 'artists');

    discord.setEnabled(false);
    await tester.pump();
  });

  testWidgets('every mode reaches the activity pushed to Discord', (
    tester,
  ) async {
    final harness = await _pumpSettings(tester);
    final discord = harness.discord;
    final rpc = harness.rpc;
    await _openDialog(tester);

    final expected = <DiscordStatusText, String>{
      DiscordStatusText.song: 'Song Title',
      DiscordStatusText.album: 'Album Name',
      DiscordStatusText.app: 'NixieTube',
    };

    for (final entry in expected.entries) {
      await tester.tapAt(
        tester.getCenter(find.text(discordStatusTextLabel(entry.key))),
      );
      await tester.pumpAndSettle();
      expect(discord.statusText, entry.key);
      // The choice lands on the activity `name`: that is the line Discord
      // renders as the status line, and it substitutes the application
      // name when the field is missing.
      final activity = rpc.pushed.last;
      expect(activity.name, entry.value);
      expect(activity.details, 'Song Title');
      expect(activity.state, 'Artist Name');
    }

    discord.setEnabled(false);
    await tester.pump();
  });

  testWidgets('a paused track keeps the mode and marks the line paused', (
    tester,
  ) async {
    final harness = await _pumpSettings(tester);
    final discord = harness.discord;
    final rpc = harness.rpc;
    await _openDialog(tester);
    await tester.tapAt(tester.getCenter(find.text('Song Album')));
    await tester.pumpAndSettle();

    await discord.update(_playing().copyWith(playing: false));
    await tester.pumpAndSettle();

    expect(discord.statusText, DiscordStatusText.album);
    expect(rpc.pushed.last.name, 'Album Name');
    expect(rpc.pushed.last.state, '⏸ Artist Name');
    expect(rpc.pushed.last.timestamps?.end, isNull);

    discord.setEnabled(false);
    await tester.pump();
  });
}
