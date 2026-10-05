// One-click cookie import from Chromium-family browsers.
//
// Instead of decrypting cookie stores (keyring layouts, v10/v11 blobs),
// headless Chrome reads its OWN store over the DevTools protocol from a
// throwaway profile copy — the same idea as yt-dlp
// `--cookies-from-browser`, minus the crypto. Only `*youtube.com` and
// `*music.youtube.com` cookies ever leave the browser; the original
// profile is never written to. Pure Dart (dart:io WebSocket +
// Process), no new dependencies.
//
// Firefox (plaintext `cookies.sqlite`) can plug into [BrowserProfile]
// later; none of the local profiles carry one today.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Domains whose cookies make up a YouTube session.
bool isYouTubeDomain(String domain) {
  var d = domain.trim().toLowerCase();
  if (d.startsWith('.')) d = d.substring(1);
  if (d.isEmpty) return false;
  const bases = ['youtube.com', 'music.youtube.com'];
  for (final base in bases) {
    if (d == base || d.endsWith('.$base')) return true;
  }
  return false;
}

/// A detected browser profile that may hold a YouTube session.
class BrowserProfile {
  const BrowserProfile({
    required this.label,
    required this.binary,
    required this.cookiesDb,
  });

  /// Display name ('Chrome').
  final String label;

  /// Resolved browser executable.
  final String binary;

  /// Profile `Cookies` SQLite file (copied before reading, never locked).
  final String cookiesDb;
}

/// A Chromium-family browser to probe for.
class _BrowserKind {
  const _BrowserKind(this.label, this.binaries, this.configDir);
  final String label;
  final List<String> binaries;
  final String configDir;
}

const _browserKinds = [
  _BrowserKind(
    'Chrome',
    ['google-chrome', 'google-chrome-stable'],
    '.config/google-chrome',
  ),
  _BrowserKind(
    'Chromium',
    ['chromium', 'chromium-browser'],
    '.config/chromium',
  ),
  _BrowserKind(
    'Brave',
    ['brave', 'brave-browser', 'brave-browser-stable'],
    '.config/BraveSoftware/Brave-Browser',
  ),
  _BrowserKind(
    'Edge',
    ['microsoft-edge', 'microsoft-edge-stable'],
    '.config/microsoft-edge',
  ),
];

/// Timeout for the whole import (launch + protocol + cleanup margin).
const browserImportTimeout = Duration(seconds: 75);

class BrowserCookies {
  BrowserCookies._();

  /// Profiles on disk whose browser binary resolves. Default profile
  /// first, then numbered ones. Empty outside Linux.
  static List<BrowserProfile> detectProfiles({
    String? home,
    List<String>? pathDirs,
  }) {
    if (!Platform.isLinux && home == null) return [];
    final homeDir =
        home ?? Platform.environment['HOME'] ?? '';
    if (homeDir.isEmpty) return [];
    final dirs = pathDirs ??
        (Platform.environment['PATH'] ?? '').split(':');
    final out = <BrowserProfile>[];
    for (final kind in _browserKinds) {
      String? binary;
      for (final name in kind.binaries) {
        for (final dir in dirs) {
          if (dir.isEmpty) continue;
          final candidate = '$dir/$name';
          try {
            if (File(candidate).existsSync()) {
              binary = candidate;
              break;
            }
          } catch (_) {}
        }
        if (binary != null) break;
      }
      if (binary == null) continue;
      for (final profile in ['Default', 'Profile 1', 'Profile 2']) {
        final db = '$homeDir/${kind.configDir}/$profile/Cookies';
        try {
          if (File(db).existsSync()) {
            out.add(
              BrowserProfile(
                label: kind.label,
                binary: binary,
                cookiesDb: db,
              ),
            );
          }
        } catch (_) {}
      }
    }
    return out;
  }

