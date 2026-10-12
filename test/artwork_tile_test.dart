// Artwork tile tests: the loading tile shimmers as one full bone
// (never a flat box with a lone icon), settled artless tiles keep the
// album icon, and playing a track reuses the list's square cover
// (palette included) instead of re-downloading the frame.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/artwork_image.dart';

import 'mock_dio.dart';

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

/// ArtworkStore double recording every crop-file resolution and
/// serving prebuilt files with no disk IO (real IO futures never
/// complete under FakeAsync without a real event turn).
class _RecordingStore extends ArtworkStore {
  _RecordingStore({required super.cacheDirPath, required this.files});

  final Map<String, File> files;
  final requested = <String>[];

  @override
  Future<File?> file(String url) {
    requested.add(url);
    return Future.value(files[url]);
  }
}

/// ArtworkStore double recording every palette decode and serving
/// prebuilt images with no disk IO or isolates.
class _PaletteStore extends ArtworkStore {
  _PaletteStore({required super.cacheDirPath, required this.images});

  final Map<String, img.Image> images;
  final requested = <String>[];

  @override
  Future<img.Image?> image(String url) {
    requested.add(url);
    return Future.value(images[url]);
  }
}

img.Image _solid(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

/// Minimal AppState harness for tile pumps: temp dirs, a fake engine,
/// and the real artwork store (or [art] when given).
({AppState state, InnerTube tube}) _harness({ArtworkStore? art}) {
  final dir = Directory.systemTemp.createTempSync('nt-tile-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube(
    squareCoversPath: '${dir.path}/square-covers.json',
  );
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final store = art ?? ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(store.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: store,
    oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  return (state: state, tube: tube);
}

Future<void> _pumpTile(
  WidgetTester tester,
  AppState state,
  Widget tile,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: MultiProvider(
          providers: [ChangeNotifierProvider.value(value: state)],
          child: tile,
        ),
      ),
    ),
  );
}

Finder _bones() =>
    find.byWidgetPredicate((w) => w is Bone);

