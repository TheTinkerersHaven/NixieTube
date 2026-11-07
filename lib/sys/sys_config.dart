// Simple properties-file config.
//
// Keys live in two places:
//
//   config.properties — app settings only (plain text, next to the
//   other app data):
//     discord.appId, discord.enabled, discord.statusText,
//     mpris.enabled, reportPlayback, lyrics.source,
//     a11y.highContrast, a11y.reducedMotion, a11y.underlineLinks,
//     theme.source, theme.seedColor, theme.primary, theme.secondary,
//     theme.tertiary, theme.surface, theme.systemPrimary.
//
//   the platform secret store — credentials only:
//     cookie, sapisidHash, sessionToken (YouTube Music auth),
//     lastfm.enabled, lastfm.apiKey, lastfm.secret, lastfm.sessionKey,
//     lastfm.username (Last.fm scrobbling).
//
// The credentials used to live in a plain-text `auth.properties` next
// to the settings; that file is migrated into the secret store on the
// first start and then deleted (see [SysConfig.loadCredentials]).
import 'dart:io';

import 'paths.dart';
import 'secure_store.dart';

/// Built-in Discord application id used when none is configured.
const defaultDiscordAppId = '1552404006498869318';

/// Unescapes Java-properties escape sequences from a raw value string:
/// `\uXXXX` → the Unicode code point, then `\n` → newline, `\t` → tab,
/// `\\` → backslash.
///
/// Also repairs files corrupted by earlier versions: those saved the
/// Java-escaped `\u003d` verbatim, then re-escaped the backslash on
/// the next save, producing `\\u003d`. Collapsing `\\u` → `\u` before
/// the standard decode recovers the intended character.
String _unescapeProperties(String value) {
  // Repair double-escaped unicode sequences from the earlier
  // round-trip corruption (\\uXXXX → \uXXXX).
  final repaired = value.replaceAll(r'\\u', r'\u');
  // Process \uXXXX sequences first.
  final sb = StringBuffer();
  var i = 0;
  while (i < repaired.length) {
    if (repaired[i] == '\\' && i + 1 < repaired.length) {
      final next = repaired[i + 1];
      if (next == 'u' && i + 5 < repaired.length) {
        // \uXXXX: parse 4 hex digits.
        final hex = repaired.substring(i + 2, i + 6);
        final code = int.tryParse(hex, radix: 16);
        if (code != null) {
          sb.writeCharCode(code);
          i += 6;
          continue;
        }
      }
      if (next == 'n') {
        sb.write('\n');
        i += 2;
        continue;
      }
      if (next == 't') {
        sb.write('\t');
        i += 2;
        continue;
      }
      if (next == '\\') {
        sb.write('\\');
        i += 2;
        continue;
      }
      // Unknown escape: keep the backslash and the character.
      sb.write(repaired[i]);
      i++;
      continue;
    }
    sb.write(repaired[i]);
    i++;
  }
  return sb.toString();
}

/// Reads a Java-properties file into a map (ignores `#`/`!` comments).
Map<String, String> readProperties(File file) {
  final out = <String, String>{};
  try {
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) {
        continue;
      }
      final idx = line.indexOf('=');
      if (idx < 0) continue;
      final key = line.substring(0, idx).trim();
      var value = line.substring(idx + 1).trim();
      // Unescape Java-properties escape sequences: \uXXXX → char,
      // then \n, \t, \\ (order matters: \u first so \\uXXXX is
      // treated as backslash + uXXXX, not a Unicode char).
      value = _unescapeProperties(value);
      out[key] = value;
    }
  } catch (_) {}
  return out;
}

