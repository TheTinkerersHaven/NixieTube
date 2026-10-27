// Tests for the home Mixed-for-you section: mix extraction from the
// InnerTube home feed (VLRD playlist pages plus personalized RDEM
// seed cards, deduplicated, in feed order) and one-tap mix playback.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

class _FakeEngine extends FakeEngine {
  int pos = 0;
  @override
  Future<String?> play(String url) async => null;
  @override
  Future<void> stop() async {
    pos = 0;
  }

  @override
  Future<void> seekTo(int ms) async {
    pos = ms;
  }

  @override
  int positionMs() => pos;
  @override
  int durationMs() => 0;
  @override
  bool isPlaying() => false;
}

/// InnerTube double serving one scripted mix playlist and radio list.
class _MixTube extends InnerTube {
  PlaylistDetail? mix;
  List<Track> radio = [];

  @override
  Future<PlaylistDetail?> playlist(String browseId, {String? params}) async =>
      mix;

  @override
  Future<List<Track>> upNext(String videoId, {String? playlistId}) async =>
      List.of(radio);
}

BrowseItem _browse(String id, String title) => BrowseItem(
  title: title,
  subtitle: 'Mix',
  browseId: id,
  thumbnails: const [],
);

Track _track(String id) => Track(
  videoId: id,
  title: 'Title $id',
  artists: [ArtistRef('Artist $id')],
  durationSec: 200,
);

Track _seed(String id, String playlistId) => Track(
  videoId: id,
  title: 'My Mix 1',
  artists: [ArtistRef('Somebody')],
  durationSec: 200,
  playlistId: playlistId,
);

void main() {
  group('mixesOfShelves', () {
    test('collects pages and seeds in feed order, deduplicated', () {
      final shelves = [
        Shelf('Moods', [
          _browse('VLRDmix1', 'Chill'),
          _browse('MPREabc', 'An album'),
          ShelfItem.song(_seed('v9', 'RDEMseed1')),
        ]),
        Shelf('More', [
          _browse('VLRDmix1', 'Chill'),
          _browse('UCartist', 'An artist'),
          ShelfItem.song(_track('v1')),
          ShelfItem.song(_seed('v9', 'RDEMseed1')),
          _browse('VLRDmix2', 'Focus'),
        ]),
      ];
      final mixes = AppState.mixesOfShelves(shelves);
      expect(mixes.map((m) => m.browseId).toList(), [
        'VLRDmix1',
        'VLRDEMseed1',
        'VLRDmix2',
      ]);
      expect(mixes[1].seed?.videoId, 'v9');
      expect(mixes[0].seed, isNull);
    });

    test('song radios are not mixes', () {
      expect(AppState.isMixSeed(_track('v1')), isFalse);
      expect(AppState.isMixSeed(_seed('v9', 'RDAMVMv9')), isFalse);
      expect(AppState.isMixSeed(_seed('v9', 'RDEMseed1')), isTrue);
      expect(AppState.isMixSeed(_seed('v9', 'RDCLAKmood1')), isTrue);
      expect(
        AppState.mixesOfShelves([
          Shelf('Songs', [
            ShelfItem.song(_track('v1')),
            ShelfItem.song(_seed('v9', 'RDAMVMv9')),
          ]),
        ]),
        isEmpty,
      );
    });

    test('empty feed means no mixes', () {
      expect(AppState.mixesOfShelves([]), isEmpty);
    });
  });

  group('mix playback', () {
    Future<AppState> boot(_MixTube tube) async {
      final dir = Directory.systemTemp.createTempSync('nt-mix-test');
      addTearDown(() => dir.deleteSync(recursive: true));
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
      final state = AppState(
        tube: tube,
        player: player,
        art: art,
        config: SysConfig(configPath: '${dir.path}/config.properties'),
        openUrl: (_) async {},
      );
      addTearDown(state.dispose);
      return state;
    }

    Future<void> drainLyrics(AppState state) async {
      // Playback fires a real background lyrics fetch a few turns
      // after the track starts; wait until it lands (bounded) so
      // teardown never races a post-dispose notify.
      for (var i = 0; i < 50 && !state.lyricsLoading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (var i = 0; i < 200 && state.lyricsLoading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    test('playMix plays the page from its first track', () async {
      final tube = _MixTube()
        ..mix = PlaylistDetail(
          title: 'Chill',
          subtitle: '',
          thumbnails: const [],
          tracks: [_track('m1'), _track('m2')],
        );
      final state = await boot(tube);
      await state.playMix(
        const HomeMix(
          title: 'Chill',
          subtitle: 'Mix',
          thumbnails: [],
          browseId: 'VLRDmix1',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(state.player.state.queue.map((t) => t.videoId).toList(), [
        'm1',
        'm2',
      ]);
      expect(state.player.state.current?.videoId, 'm1');
      await drainLyrics(state);
    });

    test('playMixSeed plays the seed then its radio mix', () async {
      final tube = _MixTube()..radio = [_track('r1'), _track('r2')];
      final state = await boot(tube);
      await state.playMixSeed(_seed('v9', 'RDEMseed1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(state.player.state.queue.map((t) => t.videoId).toList(), [
        'v9',
        'r1',
        'r2',
      ]);
      expect(state.player.state.current?.videoId, 'v9');
      await drainLyrics(state);
    });

    test('a seed with no radio mix still plays the seed', () async {
      final state = await boot(_MixTube());
      await state.playMixSeed(_seed('v9', 'RDEMnope'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(state.player.state.queue.map((t) => t.videoId).toList(), ['v9']);
      await drainLyrics(state);
    });

    test('unresolvable page mixes are ignored', () async {
      final state = await boot(_MixTube());
      await state.playMix(
        const HomeMix(
          title: 'Gone',
          subtitle: 'Mix',
          thumbnails: [],
          browseId: 'VLRDnope',
        ),
      );
      expect(state.player.state.queue, isEmpty);
      expect(state.player.state.current, isNull);
    });
  });
}
