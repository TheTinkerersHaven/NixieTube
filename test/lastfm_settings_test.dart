// Settings Last.fm card widget test: renders the section, persists the
// toggle and credentials, and drives the browser-approval login flow end to
// end against a scripted HTTP client.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

import 'mock_dio.dart';

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

void main() {
  late Directory dir;
  late SysConfig config;
  late AppState state;
  late PlayerController player;
  late MprisService mpris;
  late DiscordPresence discord;
  late LastFmService lastfm;
  String? opened;

  Future<void> pumpSettings(WidgetTester tester) async {
    final tube = InnerTube();
    addTearDown(tube.close);
    player = PlayerController(
      engine: _FakeEngine(),
      tube: tube,
      configDirPath: dir.path,
    );
    addTearDown(player.dispose);
    config = SysConfig(configPath: '${dir.path}/config.properties');
    final oauth = GoogleOAuth();
    addTearDown(oauth.close);
    final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
    addTearDown(art.close);
    state = AppState(
      tube: tube,
      player: player,
      art: art,
      oauth: oauth,
      config: config,
      openUrl: (u) async => opened = u,
    );
    addTearDown(state.dispose);
    mpris = MprisService(controller: player);
    addTearDown(mpris.dispose);
    discord = DiscordPresence();
    addTearDown(discord.dispose);
    lastfm = LastFmService(
      config: config,
      dio: mockDio((options) async {
        final fields = Map<String, String>.from(options.data as Map);
        switch (fields['method']) {
          case 'auth.getToken':
            return (200, jsonEncode({'token': 'tok123'}));
          case 'auth.getSession':
            return (
              200,
              jsonEncode({
                'session': {'key': 'newsk', 'name': 'bob'},
              }),
            );
          default:
            return (200, '{}');
        }
      }),
    );
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
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt-settings-');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  /// Scrolls the settings list until [finder] is built/visible.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  /// Opens the Last.fm custom-credentials modal via the card's cog.
  Future<void> openKeysModal(WidgetTester tester) async {
    final cog = find.descendant(
      of: find.ancestor(
        of: find.text('Scrobble plays'),
        matching: find.byType(Card),
      ),
      matching: find.byTooltip('Advanced settings'),
    );
    await reveal(tester, cog);
    await tester.tap(cog);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Last.fm card renders, toggle and credentials persist', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.pump();
    await reveal(tester, find.text('Last.fm scrobbling'));

    // Section header + card body present, disabled by default.
    expect(find.text('Last.fm scrobbling'), findsOneWidget);
    expect(find.text('Scrobble plays'), findsOneWidget);
    expect(find.textContaining('Status: disabled'), findsOneWidget);

    // Toggle scrobbling on.
    final switchFinder = find.descendant(
      of: find.ancestor(
        of: find.text('Scrobble plays'),
        matching: find.byType(Card),
      ),
      matching: find.byType(Switch),
    );
    await tester.tap(switchFinder);
    await tester.pump();
    expect(config.lastfmEnabled, isTrue);
    // No session yet, so the status reads "signed out" (empty fields
    // fall back to the built-in key — only the session is missing).
    expect(find.textContaining('Status: signed out'), findsOneWidget);

    // Typing credentials (behind the cog) persists them.
    await openKeysModal(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Last.fm API key'),
      'apikey',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Last.fm shared secret'),
      'secret',
    );
    await tester.pump();
    expect(config.lastfmApiKey, 'apikey');
    expect(config.lastfmSecret, 'secret');
  });

  testWidgets('connect flow approves in the browser and signs in', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.pump();
    await reveal(tester, find.text('Last.fm scrobbling'));

    // Enable + fill credentials so Connect is actionable.
    final switchFinder = find.descendant(
      of: find.ancestor(
        of: find.text('Scrobble plays'),
        matching: find.byType(Card),
      ),
      matching: find.byType(Switch),
    );
    await tester.tap(switchFinder);
    await tester.pump();
    await openKeysModal(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Last.fm API key'),
      'apikey',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Last.fm shared secret'),
      'secret',
    );
    await tester.pump();

    // Sanity: credentials persisted before attempting the handshake.
    expect(config.lastfmApiKey, 'apikey');
    expect(config.lastfmSecret, 'secret');
    expect(config.lastfmEnabled, isTrue);

    // Dismiss the modal so the card's Connect button is tappable.
    await tester.tap(find.text('Close'));
    await tester.pump();

    // Connect: request token + open the browser approval URL. Dio's
    // interceptor chain runs on event-queue turns, which FakeAsync
    // withholds — advance the fake clock instead of flushing real
    // time (runAsync never releases those turns).
    await reveal(tester, find.text('Connect with last.fm'));
    await tester.tap(find.text('Connect with last.fm'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(opened, isNotNull);
    expect(opened, contains('www.last.fm/api/auth/'));
    expect(opened, contains('token=tok123'));
    await reveal(tester, find.text("I've authorized it"));
    expect(find.text("I've authorized it"), findsOneWidget);

    // Approve: exchange the token for a session.
    await tester.tap(find.text("I've authorized it"));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(config.lastfmSessionKey, 'newsk');
    expect(config.lastfmUsername, 'bob');
    await reveal(tester, find.text('Sign out'));
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.textContaining('Status: signed in as bob'), findsOneWidget);

    // Signing out clears the stored session.
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(config.lastfmSessionKey, '');
    expect(find.textContaining('Status: signed out'), findsOneWidget);
  });

  testWidgets('connect works with empty fields via the built-in key', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.pump();
    await reveal(tester, find.text('Last.fm scrobbling'));

    // Toggle on, leave both credential fields empty.
    final switchFinder = find.descendant(
      of: find.ancestor(
        of: find.text('Scrobble plays'),
        matching: find.byType(Card),
      ),
      matching: find.byType(Switch),
    );
    await tester.tap(switchFinder);
    await tester.pump();

    // Connect is actionable without custom credentials; the browser
    // approval URL carries the built-in key.
    await reveal(tester, find.text('Connect with last.fm'));
    await tester.tap(find.text('Connect with last.fm'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(opened, isNotNull);
    expect(opened, contains('api_key=$defaultLastfmApiKey'));
    expect(opened, contains('token=tok123'));
  });

  testWidgets('cog opens the custom-credentials modal', (tester) async {
    await pumpSettings(tester);
    await tester.pump();
    await reveal(tester, find.text('Last.fm scrobbling'));

    // Fields live behind the Last.fm card's cog, not inline.
    expect(find.widgetWithText(TextField, 'Last.fm API key'), findsNothing);
    await openKeysModal(tester);
    expect(find.widgetWithText(TextField, 'Last.fm API key'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Last.fm shared secret'),
      findsOneWidget,
    );

    // Typing a custom key persists it.
    await tester.enterText(
      find.widgetWithText(TextField, 'Last.fm API key'),
      'apikey',
    );
    await tester.pump();
    expect(config.lastfmApiKey, 'apikey');

    // Closing the modal keeps the card usable.
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.text('Connect with last.fm'), findsOneWidget);
  });
}
