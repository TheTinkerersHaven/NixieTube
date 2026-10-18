// Unit tests for the shared album/playlist panel artwork and sort logic.

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/album_panel.dart';

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
  group('AlbumPlaylistView sort logic', () {
    test('default preserves original order', () {
      final tracks = [
        Track(videoId: 'b', title: 'B', durationSec: 10),
        Track(videoId: 'a', title: 'A', durationSec: 20),
      ];
      // Directly test the sort algorithm used in _AlbumPlaylistViewState
      final sorted = List<Track>.of(tracks);
      // _sort = 0 (default) → no sort applied
      expect(sorted.map((t) => t.videoId).toList(), ['b', 'a']);
    });

    test('title sort orders alphabetically', () {
      final tracks = [
        Track(videoId: 'c', title: 'C', durationSec: 5),
        Track(videoId: 'a', title: 'A', durationSec: 15),
        Track(videoId: 'b', title: 'B', durationSec: 10),
      ];
      final sorted = List<Track>.of(tracks);
      sorted.sort((a, b) => a.title.compareTo(b.title));
      expect(sorted.map((t) => t.title).toList(), ['A', 'B', 'C']);
    });

    test('duration sort orders longest first', () {
      final tracks = [
        Track(videoId: 'a', title: 'A', durationSec: 100),
        Track(videoId: 'b', title: 'B', durationSec: 300),
        Track(videoId: 'c', title: 'C', durationSec: 200),
      ];
      final sorted = List<Track>.of(tracks);
      sorted.sort((a, b) => b.durationSec.compareTo(a.durationSec));
      expect(sorted.map((t) => t.videoId).toList(), ['b', 'c', 'a']);
    });
  });

  group('sort control', () {
    testWidgets('keeps a fixed width across selection', (tester) async {
      final dir = Directory.systemTemp.createTempSync('nt-sort-test');
      addTearDown(() => dir.delete(recursive: true));
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: const AlbumPlaylistView(
                title: 'Album',
                subtitle: '',
                description: '',
                art: null,
                owner: null,
                tracks: [
                  Track(videoId: 'v1', title: 'One', durationSec: 100),
                  Track(videoId: 'v2', title: 'Two', durationSec: 200),
                ],
                numbered: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(M3EToggleButtonGroup);
      expect(button, findsOneWidget);
      final before = tester.getSize(button);
      // Selecting a different segment must not resize the control.
      // Labels mount twice (label + checkedLabel cross-fade), so tap
      // the toggle widgets by position instead of by text.
      await tester.tap(find.byType(M3EToggleButton).at(3));
      await tester.pumpAndSettle();
      final after = tester.getSize(button);
      expect(after.width, before.width);
      await tester.tap(find.byType(M3EToggleButton).at(0));
      await tester.pumpAndSettle();
      expect(tester.getSize(button).width, before.width);
    });
  });

  group('models', () {
    test('AlbumDetail carries artist ref', () {
      const artist = ArtistRef('Taylor Swift', browseId: 'UC123');
      final album = AlbumDetail(
        title: 'Folklore',
        subtitle: 'album',
        description: '',
        thumbnails: const [Thumbnail('https://example.com/cover.jpg')],
        tracks: const [],
        artist: artist,
      );
      expect(album.artist, isNotNull);
      expect(album.artist!.name, 'Taylor Swift');
      expect(album.artist!.browseId, 'UC123');
    });

    test('PlaylistDetail author can be null', () {
      final pl = PlaylistDetail(
        title: 'My Mix',
        subtitle: '',
        thumbnails: const [Thumbnail('https://example.com/art.jpg')],
        tracks: const [],
        author: null,
      );
      expect(pl.author, isNull);
    });

    test('ArtistRef hashCode/equals', () {
      const a = ArtistRef('Test', browseId: 'UC1');
      const b = ArtistRef('Test', browseId: 'UC1');
      const c = ArtistRef('Test', browseId: 'UC2');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == c, isFalse);
    });
  });

  group('play counts', () {
    Future<AppState> bootState() async {
      final dir = Directory.systemTemp.createTempSync('nt-views-test');
      addTearDown(() => dir.delete(recursive: true));
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
      return state;
    }

    Future<void> pumpPanel(
      WidgetTester tester,
      AppState state,
      bool showViews,
    ) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: AlbumPlaylistView(
                title: 'Album',
                subtitle: '',
                description: '',
                art: null,
                owner: null,
                tracks: const [
                  Track(
                    videoId: 'v1',
                    title: 'One',
                    durationSec: 100,
                    views: '1.8M plays',
                  ),
                  Track(videoId: 'v2', title: 'Two', durationSec: 200),
                ],
                numbered: true,
                showViews: showViews,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows play counts when enabled', (tester) async {
      final state = await bootState();
      await pumpPanel(tester, state, true);
      await tester.pumpAndSettle();
      expect(find.text('1.8M plays'), findsOneWidget);
    });

    testWidgets('hides play counts when disabled', (tester) async {
      final state = await bootState();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: const AlbumPlaylistView(
                title: 'Album',
                subtitle: '',
                description: '',
                art: null,
                owner: null,
                tracks: [
                  Track(
                    videoId: 'v1',
                    title: 'One',
                    durationSec: 100,
                    views: '1.8M plays',
                  ),
                ],
                numbered: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1.8M plays'), findsNothing);
    });
  });

  group('playlist collage square covers', () {
    Future<AppState> bootCollage() async {
      final dir = Directory.systemTemp.createTempSync('nt-collage-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 404 backend: square resolutions settle empty fast with no
      // timers or network, so assertions never race the backend.
      final tube = InnerTube(dio: mockDio((_) async => (404, '{}')));
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final state = AppState(
        tube: tube,
        player: player,
        art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
        oauth: GoogleOAuth(),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      return state;
    }

    testWidgets('collage cells never load raw frames', (tester) async {
      // Recognizably non-square collage sources backed by tracks: the
      // cells must wait for true squares (or placeholders), never
      // render the cropped frame — so no Image widget mounts at all.
      final tracks = [
        for (var i = 0; i < 4; i++)
          Track(
            videoId: 'c$i',
            title: 'T$i',
            durationSec: 200,
            thumbnails: [
              Thumbnail(
                'https://lh3.googleusercontent.com/x$i=w640-h360-l90-rj',
                width: 640,
                height: 360,
              ),
            ],
          ),
      ];
      final state = await bootCollage();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: AlbumPlaylistView(
                title: 'Playlist',
                subtitle: '',
                description: '',
                art: null,
                arts: [for (final t in tracks) t.displayArtwork!],
                owner: null,
                tracks: tracks,
                numbered: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Image), findsNothing);
      state.player.dispose();
      await tester.pump();
    });
  });
}
