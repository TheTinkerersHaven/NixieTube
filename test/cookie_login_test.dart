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
  String? authFilePath,
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
  if (oauthDone) {
    // A stored OAuth token unlocks step 2 (the InnerTube card) the
    // same way a completed step-1 sign-in would. hasStoredToken only
    // needs non-empty client id + access token.
    File('${dir.path}/oauth.properties')
        .writeAsStringSync('client_id=test-client\naccess_token=test-token\n');
  }
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
    authFilePath: authFilePath ?? '${dir.path}/auth.properties',
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
  testWidgets('sign-ins run in order: cookie card waits for OAuth', (
    tester,
  ) async {
    final env = await _pumpSettings(tester);
    await _scrollTo(tester, find.text('YouTube Data API'));
    // No OAuth token yet: the InnerTube card is the notice, and its
    // gated login button is inert.
    expect(
      find.text('Complete the Google sign-in above first.'),
      findsOneWidget,
    );
    final gated = find.descendant(
      of: find.byType(IgnorePointer),
      matching: find.text('Log in with browser'),
    );
    expect(gated, findsOneWidget);
    // The real cookie card (with its manual paste field) is absent.
    expect(find.text('…or paste it manually:'), findsNothing);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('expired sessions point at the browser flow', (tester) async {
    final env = await _pumpSettings(tester, oauthDone: true);
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
    final env = await _pumpSettings(tester, oauthDone: true);
    // OAuth done but no cookie session: only the Google card offers
    // sign-out (Last.fm is disconnected too).
    await _scrollTo(tester, find.text('…or paste it manually:'));
    expect(find.text('Sign out'), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('system browser button opens YouTube Music', (tester) async {
    final env = await _pumpSettings(tester, oauthDone: true);
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
    final env = await _pumpSettings(tester, oauthDone: true);
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
    // Seeded session file in a temp dir: logout must delete exactly
    // this file, never the real session.
    final dir = Directory.systemTemp.createTempSync('nt-logout-cookie');
    addTearDown(() => dir.deleteSync(recursive: true));
    final authPath = '${dir.path}/auth.properties';
    File(authPath).writeAsStringSync('cookie=SAPISID=abc\n');
    final env = await _pumpSettings(tester, authFilePath: authPath);
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    expect(env.state.hasCookieSession, isTrue);
    env.state.logoutCookie();
    expect(env.state.hasCookieSession, isFalse);
    expect(env.state.oauthSignedIn, isFalse);
    expect(File(authPath).existsSync(), isFalse);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('full logout still clears everything', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-logout-full');
    addTearDown(() => dir.deleteSync(recursive: true));
    final authPath = '${dir.path}/auth.properties';
    File(authPath).writeAsStringSync('cookie=SAPISID=abc\n');
    final env = await _pumpSettings(tester, authFilePath: authPath);
    env.state.tube.auth = const AuthSession(
      cookie: 'SAPISID=abc',
      sapisidHash: 'hash',
    );
    env.state.logout();
    expect(env.state.hasCookieSession, isFalse);
    expect(env.state.account, isNull);
    expect(File(authPath).existsSync(), isFalse);
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

  group('library resilience', () {
    Future<AppState> bootLibraryState({
      required InnerTube tube,
      GDataApi? api,
      String? account,
      String? authFilePath,
    }) async {
      final dir = Directory.systemTemp.createTempSync('nt-library-resil');
      addTearDown(() => dir.deleteSync(recursive: true));
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 128000),
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final state = AppState(
        tube: tube,
        player: player,
        art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
        oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        authFilePath: authFilePath ?? '${dir.path}/auth.properties',
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      // addTearDown runs LIFO: dispose the state before its deps.
      state.testAccount = account;
      state.apiOverride = api;
      return state;
    }

    test('failed library slots keep last-known-good rows', () async {
      Track liked(String id) =>
          Track(videoId: id, title: 'Title $id', artists: const []);
      final state = await bootLibraryState(
        tube: _StaleTube(),
        api: _GoodGData([liked('v1'), liked('v2')]),
        account: 'me',
      );
      await state.loadLibrary();
      expect(state.liked.map((t) => t.videoId), ['v1', 'v2']);
      // Every slot fails now: nothing is wiped, the liked entry stays.
      state.apiOverride = _ThrowingGData();
      await state.loadLibrary();
      expect(state.liked.map((t) => t.videoId), ['v1', 'v2']);
      expect(state.playlists.map((p) => p.id), contains('__liked'));
    });

    test('authoritative empty still clears its slot', () async {
      Track liked(String id) =>
          Track(videoId: id, title: 'Title $id', artists: const []);
      final state = await bootLibraryState(
        tube: _StaleTube(),
        api: _GoodGData([liked('v1')]),
        account: 'me',
      );
      await state.loadLibrary();
      expect(state.liked, hasLength(1));
      // A successful-but-empty fetch means "no likes": clears.
      state.apiOverride = _StaleGData();
      await state.loadLibrary();
      expect(state.liked, isEmpty);
    });

    test('cookie login refetches the personalized home feed', () async {
      final tube = _LoginTube();
      final authDir = Directory.systemTemp.createTempSync('nt-login-auth');
      addTearDown(() => authDir.deleteSync(recursive: true));
      final authPath = '${authDir.path}/auth.properties';
      final state = await bootLibraryState(tube: tube, authFilePath: authPath);
      // Anonymous startup feed.
      tube.personalized = false;
      await state.loadHome();
      expect(state.home.shelves.map((s) => s.title), ['Trending now']);
      // Cookie sign-in refetches: personalized rows replace the
      // generic ones without any further interaction.
      tube.personalized = true;
      // Stub the Data API so login's background library refresh
      // stays hermetic (no network after sign-in).
      state.apiOverride = _GoodGData(const []);
      final ok = await state.login('SAPISID=testhash; SID=testsid');
      expect(ok, isTrue);
      // The session persists to the isolated auth file (proving the
      // save path is hermetic too).
      expect(File(authPath).readAsStringSync(), contains('SAPISID=testhash'));
      // loadHome is fire-and-forget from login: the feed marker
      // flips synchronously but the state update trails by an event
      // turn (loadHome awaits through a timeout wrapper), so wait
      // for the shelves themselves, not just the marker.
      for (
        var i = 0;
        i < 100 && state.home.shelves.map((s) => s.title).join() != 'For you';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(tube.sawPersonalizedHome, isTrue);
      expect(state.home.shelves.map((s) => s.title), ['For you']);
    });

    test('plays bump counts, persist and reload', () async {
      Track song(String id) =>
          Track(videoId: id, title: 'Title $id', artists: const []);
      Future<AppState> bootCounts(String dir) async {
        final tube = _StaleTube();
        addTearDown(tube.close);
        final player = PlayerController(
          engine: _FakeEngine(),
          tube: tube,
          resolveStream: (id) async =>
              ResolvedStream(url: 'https://x/$id', bitrate: 128000),
          configDirPath: dir,
        );
        addTearDown(player.dispose);
        final state = AppState(
          tube: tube,
          player: player,
          art: ArtworkStore(cacheDirPath: '$dir/art'),
          oauth: GoogleOAuth(storePath: '$dir/oauth.properties'),
          config: SysConfig(configPath: '$dir/config.properties'),
          authFilePath: '$dir/auth.properties',
          openUrl: (_) async {},
        );
        addTearDown(state.dispose);
        return state;
      }

      final dir = Directory.systemTemp.createTempSync('nt-playcounts');
      addTearDown(() => dir.deleteSync(recursive: true));
      final state = await bootCounts(dir.path);
      Future<void> play(String id) async {
        state.player.playTracks([song(id)]);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      await play('a');
      await play('b');
      await play('a');
      expect(state.playCounts, {'a': 2, 'b': 1});
      // A fresh state on the same config reloads the counts.
      final again = await bootCounts(dir.path);
      expect(again.playCounts, {'a': 2, 'b': 1});
      // Let the background lyrics fetches land while the states
      // are still alive; a post-dispose notify would throw.
      await Future<void>.delayed(const Duration(seconds: 4));
    });

    test('history import merges max, never clears', () async {
      Track hist(String id) =>
          Track(videoId: id, title: 'Hist $id', artists: const []);
      final tube = _HistoryTube(
        counts: {'h1': 10, 'h2': 3},
        tracks: [hist('h2'), hist('h1'), hist('h9')],
      );
      final state = await bootLibraryState(tube: tube);
      await state.importHistoryCounts();
      expect(state.playCounts, {'h1': 10, 'h2': 3});
      // Tracks kept top-by-count for the pool (h9 uncounted, last).
      expect(state.historyTracks.map((t) => t.videoId), ['h1', 'h2', 'h9']);
      // Lower remote counts never win; absent ids are kept; empty
      // results are a no-op, not a wipe.
      tube.counts = {'h1': 4, 'h3': 1};
      await state.importHistoryCounts();
      expect(state.playCounts, {'h1': 10, 'h2': 3, 'h3': 1});
      tube.counts = {};
      await state.importHistoryCounts();
      expect(state.playCounts, {'h1': 10, 'h2': 3, 'h3': 1});
    });

    test('shelf ranking ignores enrichment churn, reacts to new ids', () async {
      Track song(String id, String artist) =>
          Track(videoId: id, title: 'Title $id', artists: [ArtistRef(artist)]);
      Shelf shelf(String title, List<Track> tracks) =>
          Shelf(title, [for (final t in tracks) SongItem(t)]);
      final api = _GoodGData(const [], activityTracks: [song('v1', 'Uno')]);
      final state = await bootLibraryState(
        tube: _StaleTube(),
        api: api,
        account: 'me',
      );
      await state.loadLibrary();
      // Generic row first in feed order, personal row second.
      state.home = HomeUiState(
        shelves: [
          shelf('Generic Mix', [song('g1', 'Someone')]),
          shelf('For Fans', [song('v1', 'Uno')]),
        ],
      );
      final first = state.rankedHomeShelves(state.home.shelves);
      expect(first.map((s) => s.title), ['For Fans', 'Generic Mix']);
      // Enrichment swaps objects with the same ids: the cached order
      // is reused (identical), so rows never jump.
      state.home = HomeUiState(
        shelves: [
          shelf('Generic Mix', [song('g1', 'Someone Else')]),
          shelf('For Fans', [song('v1', 'Uno Healed')]),
        ],
      );
      expect(
        identical(state.rankedHomeShelves(state.home.shelves), first),
        isTrue,
      );
      // New profile ids recompute: history now favors the generic row.
      api.activityTracks = [song('g1', 'Someone Else')];
      await state.loadLibrary();
      final second = state.rankedHomeShelves(state.home.shelves);
      expect(identical(second, first), isFalse);
      expect(second.map((s) => s.title), ['Generic Mix', 'For Fans']);
    });

    test('artist avatars persist across launches', () async {
      Track librarian() => const Track(
        videoId: 'v1',
        title: 'Title',
        artists: [ArtistRef('Singer', browseId: 'UC1')],
        thumbnails: [Thumbnail('https://x/song.jpg')],
        durationSec: 200,
      );
      Future<AppState> bootAvatars(String dir, GDataApi api) async {
        final tube = _StaleTube();
        addTearDown(tube.close);
        final player = PlayerController(
          engine: _FakeEngine(),
          tube: tube,
          resolveStream: (id) async =>
              ResolvedStream(url: 'https://x/$id', bitrate: 128000),
          configDirPath: dir,
        );
        addTearDown(player.dispose);
        final state = AppState(
          tube: tube,
          player: player,
          art: ArtworkStore(cacheDirPath: '$dir/art'),
          oauth: GoogleOAuth(storePath: '$dir/oauth.properties'),
          config: SysConfig(configPath: '$dir/config.properties'),
          authFilePath: '$dir/auth.properties',
          openUrl: (_) async {},
        );
        addTearDown(state.dispose);
        state.testAccount = 'me';
        state.apiOverride = api;
        return state;
      }

      final dir = Directory.systemTemp.createTempSync('nt-avatars');
      addTearDown(() => dir.deleteSync(recursive: true));
      const pic = 'https://x/avatar.jpg';
      // Session 1: song cover first, profile picture after enrichment.
      var state = await bootAvatars(
        dir.path,
        _GoodGData(
          const [],
          activityTracks: [librarian()],
          avatars: const {'UC1': pic},
        ),
      );
      await state.loadLibrary();
      for (
        var i = 0;
        i < 100 &&
            state.recentArtists
                    .map((a) => a.thumbnails.map((t) => t.url).join())
                    .join() !=
                pic;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(state.recentArtists.single.thumbnails.single.url, pic);
      expect(
        SysConfig(configPath: '${dir.path}/config.properties')
            .get('home.artistAvatars', ''),
        contains('UC1'),
      );
      // Session 2 (restart): the avatar service is down, but the
      // remembered picture still paints — never a song cover.
      state = await bootAvatars(
        dir.path,
        _GoodGData(const [], activityTracks: [librarian()]),
      );
      await state.loadLibrary();
      expect(state.recentArtists.single.thumbnails.single.url, pic);
    });
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
  Future<Map<String, ({RatingStatus rating, Map<String, int> durations})>>
  watchInfos(List<String> videoIds, {int concurrency = 8}) async => {};

  @override
  Future<Track> enrichTrack(Track track) async => track;

  @override
  Future<({String? country, List<Track> tracks})> charts() async =>
      (country: null, tracks: const <Track>[]);
}

/// Tube double with a scripted watch-history snapshot.
class _HistoryTube extends _StaleTube {
  _HistoryTube({required this.counts, this.tracks = const []});

  Map<String, int> counts;
  List<Track> tracks;

  @override
  Future<({Map<String, int> counts, List<Track> tracks})> historySnapshot({
    int maxItems = 500,
  }) async => (counts: counts, tracks: tracks);
}

/// Data API double with scripted liked songs, everything else empty.
class _GoodGData extends GDataApi {
  _GoodGData(
    this.likedTracks, {
    this.activityTracks = const [],
    this.avatars = const {},
  }) : super(tokenProvider: () async => 'tok');

  final List<Track> likedTracks;

  /// Mutable so tests can evolve server history between loads.
  List<Track> activityTracks;

  /// Scripted channel avatars by channel id.
  Map<String, String> avatars;

  @override
  Future<List<GPlaylist>> playlists() async => const [];

  @override
  Future<List<Track>> recentActivity({int max = 30}) async => activityTracks;

  @override
  Future<List<ShelfItem>> subscriptions({int max = 50}) async => const [];

  @override
  Future<List<Track>> likedVideos({int max = 2000}) async => likedTracks;

  @override
  Future<Map<String, String>> channelAvatars(List<String> ids) async => avatars;

  @override
  Future<String?> channelAvatar() async => null;
}

/// Data API double where every slot fails, like a transient
/// network/quota blip mid-refresh.
class _ThrowingGData extends GDataApi {
  _ThrowingGData() : super(tokenProvider: () async => 'tok');

  @override
  Future<List<GPlaylist>> playlists() async => throw Exception('down');

  @override
  Future<List<Track>> recentActivity({int max = 30}) async =>
      throw Exception('down');

  @override
  Future<List<ShelfItem>> subscriptions({int max = 50}) async =>
      throw Exception('down');

  @override
  Future<List<Track>> likedVideos({int max = 2000}) async =>
      throw Exception('down');
}

/// Tube double for the cookie-login refetch test: auth calls succeed
/// locally, and the home feed switches from generic to personalized
/// once the test flips [personalized] (sign-in happened).
class _LoginTube extends InnerTube {
  bool personalized = false;
  bool sawPersonalizedHome = false;

  @override
  Future<bool> verifyLogin() async => true;

  @override
  Future<String?> accountName() async => 'Tester';

  @override
  Future<String?> fetchSessionToken() async => null;

  @override
  Future<({List<Shelf> shelves, List<String> moods})> home() async {
    if (personalized) {
      sawPersonalizedHome = true;
      return (shelves: [const Shelf('For you', [])], moods: const <String>[]);
    }
    return (
      shelves: [const Shelf('Trending now', [])],
      moods: const <String>[],
    );
  }

  @override
  Future<List<Shelf>> explore() async => const <Shelf>[];

  @override
  Future<({String? country, List<Track> tracks})> charts() async =>
      (country: null, tracks: const <Track>[]);

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async => [];

  @override
  Future<Map<String, ({RatingStatus rating, Map<String, int> durations})>>
  watchInfos(List<String> videoIds, {int concurrency = 8}) async => {};

  @override
  Future<({Map<String, int> counts, List<Track> tracks})> historySnapshot({
    int maxItems = 500,
  }) async => (counts: <String, int>{}, tracks: <Track>[]);

  @override
  Future<Track> enrichTrack(Track track) async => track;

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}
