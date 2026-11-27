// The liked list's presentation: it says when it holds fewer songs
// than the playlist counts (YouTube's playlist header counts every
// entry of the playlist while its shelf only renders the ones it can
// serve), and the library's "Liked songs" card shows the playlist's
// own cover.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/account_library.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/home_screen.dart';
import 'package:nixietube/ui/screens/library_screen.dart';
import 'package:nixietube/ui/theme.dart' show sectionHeaderGap;
import 'package:nixietube/ui/widgets/cards.dart';
import 'package:provider/provider.dart';

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

  @override
  Future<List<Thumbnail>> playlistArtwork(
    String browseId, {
    String? params,
  }) async => const [
    Thumbnail('https://x/cover-192.png', width: 192, height: 192),
    Thumbnail('https://x/cover-576.png', width: 576, height: 576),
    Thumbnail('https://x/cover-1200.png', width: 1200, height: 1200),
  ];
}

/// A library double whose playlist holds more songs than the shelf
/// served.
class _ShortLibrary extends AccountLibrary {
  _ShortLibrary({this.count = 524, this.songs = 3});

  /// The count the playlist's header reports.
  final int count;

  /// How many songs the shelf served.
  final int songs;

  @override
  int? get likedCount => count;

  @override
  Future<List<AccountPlaylist>> playlists() async => const [];

  @override
  Future<List<Track>> recentActivity({int max = 30}) async => const [];

  @override
  Future<List<BrowseItem>> subscriptions({int max = 50}) async => const [];

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

/// A tube whose radios answer at once, so Discover can be built.
class _DiscoverTube extends _QuietTube {
  final radioCalls = <String>[];

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async {
    radioCalls.add(videoId);
    return [Track(videoId: 'radio-$videoId', title: 'Radio $videoId')];
  }
}

/// A library double whose slow slots stay on the wire while the liked
/// list and the recent activity answer.
class _GatedLibrary extends _ShortLibrary {
  final playlistsGate = Completer<void>();
  final artistsGate = Completer<void>();

  @override
  Future<List<AccountPlaylist>> playlists() async {
    await playlistsGate.future;
    return const [];
  }

  @override
  Future<List<BrowseItem>> subscriptions({int max = 50}) async {
    await artistsGate.future;
    return const [];
  }