/// Writes a map as a Java-properties file.
void writeProperties(
  File file,
  Map<String, String> values, {
  bool restrictive = false,
}) {
  try {
    file.parent.createSync(recursive: true);
    final buf = StringBuffer();
    final keys = values.keys.toList()..sort();
    for (final key in keys) {
      final value = values[key]!
          .replaceAll(r'\', r'\\')
          .replaceAll('\n', r'\n')
          .replaceAll('\t', r'\t');
      buf.writeln('$key=$value');
    }
    file.writeAsStringSync('$buf');
    if (restrictive) {
      // The fallback holds secrets: no world/group read. dart:io has no
      // chmod, so shell out on Linux; elsewhere the file is still the
      // best-effort fallback it always was.
      try {
        if (Platform.isLinux) {
          Process.runSync('chmod', ['600', file.path]);
        }
      } catch (_) {}
    }
  } catch (_) {}
}

/// Keys that belong in the secret store (credentials, secrets, tokens)
/// rather than `config.properties` (app settings).
bool _isAuthKey(String key) =>
    key == 'cookie' ||
    key == 'sapisidHash' ||
    key == 'sessionToken' ||
    key.startsWith('lastfm.');

/// Keys the retired OAuth sign-in wrote; they are dropped on load.
bool _isRetiredOAuthKey(String key) =>
    key == 'client_id' ||
    key == 'access_token' ||
    key == 'refresh_token' ||
    key == 'expires_at' ||
    key.startsWith('google.');

/// Persistent application settings and credentials.
///
/// Settings live in `config.properties` (plain text). Credentials live
/// in the platform secret store: they are read into memory on startup
/// ([loadCredentials]) and written back there on every change.
class SysConfig {
  SysConfig({String? configPath, SecureStore? secure})
    : _appFile = File(configPath ?? '${configDir().path}/config.properties'),
      // The legacy credential file lives next to the settings file, so
      // a custom [configPath] (tests) keeps both files inside the same
      // sandbox instead of touching the real user credentials.
      _authFile = File(
        '${File(configPath ?? '${configDir().path}/config.properties').parent.path}'
        '/auth.properties',
      ),
      // A custom config path means a sandbox, which must never touch
      // the real keyring.
      _secure =
          secure ??
          (configPath == null
              ? const SecureStore.platform()
              : SecureStore.memory()),
      _values = {} {
    _values.addAll(readProperties(_appFile));
    // Credentials of the retired OAuth sign-in: drop them so the next
    // write leaves no stale secrets behind on disk.
    _values.removeWhere((k, _) => _isRetiredOAuthKey(k));
  }

  final File _appFile;

  /// The plain-text credential file of older versions: read once for
  /// the migration, then deleted.
  final File _authFile;

  final SecureStore _secure;
  final Map<String, String> _values;

  /// The pending credential writes, so the synchronous setters can
  /// hand them to the (asynchronous) secret store in order.
  Future<void> _writes = Future<void>.value();

  /// The directory the settings (and the app's caches) live in.
  String get directory => _appFile.parent.path;

  /// The credential load, shared so concurrent callers wait for the
  /// same read instead of racing the migration.
  Future<void>? _credentialsLoad;

  /// Loads the credentials from the secret store.
  ///
  /// On the first start after the migration the legacy plain-text
  /// `auth.properties` is moved into the store and deleted — but only
  /// once every value landed, so a failure keeps the file.
  Future<void> loadCredentials() => _credentialsLoad ??= _loadCredentials();

  Future<void> _loadCredentials() async {
    Map<String, String> stored = {};
    try {
      stored = await _secure.readAll();
    } catch (_) {
      // No keyring (no session daemon): the legacy file stays the
      // source of truth.
    }
    // The platform store can hold other apps' items (the Linux
    // implementation keeps them under one schema), so keep only the
    // keys that are ours.
    final ours = <String, String>{
      for (final entry in stored.entries)
        if (_isAuthKey(entry.key)) entry.key: entry.value,
    };
    _values.addAll(ours);
    final legacy = readProperties(_authFile);
    final credentials = <String, String>{
      for (final entry in legacy.entries)
        if (_isAuthKey(entry.key)) entry.key: entry.value,
    };
    if (credentials.isEmpty) {
      if (ours.isNotEmpty) _dropLegacyAuthFile();
      return;
    }
    var migrated = true;
    for (final entry in credentials.entries) {
      // The store wins: it already holds the current value.
      if (ours.containsKey(entry.key)) continue;
      try {
        await _secure.write(entry.key, entry.value);
        _values[entry.key] = entry.value;
      } catch (_) {
        migrated = false;
      }
    }
    if (migrated) _dropLegacyAuthFile();
  }

  /// Deletes the legacy plain-text credential file.
  void _dropLegacyAuthFile() {
    try {
      if (_authFile.existsSync()) _authFile.deleteSync();
    } catch (_) {}
  }

  /// The credential values that belong in the legacy file.
  Map<String, String> get _legacyValues => {
    for (final entry in _values.entries)
      if (_isAuthKey(entry.key)) entry.key: entry.value,
  };

  /// Stores a credential in the secret store and waits for it to land.
  ///
  /// A keyring that refuses the write (no session daemon) must not
  /// lose the value: it stays in the legacy file until the store
  /// works again.
  Future<void> setCredential(String key, String value) async {
    _values[key] = value;
    final done = _writes.then((_) async {
      try {
        await _secure.write(key, value);
        _dropLegacyAuthFile();
      } catch (_) {
        writeProperties(_authFile, _legacyValues, restrictive: true);
      }
    });
    _writes = done;
    await done;
  }

  /// Waits for the queued credential writes to reach the secret store.
  Future<void> flushCredentials() => _writes;

  /// Reads a raw string setting, returning [defaultValue] when absent.
  String get(String key, [String defaultValue = '']) {
    final v = _values[key];
    return v ?? defaultValue;
  }

  /// Writes a raw string setting through immediately: app settings to
  /// `config.properties`, credentials to the secret store.
  void set(String key, String value) {
    _values[key] = value;
    if (_isAuthKey(key)) {
      // The secret store is asynchronous: keep the writes ordered
      // behind each other and let [flushCredentials] await them.
      _writes = _writes.then((_) => _writeCredential(key, value));
      return;
    }
    _persist();
  }

  /// Writes one credential to the secret store.
  Future<void> _writeCredential(String key, String value) async {
    try {
      await _secure.write(key, value);
      _dropLegacyAuthFile();
    } catch (_) {
      // No keyring: keep the value in the legacy file.
      writeProperties(_authFile, _legacyValues, restrictive: true);
    }
  }

  /// Drops one credential from the secret store.
  Future<void> _removeCredential(String key) async {
    try {
      await _secure.delete(key);
      _dropLegacyAuthFile();
    } catch (_) {
      writeProperties(_authFile, _legacyValues, restrictive: true);
    }
  }

  /// Writes the app settings file from the current in-memory map.
  void _persist() {
    final appValues = <String, String>{};
    _values.forEach((k, v) {
      if (!_isAuthKey(k)) appValues[k] = v;
    });
    writeProperties(_appFile, appValues);
  }

  /// Reads a bool setting, accepting true/1/yes (and the false forms).
  bool getBool(String key, [bool defaultValue = false]) {
    final v = _values[key]?.trim().toLowerCase();
    if (v == null) return defaultValue;
    if (v == 'true' || v == '1' || v == 'yes') return true;
    if (v == 'false' || v == '0' || v == 'no') return false;
    return defaultValue;
  }

  /// Writes a bool setting through to disk immediately.
  void setBool(String key, bool value) => set(key, value ? 'true' : 'false');

  /// Drops [key] entirely (used for nullable settings where an
  /// absent key means "follow the default").
  void remove(String key) {
    final removed = _values.remove(key);
    if (removed == null) return;
    if (_isAuthKey(key)) {
      _writes = _writes.then((_) => _removeCredential(key));
      return;
    }
    _persist();
  }

  /// Typed accessors. Getters read with
  /// per-key defaults; setters write through to disk. Groups below
  /// follow the Settings screen sections.
  ///
  /// Discord Rich Presence: custom app id (empty means built-in),
  /// master toggle and activity text mode.
  String get discordAppId => get('discord.appId');
  String get discordAppIdOrDefault =>
      discordAppId.trim().isEmpty ? defaultDiscordAppId : discordAppId.trim();
  bool get discordEnabled => getBool('discord.enabled');
  String get discordStatusText => get('discord.statusText', 'app');

  /// MPRIS media-keys integration (Linux only, on by default).
  bool get mprisEnabled => getBool('mpris.enabled', true);

  /// Last.fm scrobbling credentials and session. Key/secret identify
  /// the API application; session key and username arrive at the end
  /// of the browser-approval flow.
  bool get lastfmEnabled => getBool('lastfm.enabled');
  String get lastfmApiKey => get('lastfm.apiKey');
  String get lastfmSecret => get('lastfm.secret');
  String get lastfmSessionKey => get('lastfm.sessionKey');
  String get lastfmUsername => get('lastfm.username');

  set lastfmEnabled(bool v) => setBool('lastfm.enabled', v);
  set lastfmApiKey(String v) => set('lastfm.apiKey', v);
  set lastfmSecret(String v) => set('lastfm.secret', v);
  set lastfmSessionKey(String v) => set('lastfm.sessionKey', v);
  set lastfmUsername(String v) => set('lastfm.username', v);

  /// Whether plays report watchtime beacons to YouTube history.
  bool get reportPlayback => getBool('reportPlayback');

  /// Lyrics provider key (`LyricsSource.name`, defaults to LRCLIB).
  String get lyricsSource => get('lyrics.source', 'lrclib');
  set lyricsSource(String v) => set('lyrics.source', v);

  /// Accessibility (a11y). All default to off so the app keeps its
  /// full-fidelity look until the user opts in.
  bool get highContrast => getBool('a11y.highContrast');
  bool get reducedMotion => getBool('a11y.reducedMotion');
  bool get underlineLinks => getBool('a11y.underlineLinks');

  set highContrast(bool v) => setBool('a11y.highContrast', v);
  set reducedMotion(bool v) => setBool('a11y.reducedMotion', v);
  set underlineLinks(bool v) => setBool('a11y.underlineLinks', v);

  /// Theme (appearance). `theme.source` is `system` (desktop accent
  /// via dynamic_color, when the platform reports one) or `custom`
  /// (seed color below). Anything else falls back to custom so the
  /// app keeps its YTM-red look out of the box.
  String get themeSource => get('theme.source', 'custom');
  set themeSource(String v) => set('theme.source', v);

  /// Seed color for the custom source, as 32-bit ARGB.
  int get themeSeedColor =>
      int.tryParse(get('theme.seedColor', 'ffff0000'), radix: 16) ?? 0xffff0000;
  set themeSeedColor(int v) => set(
    'theme.seedColor',
    (v & 0xffffffff).toRadixString(16).padLeft(8, '0'),
  );

  /// Manual role overrides, applied on top of either source.
  /// Null (absent key) means "follow the scheme".
  int? _themeOverride(String role) {
    final raw = get('theme.$role', '');
    if (raw.isEmpty) return null;
    final v = int.tryParse(raw, radix: 16);
    return v == null ? null : v & 0xffffffff;
  }

  void _setThemeOverride(String role, int? v) {
    if (v == null) {
      remove('theme.$role');
    } else {
      set('theme.$role', (v & 0xffffffff).toRadixString(16).padLeft(8, '0'));
    }
  }

  int? get themePrimaryOverride => _themeOverride('primary');
  set themePrimaryOverride(int? v) => _setThemeOverride('primary', v);
  int? get themeSecondaryOverride => _themeOverride('secondary');
  set themeSecondaryOverride(int? v) => _setThemeOverride('secondary', v);

  /// Last-seen system (desktop accent) primary, remembered so the
  /// tray/window icon follows it from the first frame — before the
  /// async platform fetch lands — and across restarts. Null (absent
  /// key) means no system color has ever been reported.
  int? get themeSystemPrimary => _themeOverride('systemPrimary');
  set themeSystemPrimary(int? v) => _setThemeOverride('systemPrimary', v);
  int? get themeTertiaryOverride => _themeOverride('tertiary');
  set themeTertiaryOverride(int? v) => _setThemeOverride('tertiary', v);
  int? get themeSurfaceOverride => _themeOverride('surface');
  set themeSurfaceOverride(int? v) => _setThemeOverride('surface', v);
}
