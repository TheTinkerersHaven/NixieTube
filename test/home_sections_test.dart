// Tests for the fixed home sections: which feed shelves the pinned
// section selectors consume, which leftovers remain, the multi-column
// row layout the song-only sections use, and the cover-rail treatment
// opted into by sections like Forgotten favorites.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/home_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/cards.dart';
import 'package:nixietube/ui/widgets/rails.dart';

Shelf _shelf(String title) => Shelf(title, const []);

/// Player engine that never really plays, mirroring the other UI tests.
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
  int durationMs() => 200000;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

/// InnerTube double feeding one scripted personalized feed, scripted
/// Explore shelves and a scripted Charts read — no network.
class _FeedTube extends InnerTube {
  List<Shelf> shelves = const [];
  List<Shelf> exploreShelves = const [];
  String? country;
  List<Track> globalTracks = const [];

  @override
  Future<({List<String> moods, List<Shelf> shelves})> home() async =>
      (moods: const <String>[], shelves: shelves);

  @override
  Future<List<Shelf>> explore() async => exploreShelves;

  @override
  Future<({String? country, List<Track> tracks})> charts() async =>
      (country: country, tracks: globalTracks);

  @override
  Future<Track> enrichTrack(Track track) async => track;
  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}

/// Boots a real [AppState] over a [_FeedTube] with temp dirs.
Future<({AppState state, _FeedTube tube})> _bootHome(
  WidgetTester tester,
) async {
  final dir = Directory.systemTemp.createTempSync('nt-home-sections');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _FeedTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 1),
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final oauth = GoogleOAuth(storePath: '${dir.path}/oauth.properties');
  addTearDown(oauth.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  return (state: state, tube: tube);
}

Future<void> _pumpHome(WidgetTester tester, AppState state) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ChangeNotifierProvider.value(
          value: state,
          child: const HomeScreen(),
        ),
      ),
    ),
  );
}

