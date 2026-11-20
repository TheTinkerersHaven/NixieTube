// Application directories.
//
// Desktop follows the XDG base directories (~/.config/nixietube and
// ~/.cache/nixietube). Mobile apps cannot write to their working
// directory or a HOME-relative path, so [initPlatformPaths] resolves the
// app's own sandbox once at startup and the rest of the app keeps using
// these synchronous accessors.

import 'dart:io' show Directory, Platform;

import 'package:path_provider/path_provider.dart';

String? _mobileRoot;

/// Resolves the writable root for Android/iOS. Call from [main] after
/// [WidgetsFlutterBinding.ensureInitialized] and before any service asks
/// for a directory. Desktop keeps its XDG roots and needs no setup.
Future<void> initPlatformPaths() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  try {
    _mobileRoot = (await getApplicationSupportDirectory()).path;
  } catch (_) {
    _mobileRoot = (await getApplicationDocumentsDirectory()).path;
  }
}

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

Directory _mobileDir(String leaf) =>
    Directory('$_mobileRoot/$leaf')..createSync(recursive: true);

/// Application config dir (`~/.config/nixietube` on desktop, `config`
/// inside the app sandbox on mobile), created on access.
Directory configDir() {
  final root = _mobileRoot;
  if (root != null) return _mobileDir('config');
  return _xdgDir('XDG_CONFIG_HOME', '.config', 'nixietube');
}

/// Application cache dir (`~/.cache/nixietube` on desktop, `cache`
/// inside the app sandbox on mobile), created on access.
Directory cacheDir() {
  final root = _mobileRoot;
  if (root != null) return _mobileDir('cache');
  return _xdgDir('XDG_CACHE_HOME', '.cache', 'nixietube');
}

/// Application log dir (`~/.cache/nixietube/logs`), created on access.
Directory logDir() {
  return Directory('${cacheDir().path}/logs')..createSync(recursive: true);
}