  /// Assembles a `Cookie` header from CDP cookie objects, keeping only
  /// YouTube-session domains. Null when none are present.
  static String? buildYouTubeHeader(List<dynamic> cookies) {
    final pairs = <String>[];
    for (final c in cookies) {
      if (c is! Map) continue;
      final domain = c['domain'];
      final name = c['name'];
      final value = c['value'];
      if (domain is! String ||
          name is! String ||
          value is! String ||
          !isYouTubeDomain(domain)) {
        continue;
      }
      final n = name.trim();
      final v = value.trim();
      if (n.isEmpty || v.isEmpty) continue;
      pairs.add('$n=$v');
    }
    if (pairs.isEmpty) return null;
    return pairs.join('; ');
  }

  /// Reads the profile's YouTube cookies via headless Chrome + CDP and
  /// returns a `Cookie` header, or null when anything fails. Never
  /// throws: every failure mode degrades to "paste it manually".
  static Future<String?> importYouTubeCookie(
    BrowserProfile profile,
  ) async {
    try {
      return await _import(profile).timeout(browserImportTimeout);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _import(BrowserProfile profile) async {
    if (!File(profile.binary).existsSync() ||
        !File(profile.cookiesDb).existsSync()) {
      return null;
    }
    final workdir =
        Directory.systemTemp.createTempSync('nixietube-browser-');
    Process? proc;
    try {
      final target = Directory('${workdir.path}/Default')..createSync();
      for (final name in ['Cookies', 'Cookies-journal']) {
        final src = File('${_dirOf(profile.cookiesDb)}/$name');
        if (src.existsSync()) {
          src.copySync('${target.path}/$name');
        }
      }
      proc = await Process.start(profile.binary, [
        '--headless=new',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-gpu',
        '--remote-debugging-port=0',
        '--user-data-dir=${workdir.path}',
        'about:blank',
      ]).timeout(const Duration(seconds: 25));
      final port = await _devToolsPort(proc);
      if (port == null) return null;
      final cookies = await _allCookies(port);
      if (cookies == null) return null;
      return buildYouTubeHeader(cookies);
    } catch (_) {
      return null;
    } finally {
      try {
        proc?.kill();
        await proc?.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Hung browser — force it down before giving up.
        try {
          proc?.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      try {
        workdir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '.' : path.substring(0, i);
  }

  /// Parses the DevTools port from the browser's stderr.
  static Future<int?> _devToolsPort(Process proc) async {
    final pattern = RegExp(
      r'DevTools listening on ws://(?:127\.0\.0\.1|\[::1\]):(\d+)/',
    );
    final buf = StringBuffer();
    final found = Completer<int?>();
    late final StreamSubscription<String> sub;
    sub = proc.stderr.transform(utf8.decoder).listen(
      (chunk) {
        buf.write(chunk);
        final m = pattern.firstMatch(buf.toString());
        if (m != null && !found.isCompleted) {
          found.complete(int.tryParse(m.group(1) ?? ''));
        }
      },
      onError: (_) {},
      onDone: () {
        if (!found.isCompleted) found.complete(null);
      },
    );
    try {
      return await found.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// `Storage.getCookies` on the browser target.
  static Future<List<dynamic>?> _allCookies(int port) async {
    final client = HttpClient();
    WebSocket? ws;
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/json/version'))
          .timeout(const Duration(seconds: 10));
      final version = jsonDecode(
        await (await req.close())
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10)),
      );
      final wsUrl = version is Map
          ? version['webSocketDebuggerUrl']
          : null;
      if (wsUrl is! String || wsUrl.isEmpty) return null;
      ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 10));
      final answer = Completer<Map>();
      final sub = ws.listen(
        (msg) {
          try {
            final m = jsonDecode(msg as String);
            if (m is Map && m['id'] == 1 && !answer.isCompleted) {
              answer.complete(m);
            }
          } catch (_) {}
        },
        onError: (_) {},
      );
      try {
        ws.add(jsonEncode({'id': 1, 'method': 'Storage.getCookies'}));
        final resp =
            await answer.future.timeout(const Duration(seconds: 15));
        final result = resp['result'];
        if (result is Map && result['cookies'] is List) {
          return (result['cookies'] as List).toList();
        }
        return null;
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return null;
    } finally {
      try {
        await ws?.close();
      } catch (_) {}
      client.close();
    }
  }
}
