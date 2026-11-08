// XDG-aware config/cache directories (`~/.config/nixietube` and
// `~/.cache/nixietube`).
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

/// Application log dir (`~/.cache/nixietube/logs`), created on access.
Directory logDir() {
  return Directory('${cacheDir().path}/logs')..createSync(recursive: true);
}
