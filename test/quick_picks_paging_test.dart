// Quick picks on a phone: one page of nine tiles at a time, swiped
// sideways with a dot per page, while a wide window keeps the single
// three-row grid. Play/shuffle still follow the whole set.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/account_library.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/home_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/cards.dart';

/// A tube that never reaches the network.
class _QuietTube extends InnerTube {
  @override
  Future<({List<Shelf> shelves, List<String> moods})> home() async =>
      (shelves: <Shelf>[], moods: <String>[]);

  @override
  Future<List<Shelf>> explore() async => const [];

  @override
  Future<({String? country, List<Track> tracks})> charts() async =>
      (country: null, tracks: <Track>[]);

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async => [];

  @override
  Future<List<Track>> enrichTracks(
    List<Track> tracks, {
    int concurrency = 8,
  }) async => tracks;

  @override
  Future<Map<String, RatingStatus>> ratings(
    List<String> videoIds, {
    int concurrency = 8,
  }) async => {};
}

/// A library with [songs] liked songs and no recent activity, so the
/// quick-picks pool is exactly those songs.
class _LikedLibrary extends AccountLibrary {
  _LikedLibrary({this.songs = 20});

  final int songs;

  @override
  int? get likedCount => songs;

  @override
  Future<List<AccountPlaylist>> playlists() async => const [];

  @override
  Future<List<Track>> recentActivity({int max = 30}) async => const [];

  @override
  Future<List<BrowseItem>> subscriptions({int max = 50}) async => const [];

  // No artwork: a cover URL would send the tiles looking for the square
  // art over the (stubbed) network and leave a timer behind.
  @override
  Future<List<Track>> likedVideos({int max = 2000}) async => [
    for (var i = 0; i < songs; i++)
      Track(
        videoId: 'v$i',
        title: 'Song $i',
        artists: [ArtistRef('Artist $i')],
      ),
  ];

  @override
  Future<String?> accountAvatar() async => null;
}

Future<AppState> _boot(WidgetTester tester, {int songs = 20}) async {
  final dir = Directory.systemTemp.createTempSync('nt-picks-paging');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _QuietTube();
  addTearDown(tube.close);
  final player = PlayerController(engine: FakeEngine(), tube: tube);
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  state.libraryOverride = _LikedLibrary(songs: songs);
  state.testAccount = 'Tester';
  await state.loadLibrary();
  // The grid shimmers until the home feed answers as well, so land it
  // here rather than pumping through the skeleton.
  await state.loadHome();
  return state;
}

Future<void> _pumpHome(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Titles of the quick-pick tiles currently laid out (one page on a
/// phone, the whole grid on a wide window).
List<String> _tiles(WidgetTester tester) => [
  for (final card in tester.widgetList<QuickPickCard>(
    find.byType(QuickPickCard),
  ))
    card.title,
];

/// The page dots' screen-reader labels, in order.
List<String> _dotLabels(WidgetTester tester) => [
  for (final semantics in tester.widgetList<Semantics>(find.byType(Semantics)))
    if (semantics.properties.label case final String label
        when label.startsWith('Page '))
      label,
];

Finder _dot(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

void main() {
  testWidgets('phone: quick picks page through nine tiles at a time', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final state = await _boot(tester);
    await _pumpHome(tester, state);

    expect(find.byType(PageView), findsOneWidget);
    // 20 picks over three pages, one dot each.
    expect(_dotLabels(tester), ['Page 1 of 3', 'Page 2 of 3', 'Page 3 of 3']);
    final firstPage = _tiles(tester);
    expect(firstPage, hasLength(9));

    // Swiping turns to the next nine, none of them repeated.
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final secondPage = _tiles(tester);
    expect(secondPage, hasLength(9));
    expect(secondPage.toSet().intersection(firstPage.toSet()), isEmpty);

    // A dot taps straight back to its page.
    await tester.tap(_dot('Page 1 of 3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_tiles(tester), firstPage);
  });

  testWidgets('phone: a single page shows no dots', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    // Seven liked songs: one page, so the dot row is not drawn.
    final state = await _boot(tester, songs: 7);
    await _pumpHome(tester, state);

    expect(find.byType(PageView), findsOneWidget);
    expect(_tiles(tester), hasLength(7));
    expect(_dotLabels(tester), isEmpty);
  });

  testWidgets('wide: the grid keeps one block and no pages', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final state = await _boot(tester);
    await _pumpHome(tester, state);

    expect(find.byType(PageView), findsNothing);
    // Four columns of three rows in the grid's own width share.
    expect(_tiles(tester), hasLength(12));
    expect(_dotLabels(tester), isEmpty);
  });
}
