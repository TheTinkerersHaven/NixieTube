// Pre-solved player scripts, published by the repository's Actions job.
//
// Answering YouTube's `sig` and `n` challenges means parsing the whole
// ~2.6 MB player script with meriyah and printing the pieces back out with
// astring. That pass depends on nothing but the script itself, so it can
// run once off the device: `tool/ejs_presolve.js` does it on Node in under
// a second and publishes the result keyed by player version (an orphan
// `player-cache` branch in this repository). On an engine without a JIT the
// pass costs minutes, while evaluating the artifact costs a fraction of a
// second, so the device only does that.
//
// Fetching is content-addressed: the watch page already names the player
// version, so the artifact URL is derived from it and one download serves
// every challenge until YouTube rotates base.js. The download also
// replaces the 2.6 MB player script the local path would need.
//
// Nothing here is fatal. A version that is not published yet, an offline
// device and a stale cache all return null, and the caller solves the
// player script itself (see js_challenge_solver.dart).

import 'dart:io' show Directory, File;

import 'package:dio/dio.dart';

import '../../sys/atomic_io.dart';
import '../../sys/http_client.dart';
import '../../sys/log.dart';
import '../../sys/paths.dart';

final _log = TaggedLog('jsc');

/// Artifacts kept on disk. Each one is a few megabytes and YouTube keeps
/// at most a couple of player versions alive at a time, so a handful
/// covers the rotations a device can live through without a network.
const _keepOnDisk = 4;

/// Client for the pre-solved player scripts the project publishes.
class PresolvedPlayers {
  PresolvedPlayers({
    Dio? dio,
    this.dir,
    this.baseUrl = defaultBaseUrl,
    this.timeout = const Duration(seconds: 20),
  }) : _dio = dio ?? newHttpClient();

  /// Where the artifacts are published: the `player-cache` branch of this
  /// repository, served straight from raw.githubusercontent (public, no
  /// credentials, no API rate limit).
  static const defaultBaseUrl =
      'https://raw.githubusercontent.com/TheTinkerersHaven/NixieTube/'
      'player-cache';

  /// Player versions are short hex-ish slugs like `b485e332`. Anything
  /// else is refused rather than pasted into a URL and a file name.
  static final _validId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// The artifact is the solver core's own output: player code that fills
  /// a `_result` object with the `sig` and `n` entry points. Anything else
  /// that came back (an error page, a truncated body) is treated as a miss
  /// instead of being handed to the engine.
  static bool looksPreprocessed(String script) =>
      script.length > 4096 && script.contains('_result.sig');

  final Dio _dio;

  /// Where the artifacts are cached; null keeps them in the app's cache
  /// directory. Tests and tooling pass a temporary one.
  final String? dir;

  /// Root URL the artifacts are served from.
  final String baseUrl;

  /// Upper bound for one download.
  final Duration timeout;

  /// The last artifacts read, so a screenful of resolves does not re-read
  /// several megabytes from disk for each track.
  final Map<String, String> _memory = {};

  /// The pre-solved script for [playerId], from memory, then disk, then
  /// the published branch. Null when there is none, and never throws.
  Future<String?> fetch(String playerId) async {
    final id = playerId.trim();
    if (!_validId.hasMatch(id)) return null;
    final inMemory = _memory[id];
    if (inMemory != null) return inMemory;
    final cached = _readCached(id);
    if (cached != null) {
      _memory[id] = cached;
      return cached;
    }
    try {
      final res = await _dio
          .getUri<String>(Uri.parse('$baseUrl/$id.js'))
          .timeout(timeout);
      final body = (res.data ?? '').trim();
      if (res.statusCode != 200) {
        _log.d('no pre-solved player for $id: HTTP ${res.statusCode}');
        return null;
      }
      if (!looksPreprocessed(body)) {
        _log.w('pre-solved player for $id is not a solver artifact');
        return null;
      }
      _memory[id] = body;
      _writeCached(id, body);
      _log.d('fetched pre-solved player $id (${body.length} bytes)');
      return body;
    } catch (error) {
      _log.d('pre-solved player for $id unavailable: $error');
      return null;
    }
  }

  /// Where [id]'s artifact lives. The directory is only created when a
  /// download is written, so a device that never finds one leaves the
  /// cache untouched.
  String _path(String id) => '${dir ?? '${cacheDirPath()}/players'}/$id.js';

  String? _readCached(String id) {
    try {
      final file = File(_path(id));
      if (!file.existsSync()) return null;
      final script = file.readAsStringSync();
      return looksPreprocessed(script) ? script : null;
    } catch (_) {
      return null;
    }
  }

  void _writeCached(String id, String script) {
    try {
      writeAtomicSync(_path(id), script);
      _prune();
    } catch (error) {
      _log.d('could not cache the pre-solved player $id: $error');
    }
  }

  /// Drops the artifacts beyond [_keepOnDisk], oldest first.
  void _prune() {
    try {
      final directory = Directory(dir ?? '${cacheDirPath()}/players');
      if (!directory.existsSync()) return;
      final files =
          directory
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.js'))
              .toList()
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            );
      for (final file in files.skip(_keepOnDisk)) {
        file.deleteSync();
      }
    } catch (_) {
      // A cache that cannot be trimmed is not worth an error.
    }
  }
}
