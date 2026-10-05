// Tests for healing distributor-placeholder ("Release") credits.
//
// Data API `fixup` falls back to "Release" when a "Release - Topic"
// upload carries no artist in its tags; only InnerTube's watch-next
// panel names the real credit. The liked list (and opened playlists,
// home shelves) heal in the background via fixReleaseCredits.
//
// Lyrics enrichment fires real LRCLIB requests in the background, so
// playback tests drain before teardown; assertions never depend on it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

class _FakeEngine implements PlayerEngine {
  final List<PlayerEngineListener> listeners = [];
  final List<String> playedUrls = [];

  @override
  Future<bool> play(String url) async {
    playedUrls.add(url);
    return true;
  }

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
  bool isPlaying() => playedUrls.isNotEmpty;

  @override
  Future<void> release() async {}

  @override
  void addListener(PlayerEngineListener listener) {
    listeners.add(listener);
  }
}

/// InnerTube double: scripted panel credits per video id, like-rate
/// always accepted, everything else inert.
class _FakeCreditTube extends InnerTube {
  Map<String, List<ArtistRef>> credits = {};
  Set<String> throwOnEnrich = {};

  @override
  Future<Track> enrichTrack(Track track) async {
    if (throwOnEnrich.contains(track.videoId)) {
      throw Exception('panel unavailable');
    }
    final fixed = credits[track.videoId];
    if (fixed == null) return track;
    return track.copyWith(artists: List.of(fixed));
  }

  @override
  Future<RatingStatus> rating(String videoId) async => RatingStatus.unknown;

  @override
  Future<bool> rate(String videoId, RatingStatus rating) async => true;
}

Track _releaseTrack(String id, String title) => Track(
      videoId: id,
      title: title,
      artists: [ArtistRef('Release')],
      durationSec: 200,
      radioPlaylistId: 'RDAMVM$id',
    );

Track _goodTrack(String id) => Track(
      videoId: id,
      title: 'Title $id',
      artists: [ArtistRef('Some Artist', browseId: 'UC$id')],
      durationSec: 200,
      radioPlaylistId: 'RDAMVM$id',
    );

({AppState state, _FakeEngine engine, _FakeCreditTube tube}) _app({
  bool playback = false,
}) {
  final dir = Directory.systemTemp.createTempSync('nt-credit-test');
  final tube = _FakeCreditTube();
  final engine = _FakeEngine();
  final player = PlayerController(
    engine: engine,
    tube: tube,
    resolveStream: (id) async =>
        ResolvedStream(url: 'https://x/$id', bitrate: 128000),
    configDirPath: dir.path,
  );
  final state = AppState(
    tube: tube,
    player: player,
    art: ArtworkStore(cacheDirPath: '${dir.path}/art'),
    oauth: GoogleOAuth(storePath: '${dir.path}/oauth.properties'),
    config: SysConfig(configPath: '${dir.path}/config.properties'),
    openUrl: (_) async {},
  );
  addTearDown(() async {
    if (playback) {
      // Let the fire-and-forget lyrics fetch land while the state is
      // still alive; a post-dispose notify would throw into the zone.
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    player.dispose();
    state.dispose();
    tube.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return (state: state, engine: engine, tube: tube);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('fixReleaseCredits', () {
    test('heals placeholders, leaves the rest alone', () async {
      final env = _app();
      env.tube.credits['v1'] = [ArtistRef('Boom Kitty', browseId: 'UCBK')];

      final out = await env.state.fixReleaseCredits(
        [_releaseTrack('v1', 'Obelisk'), _goodTrack('v2')],
      );
      expect(out.map((t) => t.artistNames()), ['Boom Kitty', 'Some Artist']);
      expect(out.first.artists.single.browseId, 'UCBK');
      expect(out[1].artistNames(), 'Some Artist');
    });

    test('panel failures keep the placeholder', () async {
      final env = _app();
      env.tube.throwOnEnrich.add('v9');

      final out = await env.state.fixReleaseCredits(
        [_releaseTrack('v9', 'Unknown')],
      );
      expect(out.single.artistNames(), 'Release');
    });

    test('clean lists skip the panel entirely', () async {
      final env = _app();
      env.tube.credits['v2'] = [ArtistRef('Nobody')];
      // No placeholder in the input, so the panel credit above must
      // never be consulted: the artist stays as it was.
      final out = await env.state.fixReleaseCredits([_goodTrack('v2')]);
      expect(out.single.artistNames(), 'Some Artist');
    });
  });

  group('enrichLikedArtists', () {
    test('"Obelisk" by "Release" becomes "Obelisk" by "Boom Kitty"',
        () async {
      final env = _app(playback: true);
      // Like the placeholder track so it lands in the liked list,
      // the way a real library load would have put it there. The
      // panel credit arrives only afterwards.
      env.state.player.playTracks([_releaseTrack('v1', 'Obelisk')]);
      await _settle();
      expect(await env.state.rateTrack('v1', RatingStatus.like), isTrue);
      expect(env.state.liked.single.artistNames(), 'Release');

      // The open liked view snapshots the stale credit…
      await env.state.openPlaylist(
        const GPlaylist(id: '__liked', title: 'Liked songs', itemCount: 1),
      );
      expect(
        env.state.openedPlaylist!.tracks.single.artistNames(),
        'Release',
      );

      env.tube.credits['v1'] = [ArtistRef('Boom Kitty', browseId: 'UCBK')];
      await env.state.enrichLikedArtists();
      expect(env.state.liked.single.artistNames(), 'Boom Kitty');
      // …and the open view follows.
      expect(
        env.state.openedPlaylist!.tracks.single.artistNames(),
        'Boom Kitty',
      );
    });
  });
}
