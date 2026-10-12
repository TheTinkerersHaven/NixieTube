// Tests for the browser-login handoff in Settings: with no (or an
// expired) cookie session the card offers to open YouTube Music for
// a fresh login, and tapping it opens exactly that URL.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/auth_session.dart';
import 'package:nixietube/core/innertube/gdata_api.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
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

Future<({AppState state, List<String> opened})> _pumpSettings(
  WidgetTester tester, {
  Future<ResolvedStream?> Function(String videoId)? resolveStream,
  String? configPath,
  InnerTube? tube,
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
  final oauth = GoogleOAuth(storePath: '${dir.path}/oauth.properties');
  addTearDown(oauth.close);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final opened = <String>[];
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
    config: SysConfig(
      configPath: configPath ?? '${dir.path}/config.properties',
    ),
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

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  testWidgets('expired sessions point at the browser flow', (tester) async {
    final env = await _pumpSettings(tester);
    await _scrollTo(tester, find.text('Log in with browser'));
    // Embedded window primary; system browser + manual paste fallback.
    expect(find.text('Log in with browser'), findsOneWidget);
    expect(find.text('…or paste it manually:'), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('sign-out is per-session and hidden when signed out', (
    tester,
  ) async {
    final env = await _pumpSettings(tester);
    // Fresh state: neither session connected, so neither card offers
    // sign-out (Last.fm is disconnected too).
    await _scrollTo(tester, find.text('…or paste it manually:'));
    expect(find.text('Sign out'), findsNothing);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('system browser button opens YouTube Music', (tester) async {
    final env = await _pumpSettings(tester);
    final fallback = find.text('Open YouTube Music instead');
    await tester.ensureVisible(fallback);
    await tester.pump();
    await tester.tap(fallback);
    await tester.pump();
    // No native window involved: exactly one external-browser open.
    expect(env.opened, ['https://music.youtube.com']);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('embedded login degrades without native webview', (tester) async {
    final env = await _pumpSettings(tester);
    final loginButton = find.text('Log in with browser');
    await tester.ensureVisible(loginButton);
    await tester.pump();
    await tester.tap(loginButton);
    await tester.pump();
    // Native calls hang without the platform side: pump until the
    // capped waits fire into the error state.
    for (
      var i = 0;
      i < 30 &&
          find.text('Could not open the login window.').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Could not open the login window.'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.text('Cancel')));
    for (
      var i = 0;
      i < 10 &&
          find.text('Could not open the login window.').evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Could not open the login window.'), findsNothing);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('logoutCookie clears only the cookie session', (tester) async {
    final env = await _pumpSettings(tester);
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    expect(env.state.hasCookieSession, isTrue);
    env.state.logoutCookie();
    expect(env.state.hasCookieSession, isFalse);
    expect(env.state.oauthSignedIn, isFalse);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('full logout still clears everything', (tester) async {
    final env = await _pumpSettings(tester);
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    env.state.logout();
    expect(env.state.hasCookieSession, isFalse);
    expect(env.state.account, isNull);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('played tracks move to the head of activity', (tester) async {
    Track track(String id) =>
        Track(videoId: id, title: 'Title $id', artists: const []);
    final env = await _pumpSettings(
      tester,
      resolveStream: (id) async =>
          ResolvedStream(url: 'https://x/$id', bitrate: 128000),
    );
    expect(env.state.activity, isEmpty);
    env.state.player.playTracks([track('v1')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(env.state.activity.map((t) => t.videoId).toList(), ['v1']);
    // A second track jumps ahead; replaying dedups to the front.
    env.state.player.playTracks([track('v2')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    env.state.player.playTracks([track('v1')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(env.state.activity.map((t) => t.videoId).toList(), ['v1', 'v2']);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('pins toggle, persist as snapshots, and reload', (tester) async {
    ShelfItem song(String id) => ShelfItem.song(
      Track(videoId: id, title: 'Title $id', artists: const []),
    );
    ShelfItem album(String id) => ShelfItem.browse(
      title: 'Album $id',
      subtitle: 'Album',
      browseId: id,
      thumbnails: const [],
    );
    final env = await _pumpSettings(tester);
    expect(env.state.pinnedPicks, isEmpty);
    // Pinning stores a snapshot; unpinning removes by id.
    env.state.togglePin(song('v1'));
    env.state.togglePin(album('MPRE1'));
    expect(env.state.pinnedPicks.length, 2);
    expect(env.state.isPinned(song('v1')), isTrue);
    env.state.togglePin(song('v1'));
    expect(env.state.pinnedPicks.map(AppState.pickKeyOf), ['b:MPRE1']);
    // Codec round-trips both kinds, and drops junk.
    final songBack = AppState.pinFromJson(AppState.pinToJson(song('v9')));
    expect(songBack, isA<SongItem>());
    expect((songBack as SongItem).track.videoId, 'v9');
    final albumBack = AppState.pinFromJson(AppState.pinToJson(album('MPRE9')));
    expect(albumBack, isA<BrowseItem>());
    expect((albumBack as BrowseItem).browseId, 'MPRE9');
    expect(AppState.pinFromJson({'k': 'zzz'}), isNull);
    expect(AppState.pinFromJson('junk'), isNull);
    // Persisted synchronously: a fresh AppState on this config reloads
    // the pin from disk.
    expect(env.state.config.get('home.pinnedPicks', ''), contains('MPRE1'));
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('clear artwork cache resets and notifies', (tester) async {
    final env = await _pumpSettings(tester);
    expect(env.state.artworkCacheTick.value, 0);
    env.state.clearArtworkCache();
    await tester.pump();
    // Tick bumped (tiles reload) without throwing, including with an
    // empty player and no cached art.
    expect(env.state.artworkCacheTick.value, 1);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('session plays survive restart ahead of stale history', (
    tester,
  ) async {
    Track track(String id) =>
        Track(videoId: id, title: 'Title $id', artists: const []);
    Future<ResolvedStream?> resolve(String id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 128000);
    final dir = Directory.systemTemp.createTempSync('nt-restart');
    addTearDown(() => dir.deleteSync(recursive: true));
    final configPath = '${dir.path}/config.properties';
    // Session 1: play a song (persisted as a local recent).
    var env = await _pumpSettings(
      tester,
      configPath: configPath,
      resolveStream: resolve,
    );
    env.state.player.playTracks([track('v1')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(env.state.activity.map((t) => t.videoId).toList(), ['v1']);
    env.state.player.dispose();
    await tester.pump();
    // Session 2 (restart): the server still returns the stale list,
    // but the just-played song stays ahead of it.
    env = await _pumpSettings(
      tester,
      configPath: configPath,
      resolveStream: resolve,
      tube: _StaleTube(),
    );
    env.state.testAccount = 'me';
    env.state.apiOverride = _StaleGData();
    await env.state.loadLibrary();
    await tester.pump();
    expect(env.state.activity.map((t) => t.videoId).toList(), [
      'v1',
      'ten-toes',
    ]);
    env.state.player.dispose();
    await tester.pump();
  });
}

Track _restartTrack(String id) =>
    Track(videoId: id, title: 'Title $id', artists: const []);

/// Server frozen on old history, like a lagging watchtime backend.
class _StaleGData extends GDataApi {
  _StaleGData() : super(tokenProvider: () async => 'tok');

  @override
  Future<List<GPlaylist>> playlists() async => const [];

  @override
  Future<List<Track>> recentActivity({int max = 30}) async => [
    _restartTrack('ten-toes'),
  ];

  @override
  Future<List<ShelfItem>> subscriptions({int max = 50}) async => const [];

  @override
  Future<List<Track>> likedVideos({int max = 2000}) async => const [];

  @override
  Future<Map<String, String>> channelAvatars(List<String> ids) async => {};

  @override
  Future<String?> channelAvatar() async => null;
}

/// Tube with no network: enrichment is identity, radio is empty.
class _StaleTube extends InnerTube {
  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async => [];

  @override
  Future<Track> enrichTrack(Track track) async => track;
}
