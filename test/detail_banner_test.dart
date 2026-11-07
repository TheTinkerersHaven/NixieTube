// Tests for the artist hero banner loading state: while the banner
// bytes resolve, a shimmer bone fills the hero box (mirroring
// ArtworkImage) instead of a flat box, so the image never pops in.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/theme.dart';

void main() {
  testWidgets('hero banner bones while loading', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-banner-test');
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
    // Unreachable host: the download refuses fast, so the bone is
    // observable on the first pump and the settle completes.
    const artist = ArtistDetail(
      name: 'Test Artist',
      description: '',
      thumbnails: [Thumbnail('http://127.0.0.1:9/banner.jpg')],
      topSongs: [],
      albums: [],
    );
    state.detail = DetailUiState(loading: false, artist: artist);
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
    expect(find.byWidgetPredicate((w) => w is Bone), findsOneWidget);
    // No settle: the assertion targets the loading state itself, and
    // the refused download resolves on real (not fake) time.
  });
}
