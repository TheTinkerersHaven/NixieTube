// The album/playlist view's top-right ⋮ uses the same popup-menu component
// as the playlist header, with actions for the open list.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/theme.dart';

class _AlbumTube extends InnerTube {
  @override
  Future<AlbumDetail?> album(String browseId) async => AlbumDetail(
    title: 'Album',
    subtitle: 'Artist',
    description: 'A great album about things.',
    thumbnails: const [],
    tracks: const [Track(videoId: 't1', title: 'One', durationSec: 100)],
    artist: const ArtistRef('Artist', browseId: 'UCartist'),
  );
}

void main() {
  testWidgets('album view menu offers the popup actions', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-detail-menu-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = _AlbumTube();
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
    final lastfm = LastFmService(config: state.config);
    addTearDown(lastfm.dispose);
    state.go(
      Screen.detail,
      detail: const BrowseItem(
        title: 'Album',
        subtitle: 'Artist',
        browseId: 'MPREb_album',
        thumbnails: [],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ChangeNotifierProvider.value(
            value: state,
            child: ChangeNotifierProvider.value(
              value: lastfm,
              child: const DetailScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byWidgetPredicate((w) => w is M3EPopupMenuButton),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Album info'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.text('Shuffle'), findsNothing);
    expect(find.text('Play all'), findsNothing);

    await tester.tap(find.text('Album info'));
    await tester.pump();
    await tester.pumpAndSettle();

    // The description shows both in the page header and the dialog; the
    // dialog's copy is the second one in the tree.
    expect(find.text('A great album about things.'), findsNWidgets(2));
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pumpAndSettle();

    state.player.dispose();
    await tester.pump();
  });
}
