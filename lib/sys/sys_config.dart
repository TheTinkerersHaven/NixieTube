// Simple properties-file config, mirroring Kotlin `SysConfig`
// (`~/.config/nixietube/config.properties`).
//
// Keys: discord.appId, discord.enabled, discord.statusText, mpris.enabled,
// google.clientId, google.clientSecret, lastfm.enabled, lastfm.apiKey,
// lastfm.secret, lastfm.sessionKey, lastfm.username, reportPlayback,
// a11y.highContrast, a11y.reducedMotion, a11y.underlineLinks,
// lyrics.source, theme.source,
// theme.seedColor, theme.primary, theme.secondary, theme.tertiary,
// theme.surface, theme.systemPrimary.

import 'dart:io' show File;

import 'paths.dart';

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
void writeProperties(File file, Map<String, String> values) {
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
  } catch (_) {}
}

/// Persistent application settings.
class SysConfig {
  SysConfig({String? configPath})
    : _file = File(configPath ?? '${configDir().path}/config.properties'),
      _values = {} {
    _values.addAll(readProperties(_file));
  }

  final File _file;
  final Map<String, String> _values;

  /// Reads a raw string setting, returning [defaultValue] when absent.
  String get(String key, [String defaultValue = '']) {
    final v = _values[key];
    return v ?? defaultValue;
  }

  /// Writes a raw string setting through to disk immediately.
  void set(String key, String value) {
    _values[key] = value;
    writeProperties(_file, _values);
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
    if (_values.remove(key) != null) writeProperties(_file, _values);
  }

  /// Typed accessors mirroring Kotlin `SysConfig`. Getters read with
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

  /// Google OAuth client credentials (Desktop-type client), typed in
  /// Settings; without them the Data API login refuses to start.
  String get googleClientId => get('google.clientId');
  String get googleClientSecret => get('google.clientSecret');

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
