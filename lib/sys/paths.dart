// XDG-aware config/cache directories (`~/.config/nixietube` and
// `~/.cache/nixietube`).
import 'dart:io' show Directory, Platform;

/// Resolves one XDG base directory and appends [leaf] to it, creating
/// the result. [envKey] wins when set and non-empty; otherwise the
/// `$HOME`-relative [fallback] is used.
Directory _xdgDir(String envKey, String fallback, String leaf) {
  final configured = Platform.environment[envKey];
  final base = (configured != null && configured.isNotEmpty)
      ? configured
      : '${Platform.environment['HOME'] ?? '.'}/$fallback';
  return Directory('$base/$leaf')..createSync(recursive: true);
}

/// Application config dir (`~/.config/nixietube`), created on access.
Directory configDir() => _xdgDir('XDG_CONFIG_HOME', '.config', 'nixietube');

/// Application cache dir (`~/.cache/nixietube`), created on access.
Directory cacheDir() => _xdgDir('XDG_CACHE_HOME', '.cache', 'nixietube');

/// Application log dir (`~/.cache/nixietube/logs`), created on access.
Directory logDir() {
  return Directory('${cacheDir().path}/logs')..createSync(recursive: true);
}
