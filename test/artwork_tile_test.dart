// Artwork tile tests: the loading tile shimmers as one full bone
// (never a flat box with a lone icon), settled artless tiles keep the
// album icon, and playing a track reuses the list's square cover
// (palette included) instead of re-downloading the frame.

import 'dart:io';

import 'package:dio/dio.dart';
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
import 'package:nixietube/ui/widgets/cards.dart';

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
({AppState state, InnerTube tube}) _harness({ArtworkStore? art, Dio? dio}) {
  final dir = Directory.systemTemp.createTempSync('nt-tile-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube(
    dio: dio,
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

Future<void> _pumpTile(WidgetTester tester, AppState state, Widget tile) async {
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

Finder _bones() => find.byWidgetPredicate((w) => w is Bone);

void main() {
  group('tile skeleton bones', () {
    testWidgets('url-less tile under a loading scope bones the full tile', (
      tester,
    ) async {
      final env = _harness();
      final state = env.state;
      await _pumpTile(
        tester,
        state,
        const Skeletonizer(enabled: true, child: ArtworkImage(null, size: 48)),
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

    testWidgets('tile waiting for its bytes bones the full tile', (
      tester,
    ) async {
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

    testWidgets('tile decodes at width only, never squishing frames', (
      tester,
    ) async {
      // HiDPI: a 48px row on a 2x screen must decode 96 bitmap pixels,
      // or the tile upscales and looks soft.
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      // A real 16:9 file behind a plain (keyless) tile: decoding with
      // both cacheWidth and cacheHeight would resize it to exact
      // square pixels — the squish. Width-only keeps the aspect and
      // BoxFit.cover handles the box.
      final dir = Directory.systemTemp.createTempSync('nt-tile-aspect');
      addTearDown(() => dir.deleteSync(recursive: true));
      const url = 'https://artwork.invalid/wide.jpg';
      File('${dir.path}/wide.png')
          .writeAsBytesSync(img.encodePng(_solid(160, 90, 10, 200, 30)));
      final store = _RecordingStore(
        cacheDirPath: '${dir.path}/art',
        files: {url: File('${dir.path}/wide.png')},
      );
      final env = _harness(art: store);
      addTearDown(store.close);
      await _pumpTile(tester, env.state, const ArtworkImage(url, size: 48));
      await tester.pump();
      for (var i = 0; i < 10 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final image = tester.widget<Image>(find.byType(Image));
      // Width-only decode: the provider carries a width cap and no
      // height cap, so the frame keeps its aspect instead of
      // squishing to exact square pixels.
      final provider = image.image;
      expect(provider, isA<ResizeImage>());
      expect((provider as ResizeImage).width, 96);
      expect(provider.height, isNull);
    });

    testWidgets('keyed non-square frame falls back to the frame on a miss', (
      tester,
    ) async {
      // 404 backend: the square resolution settles empty on microtasks
      // (no timers, no network), so the fallback is deterministic.
      const frameUrl = 'https://lh3.googleusercontent.com/x=w640-h360-l90-rj';
      final missing = mockDio((_) async => (404, '{}'));
      final dir = Directory.systemTemp.createTempSync('nt-tile-miss');
      addTearDown(() => dir.deleteSync(recursive: true));
      final frame = File('${dir.path}/frame.png')
        ..writeAsBytesSync(img.encodePng(_solid(160, 90, 10, 200, 30)));
      final store = _RecordingStore(
        cacheDirPath: '${dir.path}/art',
        files: {frameUrl: frame},
      );
      final env = _harness(art: store, dio: missing);
      addTearDown(store.close);
      await _pumpTile(
        tester,
        env.state,
        const ArtworkImage(frameUrl, size: 48, squareCoverKey: 'v-miss'),
      );
      await tester.pump();
      // The 404 resolution settles over several microtask turns; drain
      // until the frame fallback lands (bounded).
      for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // No square art exists for this video, so the tile shows the 16:9
      // frame (the square box cover-fits it) instead of a blank icon —
      // and it never blanked out waiting for art that does not exist.
      expect(store.requested, [frameUrl]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.album_rounded), findsNothing);
    });
  });

  group('square cover reuse on play', () {
    testWidgets('quick-pick tile shows the square cover, not the 16:9 still', (
      tester,
    ) async {
      // The quick-picks grid art was the activity still (16:9). The card
      // must resolve the track's square cover and render that instead —
      // never the cropped frame.
      const stillUrl = 'https://i.ytimg.com/vi/v-pick/maxresdefault.jpg';
      const squareUrl = 'https://sq.invalid/pick.jpg';
      final dir = Directory.systemTemp.createTempSync('nt-tile-pick');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _RecordingStore(
        cacheDirPath: '${dir.path}/art',
        files: {squareUrl: File('${dir.path}/crop4.png')},
      );
      final env = _harness(art: store);
      addTearDown(store.close);
      env.tube.noteSquareCover('v-pick', squareUrl);
      await _pumpTile(
        tester,
        env.state,
        QuickPickCard(
          title: 'Pick',
          subtitle: 'Artist',
          art: stillUrl,
          squareCoverKey: 'v-pick',
          onTap: () {},
        ),
      );
      for (var i = 0; i < 15 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(store.requested, contains(squareUrl));
      expect(store.requested, isNot(contains(stillUrl)));
      expect(find.byType(Image), findsOneWidget);
      // Drain the square-cover save timer before the body ends.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('player tile resolves the cached square cover, not the frame', (
      tester,
    ) async {
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

    testWidgets('enrichment frame swap keeps the shown square cover', (
      tester,
    ) async {
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

    testWidgets('tap palette comes from the square cover with no refetch', (
      tester,
    ) async {
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
        httpCalls.where(
          (u) => u.contains('art.invalid') || u.contains('sq.invalid'),
        ),
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

  test('tileSize reads the PNG header without a full decode', () async {
    final dir = Directory.systemTemp.createTempSync('nt-tilesize');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ArtworkStore(cacheDirPath: dir.path);
    addTearDown(store.close);
    const url = 'https://x/v.png';
    final path = store.tileFilePath(url);
    // PNG signature + an IHDR chunk declaring 1280x720; nothing after it.
    final header = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, // length 13
      0x49, 0x48, 0x44, 0x52, // "IHDR"
      0x00, 0x00, 0x05, 0x00, // width = 1280
      0x00, 0x00, 0x02, 0xD0, // height = 720
    ];
    await File(path).writeAsBytes(header);
    expect(await store.tileSize(url), (1280, 720));
    expect(await store.tileSize('https://x/missing.png'), isNull);
  });

  testWidgets('cover-fit decode width scales with the render aspect', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    // A 1280x720 frame in a 48px square tile must decode at least ceil(48 *
    // 16 / 9) = 85px wide so BoxFit.cover fills the box from its short side
    // without upscaling into softness.
    const url = 'https://i.ytimg.com/vi/v-wide/maxresdefault.jpg';
    final dir = Directory.systemTemp.createTempSync('nt-tile-aspect2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final png = File('${dir.path}/tile.png')
      ..writeAsBytesSync(img.encodePng(_solid(1280, 720, 10, 200, 30)));
    final store = _SizedStore(
      cacheDirPath: '${dir.path}/art',
      files: {url: png},
      sizes: {url: (1280, 720)},
    );
    final state = _harness(art: store).state;
    await _pumpTile(tester, state, const ArtworkImage(url, size: 48));
    ImageProvider? provider;
    for (
      var i = 0;
      i < 60 &&
          !(find.byType(Image).evaluate().isNotEmpty &&
              (provider = tester.widget<Image>(find.byType(Image)).image)
                  is ResizeImage &&
              (provider as ResizeImage).width == 85);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(Image), findsOneWidget);
    expect(provider, isNotNull);
    expect((provider as ResizeImage).width, 85);
  });
}

class _SizedStore extends _RecordingStore {
  _SizedStore({
    required super.cacheDirPath,
    required super.files,
    required this.sizes,
  });

  final Map<String, (int, int)?> sizes;

  @override
  Future<(int, int)?> tileSize(String url) async => sizes[url];
}
