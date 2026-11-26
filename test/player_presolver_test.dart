// Pre-solved player scripts: the app reads them from the published branch,
// keeps them on disk, and treats anything unexpected as a miss (the local
// solve path then takes over).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/player_presolver.dart';

import 'mock_dio.dart';

/// A minimal stand-in for what `tool/ejs_presolve.js` publishes: player
/// code that fills `_result` with the two entry points.
String _artifact(String marker) =>
    'if (typeof globalThis.XMLHttpRequest === "undefined") {}\n'
    '${'var a = 1;\n' * 400}'
    '_result.n = n;\n_result.sig = sig;\n// $marker';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('presolved-players');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test(
    'a published artifact is fetched once and then read from disk',
    () async {
      var requests = 0;
      final dio = mockDio((options) async {
        requests++;
        return (200, _artifact(options.uri.pathSegments.last));
      });
      final players = PresolvedPlayers(dio: dio, dir: dir.path);

      final first = await players.fetch('b485e332');

      expect(first, contains('_result.sig'));
      expect(requests, 1);
      expect(File('${dir.path}/b485e332.js').existsSync(), isTrue);

      // A later launch, or a flaky network, still has the script: the file
      // is served without a request.
      final offline = PresolvedPlayers(
        dio: mockDio((options) async => (500, 'no network')),
        dir: dir.path,
      );
      final second = await offline.fetch('b485e332');

      expect(second, first);
    },
  );

  test('the artifact URL is keyed by player version', () async {
    final requested = <Uri>[];
    final dio = mockDio((options) async {
      requested.add(options.uri);
      return (200, _artifact('b485e332'));
    });
    await PresolvedPlayers(dio: dio, dir: dir.path).fetch('b485e332');

    expect(requested, hasLength(1));
    expect(requested.single.path, endsWith('/b485e332.js'));
  });

  test('an unpublished version is a miss, not an error', () async {
    final dio = mockDio((options) async => (404, '404: Not Found'));
    final players = PresolvedPlayers(dio: dio, dir: dir.path);

    expect(await players.fetch('deadbeef'), isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('a response that is not a solver artifact is refused', () async {
    // An HTML error page, or a truncated body, must not reach the engine.
    final dio = mockDio(
      (options) async => (200, '<!DOCTYPE html><html></html>'),
    );
    final players = PresolvedPlayers(dio: dio, dir: dir.path);

    expect(await players.fetch('b485e332'), isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('a corrupt cached artifact falls back to the network', () async {
    File('${dir.path}/b485e332.js').writeAsStringSync('truncated');
    final dio = mockDio((options) async => (200, _artifact('b485e332')));

    final script = await PresolvedPlayers(
      dio: dio,
      dir: dir.path,
    ).fetch('b485e332');

    expect(script, contains('_result.sig'));
  });

  test('a malformed player id is refused without a request', () async {
    var requests = 0;
    final dio = mockDio((options) async {
      requests++;
      return (200, _artifact('x'));
    });
    final players = PresolvedPlayers(dio: dio, dir: dir.path);

    for (final id in ['', '../etc', 'a/b', 'x' * 65, 'has space']) {
      expect(await players.fetch(id), isNull, reason: id);
    }
    expect(requests, 0);
  });

  test('only the most recent artifacts are kept on disk', () async {
    final dio = mockDio((options) async => (200, _artifact('x')));
    final players = PresolvedPlayers(dio: dio, dir: dir.path);

    for (var i = 0; i < 6; i++) {
      await players.fetch('version$i');
      // Distinct modification times, so the trim is deterministic.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final kept = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(kept, {'version2.js', 'version3.js', 'version4.js', 'version5.js'});
  });

  test('a network failure is a miss, not a thrown error', () async {
    final dio = mockDio((options) async => throw const SocketException('down'));
    final players = PresolvedPlayers(dio: dio, dir: dir.path);

    expect(await players.fetch('b485e332'), isNull);
  });
}