void main() {
  group('firstShelfWithTitle', () {
    test('matches case-insensitively for the first needle found', () {
      final shelves = [
        _shelf('Listen again'),
        _shelf('New albums & singles'),
        _shelf('New music videos'),
      ];
      expect(
        firstShelfWithTitle(shelves, const ['new album'])?.title,
        'New albums & singles',
      );
      // "New music videos" must not be mistaken for new releases.
      expect(
        firstShelfWithTitle(shelves, const ['new album', 'new release'])?.title,
        'New albums & singles',
      );
      expect(firstShelfWithTitle(shelves, const ['trend']), isNull);
      expect(firstShelfWithTitle(const [], const ['trend']), isNull);
    });
  });

  group('isLeftoverShelf', () {
    test('consumes every pinned fixed-section title', () {
      for (final title in const [
        'Listen again',
        'Forgotten favorites',
        'Recaps',
        'New albums & singles',
        'New releases',
        'Trending',
        'Mixed for you',
      ]) {
        expect(
          isLeftoverShelf(title, showingPersonalPicks: false),
          isFalse,
          reason: title,
        );
      }
    });

    test('keeps unrelated editorial shelves', () {
      expect(
        isLeftoverShelf('Peaceful piano', showingPersonalPicks: false),
        isTrue,
      );
      expect(
        isLeftoverShelf('The sound of autumn', showingPersonalPicks: false),
        isTrue,
      );
    });

    test('keeps the feed Quick picks shelf unless the grid replaces it', () {
      expect(
        isLeftoverShelf('Quick picks', showingPersonalPicks: true),
        isFalse,
      );
      expect(
        isLeftoverShelf('Quick picks', showingPersonalPicks: false),
        isTrue,
      );
    });
  });

  group('TrackColumns', () {
    Future<void> pump(WidgetTester tester, {required int count}) {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              child: TrackColumns(
                title: 'Trending',
                count: count,
                itemBuilder: (context, i) =>
                    SizedBox(height: 40, child: Text('item $i')),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('stacks rows in columns of five, scrolling sideways', (
      tester,
    ) async {
      await pump(tester, count: 12);
      expect(find.text('Trending'), findsOneWidget);
      final p0 = tester.getTopLeft(find.text('item 0'));
      final p4 = tester.getTopLeft(find.text('item 4'));
      final p5 = tester.getTopLeft(find.text('item 5'));
      final p10 = tester.getTopLeft(find.text('item 10'));
      // 1000px / 460px min column width → two columns per screen.
      // The next column starts at the same row as column 0, to its right.
      expect(p5.dx, greaterThan(p0.dx));
      expect(p5.dy, closeTo(p0.dy, 0.5));
      expect(p4.dy, greaterThan(p0.dy));
      // The 11th item opens a third column further right instead of a
      // second band below: the section never grows past one screenful.
      expect(p10.dx, greaterThan(p5.dx));
      expect(p10.dy, closeTo(p0.dy, 0.5));
    });

    testWidgets('renders nothing for an empty section', (tester) async {
      await pump(tester, count: 0);
      expect(find.text('Trending'), findsNothing);
      expect(find.text('item 0'), findsNothing);
    });
  });

  group('home shelves', () {
    Shelf songShelf(String title, int count) => Shelf(title, [
      for (var i = 0; i < count; i++)
        ShelfItem.song(
          Track(
            videoId: '$title-$i',
            title: 'Song $i',
            artists: const [ArtistRef('An Artist')],
          ),
        ),
    ]);

    testWidgets('Forgotten favorites is a horizontal cover rail', (
      tester,
    ) async {
      // Wide, tall viewport: the vertical list must mount the section
      // and the rail must lay out all three cards at once.
      tester.view.physicalSize = const Size(1600, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final env = await _bootHome(tester);
      env.tube.shelves = [songShelf('Forgotten favorites', 3)];
      await env.state.loadHome();
      await _pumpHome(tester, env.state);
      await tester.pump();

      expect(find.text('Forgotten favorites'), findsOneWidget);
      // Covers, not the multi-column row list the other song-only
      // shelves keep.
      expect(find.byType(TrackRailCard), findsNWidgets(3));
      expect(find.byType(TrackColumns), findsNothing);
      expect(find.text('Song 0'), findsOneWidget);
    });

    testWidgets('other song-only leftovers keep the row columns', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final env = await _bootHome(tester);
      env.tube.shelves = [songShelf('The sound of autumn', 3)];
      await env.state.loadHome();
      await _pumpHome(tester, env.state);
      await tester.pump();

      expect(find.text('The sound of autumn'), findsOneWidget);
      expect(find.byType(TrackColumns), findsOneWidget);
      expect(find.byType(TrackRailCard), findsNothing);
    });

    testWidgets('Listen Again is a pinned row list, not a leftover', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final env = await _bootHome(tester);
      env.tube.shelves = [songShelf('Listen again', 3)];
      await env.state.loadHome();
      await _pumpHome(tester, env.state);
      await tester.pump();

      // Renamed to the pinned section's own title and rendered once, as
      // rows: the feed shelf no longer lands in the leftovers.
      expect(find.text('Listen Again'), findsOneWidget);
      expect(find.text('Listen again'), findsNothing);
      expect(find.byType(TrackColumns), findsOneWidget);
    });

    testWidgets('pinned sections render in the requested order', (
      tester,
    ) async {
      // Very tall viewport: the lazy home list must mount every section
      // for their vertical positions to be comparable.
      tester.view.physicalSize = const Size(1600, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final env = await _bootHome(tester);
      env.tube.shelves = [
        songShelf('Listen again', 3),
        songShelf('Forgotten favorites', 3),
        Shelf('Recaps', [
          ShelfItem.browse(
            title: 'A Recap',
            subtitle: 'An Artist',
            browseId: 'MPRErecap',
            thumbnails: const [],
          ),
        ]),
        songShelf('The sound of autumn', 2),
      ];
      env.tube.exploreShelves = [
        songShelf('New albums & singles', 3),
        songShelf('Trending', 3),
      ];
      env.tube.country = 'Italy';
      env.tube.globalTracks = [
        for (var i = 0; i < 4; i++)
          Track(
            videoId: 'global-$i',
            title: 'Global $i',
            artists: const [ArtistRef('An Artist')],
          ),
      ];
      await env.state.loadHome();
      await _pumpHome(tester, env.state);
      await tester.pump();

      const order = [
        'Listen Again',
        'Forgotten favorites',
        'New releases',
        'Albums made for you',
        'The sound of autumn',
        'Trending in Italy',
        'Trending globally',
      ];
      var previous = double.negativeInfinity;
      for (final title in order) {
        expect(find.text(title), findsOneWidget, reason: title);
        final dy = tester.getTopLeft(find.text(title)).dy;
        expect(dy, greaterThan(previous), reason: title);
        previous = dy;
      }
      // The worldwide chart renders its own tracks as rows.
      expect(find.text('Global 0'), findsOneWidget);
    });

    testWidgets('the country trending row names the country once known', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final env = await _bootHome(tester);
      env.tube.exploreShelves = [songShelf('Trending', 2)];
      // No country reported yet: the shelf keeps its own name.
      await env.state.loadHome();
      await _pumpHome(tester, env.state);
      await tester.pump();
      expect(find.text('Trending'), findsOneWidget);

      env.tube.country = 'Italy';
      await env.state.loadHome();
      await tester.pump();
      expect(find.text('Trending'), findsNothing);
      expect(find.text('Trending in Italy'), findsOneWidget);
    });
  });
}
