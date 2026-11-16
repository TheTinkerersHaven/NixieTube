// Song-info resolution: a list row carries no album year or public like
// count, so opening the panel fills both from the watch-next response
// and the album page.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/account_library.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

/// A tube whose watch-next read already carries the album year.
class _EnrichingTube extends InnerTube {
  @override
  Future<Track> enrichTrack(Track track) async => track.copyWith(
    album: AlbumRef(
      'Album',
      browseId: 'MPRE1',
      kind: ReleaseKind.album,
      year: '2001',
    ),
  );
}

/// A library that answers the public like count and counts the calls.
class _LikesLibrary extends AccountLibrary {
  int calls = 0;

  @override
  Future<int?> videoLikeCount(String videoId) async {
    calls++;
    return 42;
  }
}

Future<({AppState state, _LikesLibrary library})> _boot({
  _LikesLibrary? library,
}) async {
  final dir = Directory.systemTemp.createTempSync('nt-song-info');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _EnrichingTube();
  addTearDown(tube.close);
  final player = PlayerController(engine: FakeEngine(), tube: tube);
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
  final lib = library ?? _LikesLibrary();
  state.libraryOverride = lib;
  state.testAccount = 'Tester';
  return (state: state, library: lib);
}

void main() {
  test('resolveSongInfo fills the album year and the like count', () async {
    final state = (await _boot()).state;
    final result = await state.resolveSongInfo(
      const Track(videoId: 'v1', title: 'Song'),
    );
    expect(result.track.album?.year, '2001');
    expect(result.likeCount, 42);
  });

  test('the like count is fetched once and reused', () async {
    final lib = _LikesLibrary();
    final state = (await _boot(library: lib)).state;
    final track = const Track(videoId: 'v1', title: 'Song');
    await state.resolveSongInfo(track);
    final second = await state.resolveSongInfo(track);
    expect(second.likeCount, 42);
    expect(lib.calls, 1);
  });
}
