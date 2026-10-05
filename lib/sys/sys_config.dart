// Simple properties-file config, mirroring Kotlin `SysConfig`
// (`~/.config/nixietube/config.properties`).
//
// Keys: discord.appId, discord.enabled, discord.statusText, mpris.enabled,
// google.clientId, google.clientSecret, lastfm.enabled, lastfm.apiKey,
// lastfm.secret, lastfm.sessionKey, lastfm.username, reportPlayback.

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

  String get(String key, [String defaultValue = '']) {
    final v = _values[key];
    return v ?? defaultValue;
  }

  void set(String key, String value) {
    _values[key] = value;
    writeProperties(_file, _values);
  }

  bool getBool(String key, [bool defaultValue = false]) {
    final v = _values[key]?.trim().toLowerCase();
    if (v == null) return defaultValue;
    if (v == 'true' || v == '1' || v == 'yes') return true;
    if (v == 'false' || v == '0' || v == 'no') return false;
    return defaultValue;
  }

  void setBool(String key, bool value) => set(key, value ? 'true' : 'false');

  // Typed accessors mirroring Kotlin `SysConfig`.
  String get discordAppId => get('discord.appId');
  String get discordAppIdOrDefault =>
      discordAppId.trim().isEmpty ? defaultDiscordAppId : discordAppId.trim();
  bool get discordEnabled => getBool('discord.enabled');
  String get discordStatusText => get('discord.statusText', 'app');
  bool get mprisEnabled => getBool('mpris.enabled', true);
  String get googleClientId => get('google.clientId');
  String get googleClientSecret => get('google.clientSecret');
  bool get lastfmEnabled => getBool('lastfm.enabled');
  String get lastfmApiKey => get('lastfm.apiKey');
  String get lastfmSecret => get('lastfm.secret');
  String get lastfmSessionKey => get('lastfm.sessionKey');
  String get lastfmUsername => get('lastfm.username');
  bool get reportPlayback => getBool('reportPlayback');
}
