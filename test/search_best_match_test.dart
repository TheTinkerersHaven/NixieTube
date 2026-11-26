// Tests for the search "best match" card: the top-result card shelf's
// entity is shown as a prominent card above the categories on the All
// tab, and tapping it plays (song) — while a category filter hides it.

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/screens/search_screen.dart';
import 'package:nixietube/ui/widgets/artwork_image.dart';

class _CardTube extends FakeTube {
  @override
  Future<SearchResults> search(String query, {String? filter}) async {
    return SearchResults(
      sections: {
        'Songs': [
          SongItem(
            Track(
              videoId: 'VID1',
              title: 'Other Song',
              artists: const [ArtistRef('Ivycomb')],
              durationSec: 200,
            ),
          ),
        ],
      },
      bestMatch: SongItem(
        Track(
          videoId: 'VID9',
          title: 'Kid Again, A Much Longer Song Title For Testing',
          artists: const [ArtistRef('Ivycomb', browseId: 'UCARTIST')],
          album: const AlbumRef('Kid Again', browseId: 'MPREALBUM'),
          durationSec: 225,
          thumbnails: const [
            Thumbnail('https://img/frame.jpg', width: 1280, height: 720),
            Thumbnail('https://img/cover.jpg', width: 544, height: 544),
          ],
        ),
      ),
    );
  }

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async => [];
}

Future<void> _pumpSearch(WidgetTester tester, AppState state) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider.value(
          value: state,
          child: const SearchScreen(),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the best match card leads the All results and plays on tap', (
    tester,
  ) async {
    final state = await bootAppState(tester, tube: _CardTube());
    await _pumpSearch(tester, state);

    await state.searchFor('kid again');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Best match'), findsOneWidget);
    final title = find.text('Kid Again, A Much Longer Song Title For Testing');
    expect(title, findsOneWidget);
    expect(tester.widget<Text>(title).maxLines, 2);
    expect(find.text('Ivycomb • Kid Again • 3:45'), findsOneWidget);
    // The card block carries top padding so it clears the filter chips.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Padding && w.padding == const EdgeInsets.fromLTRB(4, 24, 4, 0),
      ),
      findsOneWidget,
    );
    final art = tester.widget<ArtworkImage>(
      find.byWidgetPredicate(
        (w) => w is ArtworkImage && w.url == 'https://img/cover.jpg',
      ),
    );
    expect(art.size, 96);
    expect(art.url, 'https://img/cover.jpg');
    // The category section still renders below ('Songs' also matches the
    // filter chip, so assert on the row instead).
    expect(find.text('Other Song'), findsOneWidget);

    // Tapping the card plays the best match as its own station.
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.player.state.current?.videoId, 'VID9');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a category filter hides the best match card', (tester) async {
    final state = await bootAppState(tester, tube: _CardTube());
    await _pumpSearch(tester, state);

    await state.searchFor('kid again');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Best match'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Songs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Best match'), findsNothing);
    expect(find.text('Other Song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
