// Shared test fakes: a no-op [PlayerEngine] and a reusable AppState boot
// scaffold. Test files import this instead of re-declaring the same
// `_FakeEngine` (28 copies) and `_boot(...)` scaffolding (8 copies).
//
// Usage:
//   import 'fakes.dart';
//   final tube = FakeTube();
//   final state = await bootAppState(tester, tube: tube);
//   ...
//   addTearDowns are registered inside [bootAppState].

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

/// A no-op [PlayerEngine] suitable for widget tests that drive the
/// player through [PlayerController.playTracks] rather than real audio.
class FakeEngine implements PlayerEngine {
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
  int durationMs() => 200000;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
}

/// A minimal [InnerTube] that never hits the network. Override the
/// methods a test cares about.
class FakeTube extends InnerTube {
  bool rateResult = true;
  String? lastRatedVideoId;
  RatingStatus? lastRatedRating;

  /// Play count handed to callers of [viewCount]; a null value makes
  /// the call throw, simulating a network failure.
  int? nextViewCount;
  int viewCountCalls = 0;

  @override
  Future<int> viewCount(String videoId) async {
    viewCountCalls++;
    final n = nextViewCount;
    if (n == null) throw Exception('viewCount failed');
    return n;
  }

  @override
  Future<bool> rate(String videoId, RatingStatus rating) async {
    lastRatedVideoId = videoId;
    lastRatedRating = rating;
    return rateResult;
  }

  @override
  Future<RatingStatus> rating(String videoId) async =>
      RatingStatus.indifferent;

  @override
  Future<Track> enrichTrack(Track track) async => track;
}

/// Builds an [AppState] wired to a temp directory, registering the
/// usual teardowns, and returns it. The caller is responsible for
/// pumping whatever widget tree it needs.
Future<AppState> bootAppState(
  WidgetTester tester, {
  required InnerTube tube,
  PlayerEngine? engine,
  String? configDirPath,
  String? artDirPath,
  Future<ResolvedStream?> Function(String id)? resolveStream,
  Future<void> Function(String url)? openUrl,
}) async {
  final dir = Directory.systemTemp.createTempSync('nt-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  addTearDown(tube.close);
  final player = PlayerController(
    engine: engine ?? FakeEngine(),
    tube: tube,
    resolveStream: resolveStream ??
        ((id) async => ResolvedStream(url: 'https://x/$id', bitrate: 1)),
    configDirPath: configDirPath ?? dir.path,
  );
  addTearDown(player.dispose);
  final art = ArtworkStore(
    cacheDirPath: artDirPath ?? '${dir.path}/art',
  );
  addTearDown(art.close);
  final state = AppState(
    tube: tube,
    player: player,
    art: art,
    config: SysConfig(
      configPath: '${dir.path}/config.properties',
    ),
    openUrl: openUrl ?? ((_) async {}),
  );
  addTearDown(state.dispose);
  return state;
}
