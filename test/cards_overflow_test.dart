// Regression: rail cards sit in a fixed-height rail (206dp on phones),
// and their art + two text lines used to overflow that by a pixel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/artwork_image.dart';
import 'package:nixietube/ui/widgets/cards.dart';
import 'package:nixietube/ui/widgets/rails.dart';

const _compactMedia = MediaQueryData(size: Size(400, 800));

void main() {
  testWidgets('compact track rail card fits the fixed rail height', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('nt-card-overflow');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
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

    const track = Track(
      videoId: 'v1',
      title: 'A very long song title that wraps onto two lines inside the card',
      artists: [ArtistRef('Some Artist With A Long Name')],
      durationSec: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: _compactMedia,
          child: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: Center(
                // The compact rail's fixed box: 160dp card in a 206dp rail.
                child: SizedBox(
                  height: compactRailHeight,
                  child: TrackRailCard(
                    track: track,
                    onTap: () {},
                    width: compactRailCardWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact browse card fits the fixed rail height', (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-card-overflow-b');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
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

    const item = BrowseItem(
      title: 'A very long playlist title that wraps onto two lines',
      subtitle: 'Playlist • 123 songs',
      browseId: 'VLxyz',
      thumbnails: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: _compactMedia,
          child: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: Center(
                child: SizedBox(
                  height: compactRailHeight,
                  child: BrowseCard(
                    item: item,
                    onTap: () {},
                    width: compactRailCardWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rail cards share one height whatever the title length', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('nt-card-uniform');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
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

    const shortTrack = Track(
      videoId: 'v1',
      title: 'Tiny',
      artists: [ArtistRef('A')],
      durationSec: 200,
    );
    const longTrack = Track(
      videoId: 'v2',
      title: 'A very long song title that wraps onto two lines in the card',
      artists: [ArtistRef('Another Artist With A Name')],
      durationSec: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: Center(
                child: SizedBox(
                  height: compactRailHeight,
                  child: Row(
                    children: [
                      TrackRailCard(
                        track: shortTrack,
                        onTap: () {},
                        width: 160,
                      ),
                      TrackRailCard(track: longTrack, onTap: () {}, width: 160),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    // Both cards fill the rail's full height and their art, titles and
    // subtitles sit at identical offsets: single-line texts make every
    // card the same height whatever the title length.
    bool isCardTrack(Widget w, String id) =>
        w is TrackRailCard && w.track.videoId == id;

    Rect? firstTitle;
    for (final id in ['v1', 'v2']) {
      final cardRect = tester.getRect(
        find.byWidgetPredicate((w) => isCardTrack(w, id)),
      );
      expect(cardRect.height, compactRailHeight);
      final artRect = tester.getRect(
        find.descendant(
          of: find.byWidgetPredicate((w) => isCardTrack(w, id)),
          matching: find.byType(ArtworkImage),
        ),
      );
      // The art fills the card's inner width, leaving no dead space
      // beside a cover inside its card.
      expect(artRect.width, compactRailCardWidth - 4.0);
      expect(artRect.right, cardRect.right - 2.0);
      final titleRect = tester.getRect(
        find.text(id == 'v1' ? 'Tiny' : longTrack.title),
      );
      expect(titleRect.top, artRect.bottom + 8.0);
      firstTitle ??= titleRect;
      expect(titleRect.top, firstTitle.top);
      expect(titleRect.height, firstTitle.height);
    }
  });

  testWidgets('compact rail gaps are the whole space between covers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('nt-rail-gap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = FakeTube();
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

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: _compactMedia,
          child: Scaffold(
            body: ChangeNotifierProvider.value(
              value: state,
              child: CardRail(
                title: 'Albums',
                itemCount: 3,
                itemBuilder: (context, i, width) => BrowseCard(
                  item: BrowseItem(
                    title: 'Album $i',
                    subtitle: 'Album \u2022 10 songs',
                    browseId: 'MPREb$i',
                    thumbnails: const [],
                  ),
                  width: width,
                  contextMenu: false,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Cards sit one gap apart, and the only thing between two covers is
    // that gap plus the 2dp each card keeps for its ink well.
    final firstCard = tester.getRect(find.byType(BrowseCard).at(0));
    final secondCard = tester.getRect(find.byType(BrowseCard).at(1));
    expect(secondCard.left - firstCard.right, compactRailGap);
    final firstArt = tester.getRect(find.byType(ArtworkImage).at(0));
    final secondArt = tester.getRect(find.byType(ArtworkImage).at(1));
    expect(secondArt.left - firstArt.right, compactRailGap + 4.0);
  });
}
