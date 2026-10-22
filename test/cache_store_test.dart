// The app's caches (track credits, play counts, recents, artist
// avatars) live in their own JSON files; the settings file keeps only
// readable `key=value` lines.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
import 'package:nixietube/sys/cache_store.dart';
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

void main() {
  group('cache store', () {
    late Directory dir;
    late String configPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('nt-cache-store');
      configPath = '${dir.path}/config.properties';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('moves the legacy json properties into their own files', () async {
      // An install that still carries the caches as settings.
      final config = SysConfig(configPath: configPath);
      config.set('home.trackMeta', '{"v1":{"a":[["Artist","UC1"]]}}');
      config.set('home.playCounts', '{"v1":3}');

      final tube = InnerTube();
      final player = PlayerController(engine: _FakeEngine(), tube: tube);
      final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
      final state = AppState(
        tube: tube,
        player: player,
        art: art,
        config: config,
        openUrl: (_) async {},
      );

      // The caches are in their files now...
      expect(
        File('${dir.path}/trackMeta.json').readAsStringSync(),
        contains('v1'),
      );
      expect(
        File('${dir.path}/playCounts.json').readAsStringSync(),
        contains('v1'),
      );
      // ...and the settings file holds no json anymore.
      final settings = File(configPath).readAsStringSync();
      expect(settings, isNot(contains('home.trackMeta')));
      expect(settings, isNot(contains('home.playCounts')));
      expect(settings, isNot(contains('{"v1"')));

      state.dispose();
      player.dispose();
      art.close();
      tube.close();
    });

    test('the cache files survive a restart', () async {
      final store = CacheStore(dir: dir.path);
      store.write('playCounts', '{"v1":3}');
      expect(store.read('playCounts'), '{"v1":3}');
      // A missing cache reads as null, not as an error.
      expect(store.read('nothing'), isNull);
    });
  });
}