void main() {
  group('tile skeleton bones', () {
    testWidgets('url-less tile under a loading scope bones the full tile',
        (tester) async {
      final env = _harness();
      final state = env.state;
      await _pumpTile(
        tester,
        state,
        const Skeletonizer(
          enabled: true,
          child: ArtworkImage(null, size: 48),
        ),
      );
      await tester.pump();
      // One bone for the whole tile — never the flat box with a
      // lone shimmering album glyph.
      expect(_bones(), findsOneWidget);
      expect(find.byIcon(Icons.album_rounded), findsNothing);
    });

    testWidgets('settled artless tile keeps the album icon', (tester) async {
      final state = _harness().state;
      await _pumpTile(tester, state, const ArtworkImage(null, size: 48));
      await tester.pump();
      expect(find.byIcon(Icons.album_rounded), findsOneWidget);
      expect(_bones(), findsNothing);
    });

    testWidgets('tile waiting for its bytes bones the full tile',
        (tester) async {
      final state = _harness().state;
      await _pumpTile(
        tester,
        state,
        const ArtworkImage('https://artwork.invalid/pending.jpg', size: 48),
      );
      // The download cannot have completed on the first frame, so the
      // tile is still waiting: full bone, no icon.
      expect(_bones(), findsOneWidget);
      expect(find.byIcon(Icons.album_rounded), findsNothing);
    });
  });

  group('square cover reuse on play', () {
    testWidgets('player tile resolves the cached square cover, not the frame',
        (tester) async {
      const vid = 'v-sq';
      const rawUrl = 'https://art.invalid/frame.jpg';
      const squareUrl = 'https://sq.invalid/cover.jpg';
      // The square cover's rendered crop, like a list tile would have
      // produced. The raw frame has nothing: requesting it resolves
      // to null and the tile would fall back to an icon.
      final dir = Directory.systemTemp.createTempSync('nt-tile-sq');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _RecordingStore(
        cacheDirPath: '${dir.path}/art',
        files: {squareUrl: File('${dir.path}/crop4.png')},
      );
      final env = _harness(art: store);
      final state = env.state;
      final tube = env.tube;
      addTearDown(store.close);
      tube.noteSquareCover(vid, squareUrl);
      await _pumpTile(
        tester,
        state,
        const ArtworkImage(rawUrl, size: 48, squareCoverKey: vid),
      );
      for (var i = 0; i < 15 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The tile asked for the square cover — never the raw frame —
      // and rendered it. (Image.file wraps its provider in a
      // ResizeImage for the display-size decode, so match by type.)
      expect(store.requested, contains(squareUrl));
      expect(store.requested, isNot(contains(rawUrl)));
      expect(find.byType(Image), findsOneWidget);
      // Let the square-cover save timer fire before the body ends: the
      // pending-timer check runs before addTearDown callbacks, and
      // tube.close() there would be too late.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('enrichment frame swap keeps the shown square cover',
        (tester) async {
      const vid = 'v-sq2';
      const rawA = 'https://art.invalid/frame-a.jpg';
      const rawB = 'https://art.invalid/frame-b.jpg';
      const squareUrl = 'https://sq.invalid/cover2.jpg';
      final dir = Directory.systemTemp.createTempSync('nt-tile-enrich');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _RecordingStore(
        cacheDirPath: '${dir.path}/art',
        files: {squareUrl: File('${dir.path}/crop4.png')},
      );
      final env = _harness(art: store);
      final state = env.state;
      final tube = env.tube;
      addTearDown(store.close);
      tube.noteSquareCover(vid, squareUrl);
      await _pumpTile(
        tester,
        state,
        const ArtworkImage(rawA, size: 48, squareCoverKey: vid),
      );
      for (var i = 0; i < 15 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Image), findsOneWidget);
      expect(store.requested, [squareUrl]);
      // Enrichment swaps the raw frame while the resolved square cover
      // stays put: the tile must keep showing it — no blank shimmer,
      // no refetch, no new resolution.
      await _pumpTile(
        tester,
        state,
        const ArtworkImage(rawB, size: 48, squareCoverKey: vid),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.album_rounded), findsNothing);
      expect(store.requested, [squareUrl]);
      // Drain the square-cover save timer before the body ends.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('tap palette comes from the square cover with no refetch',
        (tester) async {
      const vid = 'v-red';
      const rawUrl = 'https://art.invalid/frame.jpg';
      const squareUrl = 'https://sq.invalid/cover.jpg';
      final dir = Directory.systemTemp.createTempSync('nt-tile-pal');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Distinct bytes per URL: red square, blue frame. A red palette
      // proves the square cover fed it; any artwork HTTP proves a
      // re-download. Images are prebuilt in memory: real disk and
      // isolate IO never complete under FakeAsync.
      final art = _PaletteStore(
        cacheDirPath: '${dir.path}/art',
        images: {
          squareUrl: _solid(100, 100, 200, 20, 20),
          rawUrl: _solid(100, 100, 20, 20, 200),
        },
      );
      final httpCalls = <String>[];
      final tube = InnerTube(
        dio: mockDio((options) async {
          httpCalls.add(options.uri.toString());
          return (404, '');
        }),
        squareCoversPath: '${dir.path}/square-covers.json',
      );
      addTearDown(tube.close);
      final player = PlayerController(
        engine: _FakeEngine(),
        tube: tube,
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 1),
        configDirPath: dir.path,
      );
      addTearDown(player.dispose);
      final state = AppState(
        tube: tube,
        player: player,
        art: art,
        oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      addTearDown(art.close);
      tube.noteSquareCover(vid, squareUrl);
      await tester.pumpWidget(const SizedBox.shrink());
      const track = Track(
        videoId: vid,
        title: 'Red',
        artists: [ArtistRef('A')],
        thumbnails: [Thumbnail(rawUrl, width: 480, height: 360)],
        durationSec: 200,
      );
      const filler = Track(videoId: 'v2', title: 'Other', durationSec: 200);
      state.playSongs([track, filler], 0);
      for (var i = 0; i < 20 && state.coverPalette.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.coverPalette, isNotEmpty);
      // The square cover (not the blue frame) was decoded for it.
      expect(art.requested, contains(squareUrl));
      expect(art.requested, isNot(contains(rawUrl)));
      // Red dominates: the square cover fed the palette.
      final top = state.coverPalette.first;
      expect(top.r, greaterThan(top.b));
      // And no artwork URL was ever fetched over HTTP.
      expect(
        httpCalls
            .where((u) => u.contains('art.invalid') || u.contains('sq.invalid')),
        isEmpty,
      );
      // Drain one-shot timers (square-cover save, lyrics backoff)
      // before the body ends: the pending-timer check runs before
      // addTearDown callbacks. The player dispose is idempotent, so
      // the teardown backstop stays safe.
      await tester.pump(const Duration(seconds: 3));
      player.dispose();
    });
  });
}
