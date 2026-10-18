// Regression tests for the open-playlist load race: opening playlist
// B while A still loads (or closing A mid-load) must keep A's late
// tracks from popping over the new view (or reopening the closed one).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/gdata_api.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

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
  Future<List<Track>> enrichTracks(
    List<Track> tracks, {
    int concurrency = 8,
  }) async => tracks;
  @override
  Future<Map<String, RatingStatus>> ratings(
    List<String> videoIds, {
    int concurrency = 8,
  }) async => {};
  @override
  Future<Map<String, ({RatingStatus rating, Map<String, int> durations})>>
  watchInfos(List<String> videoIds, {int concurrency = 8}) async => {};
  @override
  Future<Track> enrichTrack(Track track) async => track;
  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;
}

/// Data API double with gated per-playlist track fetches.
class _GatedGData extends GDataApi {
  _GatedGData() : super(tokenProvider: () async => 'tok');

  final gates = <String, Completer<List<Track>>>{};

  @override
  Future<List<GPlaylist>> playlists() async => [];
  @override
  Future<List<Track>> recentActivity({int max = 30}) async => [];
  @override
  Future<List<ShelfItem>> subscriptions({int max = 50}) async => [];
  @override
  Future<List<Track>> likedVideos({int max = 2000}) async => [];
  @override
  Future<List<Track>> playlistTracks(String playlistId, {int max = 5000}) =>
      (gates[playlistId] ??= Completer<List<Track>>()).future;
  @override
  Future<String?> channelAvatar() async => null;
}

Track _track(String id) => Track(
  videoId: id,
  title: 'Title $id',
  artists: [ArtistRef('Artist $id', browseId: 'UC$id')],
  durationSec: 200,
);

const _plA = GPlaylist(id: 'plA', title: 'A', itemCount: 1);
const _plB = GPlaylist(id: 'plB', title: 'B', itemCount: 1);

Future<({AppState state, _GatedGData api})> _boot() async {
  final dir = Directory.systemTemp.createTempSync('nt-plrace-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _QuietTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: _FakeEngine(),
    tube: tube,
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
  final api = _GatedGData();
  state.apiOverride = api;
  state.testAccount = 'Tester';
  return (state: state, api: api);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('stale playlist load cannot pop over the new one', () async {
    final env = await _boot();
    final state = env.state;
    final api = env.api;
    api.gates['plA'] = Completer<List<Track>>();
    api.gates['plB'] = Completer<List<Track>>();

    unawaited(state.openPlaylist(_plA));
    await _settle();
    expect(state.openedPlaylist?.playlist.id, 'plA');
    expect(state.openedPlaylist?.tracks, isEmpty);

    unawaited(state.openPlaylist(_plB));
    await _settle();
    expect(state.openedPlaylist?.playlist.id, 'plB');
    expect(state.openedPlaylist?.tracks, isEmpty);

    // A lands late: dropped, and B keeps its spinner.
    api.gates['plA']!.complete([_track('a1')]);
    await _settle();
    expect(state.openedPlaylist?.playlist.id, 'plB');
    expect(state.openedPlaylist?.tracks, isEmpty);
    expect(state.libraryLoading, isTrue);

    api.gates['plB']!.complete([_track('b1')]);
    await _settle();
    expect(state.openedPlaylist?.playlist.id, 'plB');
    expect(state.openedPlaylist!.tracks.map((t) => t.videoId), ['b1']);
    expect(state.libraryLoading, isFalse);
  });

  test('closing mid-load drops the landing tracks', () async {
    final env = await _boot();
    final state = env.state;
    final api = env.api;
    api.gates['plA'] = Completer<List<Track>>();

    unawaited(state.openPlaylist(_plA));
    await _settle();
    expect(state.openedPlaylist?.playlist.id, 'plA');

    state.closePlaylist();
    expect(state.openedPlaylist, isNull);

    api.gates['plA']!.complete([_track('a1')]);
    await _settle();
    // The closed view must not reopen by itself.
    expect(state.openedPlaylist, isNull);
  });
}
