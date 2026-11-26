// Tests for the mobile album header spec: album track rows drop the
// repeated cover and album name and keep a single like toggle, and the
// detail top bar is a 56dp sliver whose title fades in with scroll.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/album_panel.dart';
import 'package:nixietube/ui/widgets/album_panel_mobile.dart';
import 'package:nixietube/ui/widgets/artwork_image.dart';
import 'package:nixietube/ui/widgets/detail_header.dart';
import 'package:nixietube/ui/widgets/track_row.dart';

class _QuietTube extends InnerTube {
  @override
  Future<Track> enrichTrack(Track track) async => track;
  @override
  Future<List<Track>> enrichTracks(
    List<Track> tracks, {
    int concurrency = 8,
  }) async => tracks;
  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
  @override
  Future<Map<String, RatingStatus>> ratings(
    List<String> videoIds, {
    int concurrency = 8,
  }) async => {};
  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async => [];
}

Future<AppState> _boot() async {
  final dir = Directory.systemTemp.createTempSync('nt-albumheader-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _QuietTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
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
  return state;
}

const _albumTrack = Track(
  videoId: 'v1',
  title: 'Song 1',
  artists: [ArtistRef('Some Artist')],
  album: AlbumRef('Some Album', browseId: 'MPRE1'),
  durationSec: 200,
);

void _phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() => tester.view.resetPhysicalSize);
}

void main() {
  testWidgets('album rows on a phone drop the cover and album name', (
    tester,
  ) async {
    _phoneView(tester);
    final state = await _boot();
    state.testAccount = 'Tester';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: const AlbumPlaylistView(
              title: 'Test Album',
              subtitle: '',
              description: '',
              art: null,
              owner: null,
              tracks: [_albumTrack],
              numbered: true,
              isAlbum: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlbumPlaylistViewMobile), findsOneWidget);
    // The hero card carries the stats line with the kind label; the
    // tracklist header repeats the bare count.
    expect(find.text('Album • 1 songs • 3:20'), findsOneWidget);
    expect(find.text('1 songs'), findsOneWidget);
    // No artwork inside the row (the hero card owns the cover), a
    // fixed 28dp index, and no repeated album name in the subtitle.
    expect(
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.byType(ArtworkImage),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 28 && w.child is Text,
        ),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Some Album'), findsNothing);
    // Duration folded into the subtitle on phones.
    expect(find.textContaining('Some Artist • 3:20'), findsOneWidget);
    // Signed in: like and dislike toggles both stay in the row.
    expect(
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.byIcon(Icons.thumb_up_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.byIcon(Icons.thumb_down_outlined),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact rows pad the left side to match the trailing buttons', (
    tester,
  ) async {
    _phoneView(tester);
    final state = await _boot();
    state.testAccount = 'Tester';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: TrackRow(
              track: _albumTrack,
              onPlay: () {},
              rateable: true,
              showPlaylists: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byType(TrackRow);
    final rowRect = tester.getRect(row);
    // The trailing icon buttons carry 12dp of icon inset; the row pads
    // its left side by the same amount so content sits evenly.
    final tile = find.descendant(of: row, matching: find.byType(ListTile));
    expect(
      tester.widget<ListTile>(tile).contentPadding,
      const EdgeInsets.only(left: 12),
    );
    final art = find.descendant(of: row, matching: find.byType(ArtworkImage));
    final artRect = tester.getRect(art);
    expect(artRect.left - rowRect.left, 12.0);
    final dislikeIcon = find.descendant(
      of: row,
      matching: find.byIcon(Icons.thumb_down_outlined),
    );
    final iconRect = tester.getRect(dislikeIcon);
    expect(rowRect.right - iconRect.right, 12.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-album rows keep artwork and album subtitle', (tester) async {
    _phoneView(tester);
    final state = await _boot();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: const AlbumPlaylistView(
              title: 'My Playlist',
              subtitle: '',
              description: '',
              art: null,
              owner: null,
              tracks: [_albumTrack],
              numbered: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Playlist • 1 songs • 3:20'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.byType(ArtworkImage),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Some Album'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail top bar is 56dp and its title fades in with scroll', (
    tester,
  ) async {
    _phoneView(tester);
    final pixels = ValueNotifier<double>(0);
    addTearDown(pixels.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DetailHeader(title: 'Album X', scrollPixels: pixels),
        ),
      ),
    );
    await tester.pump();

    // Fixed 56dp app bar on phones.
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.height == 56),
      findsOneWidget,
    );
    Finder opacityOfTitle() => find.descendant(
      of: find.byType(DetailHeader),
      matching: find.byType(Opacity),
    );
    // Hero visible at rest: title hidden.
    expect(tester.widget<Opacity>(opacityOfTitle()).opacity, 0.0);
    expect(find.text('Album X'), findsOneWidget);

    pixels.value = 50;
    await tester.pump();
    expect(tester.widget<Opacity>(opacityOfTitle()).opacity, 0.5);

    pixels.value = 150;
    await tester.pump();
    expect(tester.widget<Opacity>(opacityOfTitle()).opacity, 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail top bar keeps its title without a scroll source', (
    tester,
  ) async {
    _phoneView(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DetailHeader(title: 'Album X'))),
    );
    await tester.pump();
    expect(find.text('Album X'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailHeader),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
