// Tests for the album info dialog: the facts it lists (year, type,
// tracks, artist) and the empty state when an album carries nothing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/sys/lastfm.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/widgets/album_info.dart';
import 'package:provider/provider.dart';

import 'mock_dio.dart';

/// A config in a temp dir with no credentials, so every lookup the
/// service attempts is scripted by [mockDio].
SysConfig _emptyConfig() {
  final dir = Directory.systemTemp.createTempSync('nixie_album_info');
  addTearDown(() => dir.deleteSync(recursive: true));
  return SysConfig(configPath: '${dir.path}/config.properties');
}

void main() {
  final album = AlbumDetail(
    title: 'Random Access Memories',
    subtitle: 'Album · Daft Punk · 2013',
    description: 'The fourth studio album by Daft Punk.',
    thumbnails: const [],
    tracks: const [
      Track(videoId: 'a', title: 'One', durationSec: 60),
      Track(videoId: 'b', title: 'Two', durationSec: 90),
    ],
    kind: ReleaseKind.album,
    year: '2013',
    artist: const ArtistRef('Daft Punk', browseId: 'UCdaft'),
  );

  testWidgets('album facts render', (tester) async {
    // A LastFmService with no config/session: the lookup returns null,
    // so the dialog renders its facts without any real network.
    final dir = Directory.systemTemp.createTempSync('nixie_album_info');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lastfm = LastFmService(
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      dio: mockDio((options) async => (404, '')),
    );
    addTearDown(lastfm.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<LastFmService>.value(
        value: lastfm,
        child: MaterialApp(
          home: Scaffold(
            body: AlbumInfoView(album: album, artist: album.artist),
          ),
        ),
      ),
    );
    await tester.pump();
    // Let the (failing) Last.fm lookup settle.
    await tester.pump(const Duration(milliseconds: 50));

    // YouTube Music description as the About section.
    expect(find.text('About'), findsOneWidget);
    expect(find.text('The fourth studio album by Daft Punk.'), findsOneWidget);
    // Facts: each row appears exactly once (no header duplication).
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('2013'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('2 songs · 2 min'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Daft Punk'), findsOneWidget);
  });

  testWidgets('facts render once when the Last.fm lookup completes', (
    tester,
  ) async {
    // A Dio whose handler blocks until the test unblocks it: the album
    // facts render while the lookup is pending, then the rebuild that
    // applies the (empty) Last.fm snapshot must not re-append them.
    final pending = Completer<void>();
    final dio = mockDio((options) async {
      await pending.future;
      return (200, '{}');
    });
    final dir = Directory.systemTemp.createTempSync('nixie_album_info');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lastfm = LastFmService(
      config: SysConfig(configPath: '${dir.path}/config.properties'),
      dio: dio,
    );
    addTearDown(lastfm.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<LastFmService>.value(
        value: lastfm,
        child: MaterialApp(
          home: Scaffold(
            body: AlbumInfoView(album: album, artist: album.artist),
          ),
        ),
      ),
    );
    await tester.pump();
    // The album facts render while the lookup is pending.
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('2 songs · 2 min'), findsOneWidget);

    // Unblock the lookup; the rebuild must not duplicate the facts.
    pending.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('2 songs · 2 min'), findsOneWidget);
  });

  testWidgets('album without any metadata falls back to empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlbumInfoView(
            album: AlbumDetail(
              title: 'Mystery',
              subtitle: '',
              description: '',
              thumbnails: const [],
              tracks: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('No info available.'), findsOneWidget);
  });

  testWidgets('Last.fm summary and tags render once the lookup lands', (
    tester,
  ) async {
    // An album with no YouTube Music description relies on Last.fm for
    // its About section; the summary and tags must appear exactly once
    // after the snapshot lands, not once per rebuild.
    final lastfm = LastFmService(
      config: _emptyConfig(),
      dio: mockDio((options) async {
        return (
          200,
          jsonEncode({
            'album': {
              'wiki': {'summary': 'A landmark record.'},
              'tags': {'tag': [{'name': 'electronic'}, {'name': 'disco'}]},
            },
          }),
        );
      }),
    );
    addTearDown(lastfm.dispose);

    final bare = AlbumDetail(
      title: 'Random Access Memories',
      subtitle: 'Album · Daft Punk · 2013',
      description: '',
      thumbnails: const [],
      tracks: const [Track(videoId: 'a', title: 'One', durationSec: 60)],
      kind: ReleaseKind.album,
      year: '2013',
      artist: const ArtistRef('Daft Punk', browseId: 'UCdaft'),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<LastFmService>.value(
        value: lastfm,
        child: MaterialApp(
          home: Scaffold(
            body: AlbumInfoView(album: bare, artist: bare.artist),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The Last.fm summary is the About section, and both it and the tag
    // row appear exactly once.
    expect(find.text('A landmark record.'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Tags'), findsOneWidget);
    expect(find.text('electronic, disco'), findsOneWidget);
    // The facts are still single after the rebuild.
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
  });
}