  @override
  Future<List<Track>> recentActivity({int max = 30}) async => [
    const Track(videoId: 'a1', title: 'Recent One'),
  ];
}

Future<AppState> _boot(
  _ShortLibrary api, {
  bool wait = true,
  InnerTube? feed,
}) async {
  final dir = Directory.systemTemp.createTempSync('nt-liked-note');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = feed ?? _QuietTube();
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
  state.libraryOverride = api;
  state.testAccount = 'Tester';
  if (wait) {
    await state.loadLibrary();
  } else {
    unawaited(state.loadLibrary());
  }
  return state;
}

void main() {
  test('the liked songs card shows the playlist own cover', () async {
    final state = await _boot(_ShortLibrary());
    // The cover lands after the library load.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final liked = state.playlists.firstWhere((p) => p.id == '__liked');
    // YouTube's own art for the liked-music playlist, at a size the
    // card can use.
    expect(liked.art, 'https://x/cover-576.png');
  });

  test('the grid stops waiting for playlists and artists', () async {
    final api = _GatedLibrary();
    final state = await _boot(api, wait: false);
    // Liked songs and the recent activity answer first: the home grid
    // holds everything it reads, so it can stop shimmering...
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(state.liked, hasLength(3));
    expect(state.activity.map((t) => t.title), contains('Recent One'));
    expect(state.quickPicksLoading, isFalse);
    expect(state.discoverLoading, isFalse);
    // ...while the playlists and the artists are still on the wire.
    expect(state.libraryLoading, isTrue);
    expect(api.playlistsGate.isCompleted, isFalse);
    expect(api.artistsGate.isCompleted, isFalse);

    // They land too, and the library's own flag clears with the last of
    // them.
    api.playlistsGate.complete();
    api.artistsGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(state.libraryLoading, isFalse);
    expect(state.playlists.map((p) => p.id), contains('__liked'));
  });

  test('discover seeds from the library without waiting for it all', () async {
    final api = _GatedLibrary();
    final state = await _boot(api, wait: false, feed: _DiscoverTube());
    // Discover is seeded by the liked songs and the recent activity, so
    // it is built as soon as those land...
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(state.discover, isNotEmpty);
    expect(state.discover.every((t) => t.videoId.startsWith('radio-')), isTrue);
    // ...while the playlists and the artists are still on the wire, and
    // the rail no longer holds its slot open.
    expect(api.playlistsGate.isCompleted, isFalse);
    expect(state.discoverLoading, isFalse);
  });

  test('the liked playlist view shows that cover, not a mosaic', () async {
    final state = await _boot(_ShortLibrary());
    // The cover lands after the library load.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final liked = state.playlists.firstWhere((p) => p.id == '__liked');
    expect(liked.art, 'https://x/cover-576.png');

    // The entry can carry a collage of the first songs...
    final withCollage = AccountPlaylist(
      id: '__liked',
      title: 'Liked songs',
      itemCount: 4,
      art: 'https://x/cover-576.png',
      arts: const ['https://x/a.png', 'https://x/b.png'],
    );
    // ...but opening it hands the view no collage sources, so it paints
    // the playlist's own cover instead of a 2x2 mosaic.
    expect(withCollage.art, 'https://x/cover-576.png');
    expect(playlistViewArts(withCollage), isEmpty);

    // Other playlists keep their mosaic.
    final playlist = AccountPlaylist(
      id: 'PL1',
      title: 'Mix',
      itemCount: 4,
      arts: const ['https://x/a.png', 'https://x/b.png'],
    );
    expect(playlistViewArts(playlist), playlist.arts);
  });

  testWidgets('the liked playlist says when songs are missing', (tester) async {
    final state = await _boot(_ShortLibrary());
    expect(state.likedLoadNote, '3 of 524 songs loaded');

    // The liked songs live in the library's "Liked songs" playlist
    // entry; opening it says how many of the playlist's songs loaded.
    final liked = state.playlists.firstWhere((p) => p.id == '__liked');
    // The playlist's own count, the way YouTube Music reports it.
    expect(liked.itemCount, 524);
    await state.openPlaylist(liked);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
      ),
    );
    await tester.pump();
    expect(
      find.text('Automatic playlist · 3 of 524 songs loaded'),
      findsOneWidget,
    );
  });

  testWidgets('a complete list needs no note', (tester) async {
    final state = await _boot(_ShortLibrary(count: 3));
    expect(state.likedLoadNote, isNull);

    final liked = state.playlists.firstWhere((p) => p.id == '__liked');
    await state.openPlaylist(liked);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
      ),
    );
    await tester.pump();
    expect(find.text('Automatic playlist'), findsOneWidget);
    expect(find.textContaining('songs loaded'), findsNothing);
  });

  testWidgets('the home shows the note next to the liked songs title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    // Six songs so the personal block (quick picks + liked column)
    // shows.
    final state = await _boot(_ShortLibrary(songs: 6));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump();

    final title = tester.getTopLeft(find.text('Liked songs'));
    final note = tester.getTopLeft(find.text('6 of 524 songs loaded'));
    // Same row, right of the title.
    expect(note.dx, greaterThan(title.dx));
    expect(note.dy, closeTo(title.dy, 24));
  });

  testWidgets('the quick picks and liked songs titles share a line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    // Six songs so the personal block (quick picks + liked column)
    // shows.
    final state = await _boot(_ShortLibrary(songs: 6));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump();

    final quick = tester.getTopLeft(find.text('Quick picks'));
    final liked = tester.getTopLeft(find.text('Liked songs'));
    // Both headings are the same size, so their tops must match.
    expect(liked.dy, closeTo(quick.dy, 1));
    // The heading hugs its text: the trailing controls are exactly as
    // tall as the title box, not a 48px button row.
    final titleBox = tester.getRect(find.text('Quick picks'));
    final playButton = tester.getRect(find.byTooltip('Play quick picks'));
    expect(playButton.height, closeTo(titleBox.height, 1));
    expect(playButton.top, closeTo(titleBox.top, 1));
  });

  testWidgets('phone: every section heading is one height, button or not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final state = await _boot(_ShortLibrary(songs: 9), feed: _DiscoverTube());
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    // Discover is seeded by the radios the liked songs kick off.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.text('Discover'), findsOneWidget);

    // The heading plus the gap under it: the same box for a heading with
    // a Play all button (Discover) as for one without (Quick picks).
    double headingBox(String title) => tester
        .getSize(
          find.ancestor(of: find.text(title), matching: find.byType(Padding))
              .first,
        )
        .height;

    final quick = headingBox('Quick picks');
    expect(headingBox('Discover'), closeTo(quick, 0.5));
    // ...and that box is a line of title, not a 48dp button row.
    expect(quick, lessThan(48));

    // The first tile and the first Discover card both start the same
    // distance under their own heading.
    final quickGap =
        tester.getTopLeft(find.byType(QuickPickCard).first).dy -
        tester.getBottomLeft(find.text('Quick picks')).dy;
    final discoverGap =
        tester.getTopLeft(find.byType(TrackRailCard).first).dy -
        tester.getBottomLeft(find.text('Discover')).dy;
    expect(discoverGap, closeTo(quickGap, 0.5));
  });

  testWidgets('phone quick picks sit under the title and keep the last row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize);
    final state = await _boot(_ShortLibrary(songs: 9));
    // Pins count toward the slots and the row count too.
    state.togglePin(ShelfItem.song(state.liked.first));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump();

    final title = tester.getRect(find.text('Quick picks'));
    final grid = tester.getRect(find.byType(GridView));
    // The grid follows the heading by the shared section gap, the same
    // one every rail leaves, not after a taller block.
    expect(grid.top - title.bottom, closeTo(sectionHeaderGap, 4));

    // Every rendered card is inside the grid box: the last row is not
    // clipped by the grid's fixed height.
    final cards = find.byType(QuickPickCard);
    expect(cards, findsWidgets);
    for (var i = 0; i < cards.evaluate().length; i++) {
      final card = tester.getRect(cards.at(i));
      expect(card.bottom, lessThanOrEqualTo(grid.bottom + 0.5));
    }
    // The skeleton fills the phone grid: three rows of three.
    expect(cards, findsNWidgets(9));
    final first = tester.widget<QuickPickCard>(cards.first);
    expect(first.padding, EdgeInsets.zero);
    expect(first.borderRadius.topLeft, const Radius.circular(20));
    expect(first.borderRadius.topRight, const Radius.circular(4));
    final last = tester.widget<QuickPickCard>(cards.last);
    expect(last.borderRadius.bottomRight, const Radius.circular(20));
    expect(last.borderRadius.bottomLeft, const Radius.circular(4));
  });
}
