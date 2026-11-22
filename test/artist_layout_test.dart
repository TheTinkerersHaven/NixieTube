// Artist page reading order: on a phone the bio ("About") comes after
// every rail, while a wide window keeps it beside the top songs.

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
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/theme.dart';

/// Boots an [AppState] whose detail is already a loaded [artist].
Future<void> _pumpArtist(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final dir = Directory.systemTemp.createTempSync('nt-artist-layout');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final state = AppState(
    tube: tube,
    player: player,
    art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  state.detail = DetailUiState(loading: false, artist: _artist);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ChangeNotifierProvider.value(
          value: state,
          child: const DetailScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _railItem = BrowseItem(
  title: 'Rail item',
  subtitle: 'Artist',
  browseId: 'rail-1',
  thumbnails: [],
);

const _artist = ArtistDetail(
  name: 'Test Artist',
  description: 'A short biography.',
  thumbnails: [],
  topSongs: [Track(videoId: 'v1', title: 'Song', durationSec: 120)],
  albums: [_railItem],
  singlesAndEps: [_railItem],
  relatedPlaylists: [_railItem],
  similarArtists: [_railItem],
);

double _topOf(WidgetTester tester, String label) =>
    tester.getTopLeft(find.text(label)).dy;

void main() {
  testWidgets('phone: the About card renders after the last rail', (
    tester,
  ) async {
    await _pumpArtist(tester, size: const Size(400, 4000));

    final aboutY = _topOf(tester, 'About');
    expect(aboutY, greaterThan(_topOf(tester, 'Similar artists')));
  });

  testWidgets('wide: the About card renders before the rails', (tester) async {
    await _pumpArtist(tester, size: const Size(1200, 4000));

    final aboutY = _topOf(tester, 'About');
    expect(aboutY, lessThan(_topOf(tester, 'Albums')));
  });
}