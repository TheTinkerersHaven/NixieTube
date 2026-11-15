// Cache persistence hardening: loading dedupes and caps what was on
// disk, and the hot caches still reach the disk after a play (saves are
// coalesced into a microtask instead of one write per event).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/app_state.dart';

import 'fakes.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('nt-cache-persist'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Boots an AppState on [dir] so tests can seed the cache files first.
  AppState boot() {
    final tube = InnerTube();
    addTearDown(tube.close);
    final player = PlayerController(
      engine: FakeEngine(),
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

  test('recents load deduped, newest first, skipping broken rows', () {
    File('${dir.path}/localRecents.json').writeAsStringSync(
      jsonEncode([
        {'videoId': 'v1', 'title': 'One'},
        {'videoId': 'v2', 'title': 'Two'},
        {'videoId': 'v1', 'title': 'One (again)'},
        {'videoId': '', 'title': 'Broken'},
        {'title': 'No id at all'},
      ]),
    );

    final state = boot();

    expect(state.localRecents.map((t) => t.videoId).toList(), ['v1', 'v2']);
    expect(state.localRecents.first.title, 'One');
  });

  test('play counts load capped to the most played', () {
    File('${dir.path}/playCounts.json').writeAsStringSync(
      jsonEncode({for (var i = 0; i < 305; i++) 'v$i': i + 1}),
    );

    final state = boot();

    expect(state.playCounts.length, 300);
    // The least played fall off, the heavy rotation stays.
    expect(state.playCounts.containsKey('v0'), isFalse);
    expect(state.playCounts['v304'], 305);
  });

  test('a play still persists both hot caches', () async {
    final state = boot();

    state.player.playTracks([const Track(videoId: 'v9', title: 'Nine')]);
    await Future<void>.delayed(Duration.zero);

    final recents = File('${dir.path}/localRecents.json');
    final counts = File('${dir.path}/playCounts.json');
    expect(recents.existsSync(), isTrue);
    expect(counts.existsSync(), isTrue);
    expect(recents.readAsStringSync(), contains('v9'));
    expect(jsonDecode(counts.readAsStringSync()), {'v9': 1});
    // Coalesced writes never leave a temp file behind.
    expect(File('${dir.path}/localRecents.json.tmp').existsSync(), isFalse);
  });

  test('flushCaches is safe with nothing queued', () {
    final state = boot();

    state.flushCaches();
    state.flushCaches();

    expect(File('${dir.path}/localRecents.json').existsSync(), isFalse);
  });
}
