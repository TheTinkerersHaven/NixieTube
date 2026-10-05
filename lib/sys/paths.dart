// XDG-aware config/cache directories, mirroring the Kotlin client's
// hard-coded `~/.config/nixietube` + `~/.cache/nixietube` layout so both
// frontends share on-disk state.
import 'dart:io' show Directory, Platform;

/// Application config dir (`~/.config/nixietube`), created on access.
Directory configDir() {
  final base =
      Platform.environment['XDG_CONFIG_HOME'] ??
      '${Platform.environment['HOME'] ?? '.'}/.config';
  return Directory('$base/nixietube')..createSync(recursive: true);
}

/// Application cache dir (`~/.cache/nixietube`), created on access.
Directory cacheDir() {
  final base =
      Platform.environment['XDG_CACHE_HOME'] ??
      '${Platform.environment['HOME'] ?? '.'}/.cache';
  return Directory('$base/nixietube')..createSync(recursive: true);
}
