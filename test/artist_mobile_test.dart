// Tests for the mobile artist page: the collapsing banner hero stays
// (a bit shorter than on wide windows) with pill actions, compact
// top-song rows, the bio after the songs and the rails last.

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
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/detail_screen.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/artist_panel_mobile.dart';
import 'package:nixietube/ui/widgets/artwork_image.dart';
import 'package:nixietube/ui/widgets/detail_header.dart';
import 'package:nixietube/ui/widgets/track_row.dart';

class _ArtistTube extends InnerTube {
  @override
  Future<ArtistDetail?> artist(String browseId) async => _artist;
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
  subscribers: '1.24M subscribers',
  songsPlaylistId: 'VLtopSongs',
);

Future<AppState> _bootArtist(
  WidgetTester tester, {
  required Size size,
  bool signedIn = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final dir = Directory.systemTemp.createTempSync('nt-artist-mobile');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _ArtistTube();
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
  if (signedIn) state.testAccount = 'Tester';
  state.go(
    Screen.detail,
    detail: const BrowseItem(
      title: 'Test Artist',
      subtitle: 'Artist',
      browseId: 'UCtest',
      thumbnails: [],
    ),
  );
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return state;
}

double _heroHeight(WidgetTester tester) =>
    tester.widget<SliverAppBar>(find.byType(SliverAppBar)).expandedHeight!;

void main() {
  testWidgets('phone: shorter hero, compact panel with pill actions', (
    tester,
  ) async {
    await _bootArtist(tester, size: const Size(400, 800));

    // The collapsing banner hero stays on phones (no shared 56dp top
    // bar), rendered by the compact panel below it.
    expect(find.byType(SliverAppBar), findsOneWidget);
    expect(find.byType(DetailHeader), findsNothing);
    expect(find.byType(ArtistPanelMobile), findsOneWidget);

    // The hero carries the name and the raw subscriber count.
    expect(find.text('1.24M subscribers'), findsOneWidget);

    // Subscribe, Shuffle and Radio live in a single connected M3E button
    // group below the hero (no duplicate Subscribe pill in the hero), and
    // Play all sits in the Top songs header.
    expect(
      find.descendant(
        of: find.byType(SliverAppBar),
        matching: find.text('Subscribe'),
      ),
      findsNothing,
    );
    expect(find.byType(M3EToggleButtonGroup), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ArtistPanelMobile),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(ArtistPanelMobile),
        matching: find.byIcon(Icons.shuffle_rounded),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(ArtistPanelMobile),
        matching: find.byIcon(Icons.radio_rounded),
      ),
      findsWidgets,
    );
    expect(find.text('Play all'), findsWidgets);
    expect(find.text('Subscribe'), findsWidgets);

    // Top-song rows keep their cover thumbnail and the fixed index.
    expect(
      find.descendant(of: find.byType(TrackRow), matching: find.text('1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.byType(ArtworkImage),
      ),
      findsOneWidget,
    );
  });

  testWidgets('phone: the hero name is centred under the banner', (
    tester,
  ) async {
    await _bootArtist(tester, size: const Size(400, 800));

    Finder heroText(String text) => find.descendant(
      of: find.byType(SliverAppBar),
      matching: find.text(text),
    );
    // No subscribe pill on phones, so the name leads the hero: it sits in
    // the middle of the banner with the subscriber count under it.
    expect(
      tester.widget<Text>(heroText('Test Artist')).textAlign,
      TextAlign.center,
    );
    expect(
      tester.getRect(heroText('Test Artist')).center.dx,
      closeTo(200, 0.5),
    );
    expect(
      tester.widget<Text>(heroText('1.24M subscribers')).textAlign,
      TextAlign.center,
    );
    expect(
      tester.getRect(heroText('1.24M subscribers')).center.dx,
      closeTo(200, 0.5),
    );
  });

  testWidgets('phone: the Top songs header keeps its title left and the '
      'actions right', (tester) async {
    await _bootArtist(tester, size: const Size(400, 800));

    final title = tester.getRect(find.text('Top songs'));
    // The buttons' own boxes (their icon variants subclass M3EButton).
    Rect button(String label) => tester.getRect(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is M3EButton),
          )
          .first,
    );
    final seeAll = button('See all');
    final playAll = button('Play all');
    final row = tester.getRect(
      find
          .ancestor(of: find.text('Top songs'), matching: find.byType(Row))
          .first,
    );

    // The title keeps the left keyline...
    expect(title.left, closeTo(row.left, 0.5));
    // ...and both actions line up on the right edge, Play all last.
    expect(playAll.right, closeTo(row.right, 0.5));
    expect(seeAll.right, lessThan(playAll.left));
    // The title is not stretched to hold the buttons: it hugs its text.
    expect(title.width, lessThan(140));
    expect(
      find.ancestor(
        of: find.text('Top songs'),
        matching: find.byType(Expanded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('phone: the hero is shorter than on a wide window', (
    tester,
  ) async {
    await _bootArtist(tester, size: const Size(400, 800));
    final phoneHero = _heroHeight(tester);

    await _bootArtist(tester, size: const Size(1200, 800));
    final wideHero = _heroHeight(tester);

    expect(phoneHero, lessThan(wideHero));
  });

  testWidgets('phone: without an account the Subscribe pill is hidden', (
    tester,
  ) async {
    await _bootArtist(tester, size: const Size(400, 800), signedIn: false);

    expect(find.text('Subscribe'), findsNothing);
    expect(find.byIcon(Icons.shuffle_rounded), findsWidgets);
    expect(find.byIcon(Icons.radio_rounded), findsWidgets);
    expect(find.byType(M3EToggleButtonGroup), findsOneWidget);
  });

  testWidgets('wide: the hero name keeps the left keyline', (tester) async {
    await _bootArtist(tester, size: const Size(1200, 800));

    final name = find.descendant(
      of: find.byType(SliverAppBar),
      matching: find.text('Test Artist'),
    );
    expect(tester.widget<Text>(name).textAlign, isNull);
    expect(tester.getRect(name).left, closeTo(gutter, 0.5));
  });

  testWidgets('wide: full hero and the wide action row are kept', (
    tester,
  ) async {
    await _bootArtist(tester, size: const Size(1200, 800));

    expect(find.byType(SliverAppBar), findsOneWidget);
    expect(find.byType(ArtistPanelMobile), findsNothing);
    expect(find.text('Play all'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SliverAppBar),
        matching: find.text('Subscribe'),
      ),
      findsOneWidget,
    );
  });
}
