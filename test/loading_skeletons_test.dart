// Loading-skeleton tests: lyrics fetching, album/playlist detail
// loading and the library open-playlist list shimmer placeholder
// rows in place instead of spinning. Shimmer repeats forever, so
// these tests use bounded pumps only — never pumpAndSettle.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/screens/now_playing_screen.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/album_panel.dart';
import 'package:nixietube/ui/widgets/loading_placeholders.dart';
import 'package:nixietube/ui/widgets/lyrics_list.dart';
import 'package:nixietube/ui/widgets/track_row.dart';


/// InnerTube with held detail fetches: tests release the
/// background load deterministically instead of racing it.
class _GatedTube extends InnerTube {
  Completer<AlbumDetail?> albumGate = Completer();
  Completer<ArtistDetail?> artistGate = Completer();

  @override
  Future<AlbumDetail?> album(String browseId) => albumGate.future;

  @override
  Future<ArtistDetail?> artist(String browseId) => artistGate.future;
}

class _QuietTube extends InnerTube {
  @override
  Future<Track> enrichTrack(Track track) async => track;
  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}

/// Boots a real [AppState] over [tube] with temp dirs.
Future<({AppState state, T tube})> _boot<T extends InnerTube>(
  WidgetTester tester,
  T tube, {
  Future<ResolvedStream> Function(String)? resolveStream,
}) async {
  final dir = Directory.systemTemp.createTempSync('nt-skeleton-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    resolveStream:
        resolveStream ??
        (id) async => ResolvedStream(url: 'https://x/$id', bitrate: 1),
    configDirPath: dir.path,
  );
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
  return (state: state, tube: tube);
}

Future<void> _pumpUnder(WidgetTester tester, AppState state, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ChangeNotifierProvider.value(value: state, child: child),
      ),
    ),
  );
}

/// Enabled skeleton scopes only (tiles also wrap themselves in
/// disabled scopes while settled).
Finder _enabledSkeletons() =>
    find.byWidgetPredicate((w) => w is Skeletonizer && w.enabled);

void main() {
  testWidgets('open-playlist list loading shimmers skeleton rows', (
    tester,
  ) async {
    // Tall viewport: ListView.builder only mounts visible
    // rows, and all 8 placeholders must exist to count them.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final env = await _boot(tester, InnerTube());
    await _pumpUnder(
      tester,
      env.state,
      const AlbumPlaylistView(
        title: 'Playlist',
        subtitle: '',
        description: '',
        art: null,
        owner: null,
        tracks: [],
        numbered: false,
        listLoading: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(M3ELoadingIndicator), findsNothing);
    expect(find.byType(TrackRow), findsNWidgets(placeholderTracks.length));
    expect(_enabledSkeletons(), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('album detail loading shimmers, then reveals in place', (
    tester,
  ) async {
    // Tall viewport: see above.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final env = await _boot(tester, _GatedTube());
    await _pumpUnder(tester, env.state, const DetailScreen());
    env.state.go(
      Screen.detail,
      detail: const BrowseItem(
        title: 'Album',
        subtitle: '',
        browseId: 'MPREabc',
        thumbnails: [],
      ),
    );
    await tester.pump();
    // Songs on their way: skeleton rows, no spinner.
    expect(find.byType(M3ELoadingIndicator), findsNothing);
    expect(find.byType(TrackRow), findsNWidgets(placeholderTracks.length));
    expect(_enabledSkeletons(), findsOneWidget);

    // The fetch lands: the real song replaces the placeholders.
    env.tube.albumGate.complete(
      const AlbumDetail(
        title: 'Real Album',
        subtitle: '',
        description: '',
        thumbnails: [],
        tracks: [Track(videoId: 'r1', title: 'Real Song', durationSec: 120)],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Real Song'), findsOneWidget);
    expect(find.byType(TrackRow), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('artist detail loading shimmers, then reveals in place', (
    tester,
  ) async {
    // Tall viewport: see above.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final env = await _boot(tester, _GatedTube());
    await _pumpUnder(tester, env.state, const DetailScreen());
    env.state.go(
      Screen.detail,
      detail: const BrowseItem(
        title: 'Artist',
        subtitle: '',
        browseId: 'UC123',
        thumbnails: [],
      ),
    );
    await tester.pump();
    // Songs/rails on their way: skeleton layout, no spinner.
    expect(find.byType(M3ELoadingIndicator), findsNothing);
    expect(find.text('Top songs'), findsOneWidget);
    expect(find.byType(TrackRow), findsNWidgets(placeholderTracks.length));
    expect(_enabledSkeletons(), findsOneWidget);

    // The fetch lands: the real artist replaces the placeholders.
    env.tube.artistGate.complete(
      const ArtistDetail(
        name: 'Real Artist',
        description: '',
        thumbnails: [],
        topSongs: [Track(videoId: 'r1', title: 'Real Song', durationSec: 120)],
        albums: [],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Real Artist'), findsOneWidget);
    expect(find.text('Real Song'), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('placeholder lyrics render shimmer rows', (tester) async {
    final env = await _boot(tester, InnerTube());
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    await _pumpUnder(
      tester,
      env.state,
      Skeletonizer(
        enabled: true,
        child: LyricsList(
          ctrl: ctrl,
          lyrics: placeholderLyrics,
          positionMs: 0,
          state: env.state,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // One row per placeholder line, none highlighted.
    expect(find.byType(InkWell), findsNWidgets(placeholderLyrics.length));
    expect(_enabledSkeletons(), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });

  testWidgets('failed lyrics fetch settles on "No lyrics found"', (
    tester,
  ) async {
    final env = await _boot(tester, _QuietTube());
    await _pumpUnder(tester, env.state, const NowPlayingScreen());
    env.state.player.playTracks([
      const Track(videoId: 'v1', title: 'One', durationSec: 200),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Stage the tabs past the Now Playing transition, then open
    // the Lyrics tab.
    env.state.openNow();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Lyrics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The failed fetch clears the flag instead of sticking on
    // the skeleton: the empty state shows the static note.
    expect(env.state.lyricsLoading, isFalse);
    expect(env.state.lyrics, isEmpty);
    expect(find.text('No lyrics found'), findsOneWidget);
    env.state.player.dispose();
    await tester.pump();
  });
}
