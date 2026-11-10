// Self-updater: checks GitHub releases for a newer AppImage and
// atomically replaces the running executable so the update takes
// effect on the next launch.
//
// Resource-light by design: the version check is a single GET to the
// GitHub releases API, the download is a single streamed request, and
// the replace is an atomic rename on the same filesystem. Every step
// is best-effort and never throws — a failed update is logged and the
// app keeps running.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../sys/version.dart';
import 'http_client.dart';
import 'log.dart';

const _log = TaggedLog('updater');

const _githubOwner = 'TheTinkerersHaven';
const _githubRepo = 'NixieTube';

/// A newer release is available at [downloadUrl].
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.body,
  });

  /// Release version without the leading `v`.
  final String version;

  /// Direct download URL for the x86_64 AppImage asset.
  final String downloadUrl;

  /// Release notes body.
  final String body;
}

/// Checks GitHub releases and applies AppImage updates.
class Updater {
  Updater({
    Dio? dio,
    String? appImagePath,
    Future<void> Function(String url, String path)? download,
  }) : _dio = dio ?? newHttpClient(),
       _appImagePathOverride = appImagePath,
       _downloadOverride = download;

  final Dio _dio;

  /// Test seam: the `.AppImage` file to replace instead of resolving it
  /// from the environment.
  final String? _appImagePathOverride;

  /// Test seam: replaces the network download.
  final Future<void> Function(String url, String path)? _downloadOverride;

  /// Queries the GitHub releases API for the latest release and compares
  /// its version against [appVersion]. Returns [UpdateInfo] when a newer
  /// release exists, null when up to date or on any error. Never throws.
  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final res = await _dio
          .getUri(
            Uri.parse(
              'https://api.github.com/repos/$_githubOwner/$_githubRepo/'
              'releases/latest',
            ),
            options: Options(
              headers: {
                'Accept': 'application/vnd.github+json',
                'User-Agent': 'NixieTube updater',
              },
            ),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        _log.w('Update check HTTP ${res.statusCode}: ${res.statusMessage}');
        return null;
      }

      final data = res.data;
      final json = data is String ? jsonDecode(data) as Map? : data as Map?;
      if (json == null) return null;

      final tagName = json['tag_name'] as String? ?? '';
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final local = appVersion.split('+').first;
      if (version.isEmpty || !_isNewer(version, local)) {
        return null;
      }

      String? assetUrl;
      final assets = json['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is! Map) continue;
          final name = a['name'] as String? ?? '';
          if (name.endsWith('-x86_64.AppImage')) {
            assetUrl = a['browser_download_url'] as String?;
            break;
          }
        }
      }
      if (assetUrl == null || assetUrl.isEmpty) return null;

      return UpdateInfo(
        version: version,
        downloadUrl: assetUrl,
        body: json['body'] as String? ?? '',
      );
    } catch (e) {
      _log.w('Update check failed: $e');
      return null;
    }
  }

  /// Returns true when [remote] is a higher version than [local]. Both
  /// are dot-separated numeric components; missing components count as
  /// zero.
  bool _isNewer(String remote, String local) {
    final r = remote.split('.');
    final l = local.split('.');
    final len = r.length > l.length ? r.length : l.length;
    for (var i = 0; i < len; i++) {
      final rv = i < r.length ? int.tryParse(r[i]) ?? 0 : 0;
      final lv = i < l.length ? int.tryParse(l[i]) ?? 0 : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }

  /// Downloads the [UpdateInfo] asset and atomically replaces the
  /// running AppImage with it. Returns the AppImage path on success,
  /// null on failure. Never throws.
  ///
  /// The file is written as `<appimage>.new` alongside the running
  /// AppImage, made executable, then renamed over it. On Linux the
  /// running process keeps its old inode, so the update takes effect on
  /// the next launch.
  ///
  /// The AppImage path comes from the `APPIMAGE` environment variable,
  /// which the AppImage runtime sets. [Platform.executable] points at
  /// the *mounted* bundle (`/tmp/.mount_…/usr/bin/nixietube`), not the
  /// `.AppImage` file, so it cannot be used to find the file to replace.
  Future<String?> applyUpdate(UpdateInfo info) async {
    final appImagePath = _appImagePathOverride ?? _appImagePath();
    if (appImagePath == null) {
      _log.w(
        'Not running from an AppImage: ${Platform.executable} '
        '(APPIMAGE unset)',
      );
      return null;
    }
    final appImage = File(appImagePath);
    if (!appImage.existsSync()) {
      _log.w('AppImage not found: $appImagePath');
      return null;
    }
    final newFile = File('$appImagePath.new');

    try {
      await newFile.parent.create(recursive: true);
      if (await newFile.exists()) await newFile.delete();
      await _download(info.downloadUrl, newFile.path);

      // A failed request can still hand back an error page; verify the
      // payload is an ELF binary before replacing a working AppImage.
      final downloaded = await newFile.length();
      final magic = downloaded >= 4 ? await _readMagic(newFile) : const <int>[];
      final isElf =
          magic.length == 4 &&
          magic[0] == 0x7f &&
          magic[1] == 0x45 &&
          magic[2] == 0x4c &&
          magic[3] == 0x46;
      if (downloaded < 1024 * 1024 || !isElf) {
        _log.w(
          'Downloaded update is not an AppImage binary '
          '($downloaded bytes); discarding',
        );
        await newFile.delete();
        return null;
      }

      // Make the replacement executable.
      if (Platform.isLinux) {
        await Process.run('chmod', ['755', newFile.path]);
      }

      // Atomic replace on the same filesystem. The running process
      // keeps the old inode; the next launch uses the new one.
      await newFile.rename(appImagePath);
      _log.i('Update applied: $appImagePath');
      return appImagePath;
    } catch (e) {
      _log.w('Apply update failed: $e');
      try {
        if (await newFile.exists()) await newFile.delete();
      } catch (_) {}
      return null;
    }
  }

  /// Downloads [url] to [path], honoring the test seam.
  ///
  /// Progress is reported at most eleven times: every 10% when the
  /// payload length is known, or every 5 MiB when it isn't.
  Future<void> _download(String url, String path) async {
    final override = _downloadOverride;
    if (override != null) {
      await override(url, path);
      return;
    }
    _log.i('Downloading update');
    var lastStep = -1;
    await _dio
        .download(
          url,
          path,
          onReceiveProgress: (received, total) {
            final step = total > 0
                ? (received * 10) ~/ total
                : received ~/ (5 * 1024 * 1024);
            if (step <= lastStep) return;
            lastStep = step;
            _log.i(
              total > 0
                  ? 'Update download: ${(received * 100) ~/ total}%'
                  : 'Update download: ${received ~/ (1024 * 1024)} MiB',
            );
          },
        )
        .timeout(const Duration(minutes: 10));
  }

  /// The first four bytes of [file], used to check the ELF magic.
  static Future<List<int>> _readMagic(File file) async {
    final raf = await file.open();
    try {
      return await raf.read(4);
    } finally {
      await raf.close();
    }
  }

  /// The `.AppImage` file the running app was launched from, or null
  /// when this is not an AppImage build.
  String? _appImagePath() {
    final fromEnv = Platform.environment['APPIMAGE'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    // Running the AppImage file directly (no runtime mount) still
    // reports an executable that ends in `.AppImage`.
    final exe = Platform.executable;
    return exe.endsWith('.AppImage') ? exe : null;
  }
}
