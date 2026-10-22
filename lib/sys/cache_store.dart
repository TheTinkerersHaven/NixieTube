// The app's on-disk caches: enriched track credits, play counts, the
// locally remembered recents and the artist avatars.
//
// Each cache lives in its own JSON file next to the settings, so the
// settings file stays a readable list of `key=value` lines instead of
// a wall of escaped JSON.
//
// The caches used to be properties (`home.trackMeta` and friends) in
// `config.properties`; [CacheStore.migrate] moves those into their
// files once and drops the properties.

import 'dart:io' show File;

import 'paths.dart';

/// The app's JSON caches on disk.
class CacheStore {
  CacheStore({String? dir}) : _dir = dir ?? configDir().path;

  /// Where the cache files live (the config dir).
  final String _dir;

  /// The file backing the cache [name].
  File _file(String name) => File('$_dir/$name.json');

  /// The raw JSON of the cache [name], or null when there is none (or
  /// it cannot be read).
  String? read(String name) {
    try {
      final file = _file(name);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// Writes the raw JSON of the cache [name].
  void write(String name, String json) {
    try {
      final file = _file(name);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(json);
    } catch (_) {}
  }
}
