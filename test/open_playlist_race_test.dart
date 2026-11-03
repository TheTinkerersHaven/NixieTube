// Regression tests for the open-playlist load race: opening playlist
// B while A still loads (or closing A mid-load) must keep A's late
// tracks from popping over the new view (or reopening the closed one).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/account_library.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';


class _QuietTube extends InnerTube {
  PlaylistDetail? playlistDetail;

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
  @override
  Future<PlaylistDetail?> playlist(String browseId, {String? params}) async =>
      playlistDetail;
}

/// Library double with gated per-playlist track fetches.
class _GatedLibrary extends AccountLibrary {
  _GatedLibrary();

  final gates = <String, Completer<List<Track>>>{};

  @override
  Future<List<AccountPlaylist>> playlists() async => [];
  @override
  Future<List<Track>> recentActivity({int max = 30}) async => [];
  @override
  Future<List<BrowseItem>> subscriptions({int max = 50}) async => [];
  @override
  Future<List<Track>> likedVideos({int max = 2000}) async => [];
  @override
  Future<List<Track>> playlistTracks(String playlistId, {int max = 5000}) =>
      (gates[playlistId] ??= Completer<List<Track>>()).future;
  @override
  Future<String?> accountAvatar() async => null;
}

Track _track(String id) => Track(
  videoId: id,
  title: 'Title $id',
  artists: [ArtistRef('Artist $id', browseId: 'UC$id')],
  durationSec: 200,
);

const _plA = AccountPlaylist(id: 'plA', title: 'A', itemCount: 1);
const _plB = AccountPlaylist(id: 'plB', title: 'B', itemCount: 1);

Future<({AppState state, _GatedLibrary api, _QuietTube tube})> _boot() async {
  final dir = Directory.systemTemp.createTempSync('nt-plrace-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _QuietTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(state.dispose);
  final api = _GatedLibrary();
  state.libraryOverride = api;
  state.testAccount = 'Tester';
  return (state: state, api: api, tube: tube);
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

  test('any surface opens the same playlist view', () async {
    final env = await _boot();
    final state = env.state;
    final api = env.api;
    env.tube.playlistDetail = const PlaylistDetail(
      title: 'Road trip',
      subtitle: 'Playlist • 3 songs',
      thumbnails: [
        Thumbnail('https://x/art.jpg', width: 640, height: 640),
      ],
      tracks: [],
      author: ArtistRef('Creator', browseId: 'UCC'),
      id: 'PLabc',
      editable: false,
    );
    api.gates['PLabc'] = Completer<List<Track>>();

    // A `VL…` browse id from home resolves to the same raw playlist id
    // as the library entry would.
    state.openPlaylistById(
      'VLPLabc',
      item: const BrowseItem(
        title: 'Road trip',
        subtitle: 'Playlist',
        browseId: 'VLPLabc',
        thumbnails: [],
      ),
    );
    await _settle();

    // The one playlist view hosts it, with the page's own metadata.
    expect(state.screen, Screen.library);
    expect(state.openedPlaylist?.playlist.id, 'PLabc');
    expect(state.openedPlaylist?.playlist.title, 'Road trip');

    api.gates['PLabc']!.complete([_track('x1')]);
    await _settle();
    expect(state.openedPlaylist!.tracks.map((t) => t.videoId), ['x1']);
    expect(state.openedPlaylist?.subtitle, 'Playlist • 3 songs');
    expect(state.openedPlaylist?.author?.name, 'Creator');
    expect(state.openedPlaylist?.editable, isFalse);

    // Back returns to the screen it was opened from, not the library.
    state.closePlaylist();
    expect(state.openedPlaylist, isNull);
    expect(state.screen, Screen.home);
  });
}
