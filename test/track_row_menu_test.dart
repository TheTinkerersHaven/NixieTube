// Tests for the track row overflow menu: the ⋮ button and
// right-click open the same spring menu, and Play next enqueues.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/track_row.dart';

class _FakeEngine implements PlayerEngine {
  @override
  Future<String?> play(String url) async => null;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seekTo(int ms) async {}
  @override
  Future<void> setVolume(int volume) async {}
  @override
  int positionMs() => 0;
  @override
  int durationMs() => 0;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

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

const _track = Track(videoId: 'v1', title: 'One', durationSec: 200);

Future<AppState> _boot() async {
  final dir = Directory.systemTemp.createTempSync('nt-rowmenu-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _QuietTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 1),
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final oauth = GoogleOAuth(storePath: '${dir.path}/oauth.properties');
  addTearDown(oauth.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    oauth: oauth,
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  return state;
}

Future<void> _pumpRow(WidgetTester tester, AppState state, [Track? track]) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider.value(
          value: state,
          child: TrackRow(
            track: track ?? _track,
            onPlay: () {},
            showPlaylists: true,
          ),
        ),
      ),
    ),
  );
}

/// Pumps until any background lyrics fetch settles (bounded), keeping
/// the fake clock moving — bare [Future.delayed] would hang forever.
Future<void> drainLyrics(WidgetTester tester, AppState state) async {
  for (var i = 0; i < 50 && !state.lyricsLoading; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  for (var i = 0; i < 200 && state.lyricsLoading; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('overflow button opens the spring menu', (tester) async {
    final state = await _boot();
    await _pumpRow(tester, state);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Add to playlist'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('Play next enqueues with feedback', (tester) async {
    final state = await _boot();
    await _pumpRow(tester, state);
    // Open the menu while idle (springs settle on real time; the
    // live position ticker would hang pumpAndSettle once playing).
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    // Something already playing: Play next queues behind it.
    state.player.playTracks([
      const Track(videoId: 'v0', title: 'Zero', durationSec: 200),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Play next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(state.player.state.queue.map((t) => t.videoId).toList(), [
      'v0',
      'v1',
    ]);
    expect(find.text('Queued next'), findsOneWidget);
    // Playback fires a background lyrics fetch; drain it with pumps
    // (bare delays never advance the fake clock) so teardown never
    // races a post-dispose notify.
    await drainLyrics(tester, state);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('Play next with nothing loaded just plays', (tester) async {
    final state = await _boot();
    await _pumpRow(tester, state);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.player.state.current?.videoId, 'v1');
    expect(find.text('Queued next'), findsNothing);
    await drainLyrics(tester, state);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('right-click opens the same menu', (tester) async {
    final state = await _boot();
    await _pumpRow(tester, state);
    final center = tester.getCenter(find.byType(TrackRow));
    final gesture = await tester.startGesture(
      center,
      buttons: kSecondaryMouseButton,
    );
    addTearDown(gesture.removePointer);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('explicit badge shows before the artist name', (tester) async {
    const flagged = Track(
      videoId: 'e1',
      title: 'Bold Song',
      artists: [ArtistRef('Loud Act')],
      explicit: true,
    );
    final state = await _boot();
    await _pumpRow(tester, state, flagged);
    await tester.pump();
    expect(find.byIcon(Icons.explicit), findsOneWidget);
    state.player.dispose();
    await tester.pump();
  });

  testWidgets('clean tracks show no badge', (tester) async {
    final state = await _boot();
    await _pumpRow(tester, state);
    await tester.pump();
    expect(find.byIcon(Icons.explicit), findsNothing);
    state.player.dispose();
    await tester.pump();
  });
}
