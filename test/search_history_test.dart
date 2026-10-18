// Tests for search history: recording order/dedup through searchFor,
// single-entry removal, and clearing. Run with XDG_CONFIG_HOME pointed
// at a temp dir — history persists under the global config dir.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
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

class _EmptyTube extends InnerTube {
  @override
  Future<Map<String, List<ShelfItem>>> search(String query) async => {};
}

Future<AppState> _boot() async {
  final dir = Directory.systemTemp.createTempSync('nt-searchhist-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = _EmptyTube();
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

/// History persists under the global config dir, so these tests only
/// run against an isolated XDG_CONFIG_HOME (otherwise a plain
/// `flutter test` would scribble on the real user config).
final bool _isolated = Platform.environment['XDG_CONFIG_HOME'] != null;

Object? _needsIsolation() => _isolated
    ? null
    : 'Set XDG_CONFIG_HOME to a temp dir to run config-persistence tests';

void main() {
  test(
    'searchFor records trimmed queries newest-first',
    skip: _needsIsolation(),
    () async {
      final state = await _boot();
      await state.searchFor('  Kid Again  ');
      await state.searchFor('ivycomb');
      expect(state.searchHistory, ['ivycomb', 'Kid Again']);
      // Re-searching bumps to the front without duplicating.
      await state.searchFor('kid again');
      expect(state.searchHistory, ['kid again', 'ivycomb']);
    },
  );

  test(
    'removeSearchHistory drops one entry and persists',
    skip: _needsIsolation(),
    () async {
      final state = await _boot();
      await state.searchFor('aaa');
      await state.searchFor('bbb');
      await state.searchFor('ccc');
      state.removeSearchHistory('bbb');
      expect(state.searchHistory, ['ccc', 'aaa']);
      // Unknown entries are a no-op (and notify nothing observable).
      state.removeSearchHistory('zzz');
      expect(state.searchHistory, ['ccc', 'aaa']);
      // A fresh state reads back the persisted remainder on startup.
      final reread = await _boot();
      await reread.loadAuth();
      expect(reread.searchHistory, ['ccc', 'aaa']);
    },
  );

  test(
    'clearSearchHistory empties memory and disk',
    skip: _needsIsolation(),
    () async {
      final state = await _boot();
      await state.searchFor('aaa');
      expect(state.searchHistory, isNotEmpty);
      state.clearSearchHistory();
      expect(state.searchHistory, isEmpty);
      final reread = await _boot();
      await reread.loadAuth();
      expect(reread.searchHistory, isEmpty);
    },
  );
}
