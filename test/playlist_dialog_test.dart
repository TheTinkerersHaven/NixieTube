// Regression test: the add-to-playlist dialog kept its
// loading indicator up forever. It only listened to the
// dialog track and the playlist list, neither of which
// changes when the per-playlist membership checks land —
// so the loading-flag flip never rebuilt the dialog.

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/gdata_api.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';
import 'package:nixietube/ui/widgets/playlist_dialog.dart';

class _FakeEngine implements PlayerEngine {
  @override
  Future<bool> play(String url) async => true;
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
  int durationMs() => 200000;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

class _FakeTube extends InnerTube {
  @override
  Future<({List<String> moods, List<Shelf> shelves})> home() async =>
      (shelves: <Shelf>[], moods: <String>[]);
  @override
  Future<List<Thumbnail>> playlistArtwork(
    String browseId, {
    String? params,
  }) async => [];
}

class _FakeGData extends GDataApi {
  _FakeGData() : super(tokenProvider: () async => 'tok');

  /// Held membership: the test releases the per-playlist
  /// checks deterministically instead of racing them.
  Completer<void>? membershipGate;

  final added = <String>[];

  @override
  Future<List<GPlaylist>> playlists() async => const [
        GPlaylist(
          id: 'pl1',
          title: 'Road Trip',
          itemCount: 12,
          art: 'https://x/a.jpg',
          arts: ['https://x/a.jpg'],
        ),
        GPlaylist(
          id: 'pl2',
          title: 'Gym',
          itemCount: 3,
          art: 'https://x/b.jpg',
          arts: ['https://x/b.jpg'],
        ),
      ];

  @override
  Future<List<Track>> recentActivity({int max = 30}) async => [];
  @override
  Future<List<ShelfItem>> subscriptions({int max = 50}) async => [];
  @override
  Future<List<Track>> likedVideos({int max = 2000}) async => [];
  @override
  Future<List<Track>> playlistTracks(
    String playlistId, {
    int max = 5000,
  }) async => [];
  @override
  Future<String?> channelAvatar() async => null;

  @override
  Future<String?> playlistItemId(String playlistId, String videoId) async {
    final gate = membershipGate;
    if (gate != null) await gate.future;
    return playlistId == 'pl1' ? 'item-1' : null;
  }

  @override
  Future<bool> addToPlaylist(String playlistId, String videoId) async {
    added.add('$playlistId:$videoId');
    return true;
  }

  @override
  Future<bool> removePlaylistItem(String itemId) async => true;
}

const _track = Track(videoId: 'v9', title: 'Nine', durationSec: 200);

void main() {
  testWidgets('membership load resolves the spinner into playlist rows',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('nt-pldialog-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tube = _FakeTube();
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
    // Test-only sign-in: reaches the signed-in dialog UI
    // without touching the real auth files or the network.
    final fake = _FakeGData();
    state.apiOverride = fake;
    state.testAccount = 'Tester';

    await state.loadLibrary();
    expect(
      state.playlists.where((p) => p.id != '__liked'),
      hasLength(2),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(body: PlaylistPickerDialog()),
        ),
      ),
    );
    expect(find.byType(M3ELoadingIndicator), findsNothing);

    // Hold the membership checks: the dialog must show the
    // spinner while they are in flight…
    fake.membershipGate = Completer<void>();
    final fut = state.openPlaylistDialog(_track);
    await tester.pump();
    expect(find.byType(M3ELoadingIndicator), findsOneWidget);
    expect(find.text('Road Trip'), findsNothing);

    // …and resolve into the rows once they land (before the
    // fix this second half never happened: the loading-flag
    // flip rebuilt nothing, so the spinner stayed forever).
    fake.membershipGate!.complete();
    await fut;
    await tester.pump();
    expect(find.byType(M3ELoadingIndicator), findsNothing);
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Gym'), findsOneWidget);
    final boxes =
        tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes, hasLength(2));
    expect(boxes[0].value, isTrue);
    expect(boxes[1].value, isFalse);

    // Toggling adds the track and flips the checkbox.
    await tester.tap(find.text('Gym'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.added, ['pl2:v9']);
    expect(
      tester.widgetList<Checkbox>(find.byType(Checkbox)).toList()[1].value,
      isTrue,
    );

    state.closePlaylistDialog();
    player.dispose();
    await tester.pump();
  });
}
