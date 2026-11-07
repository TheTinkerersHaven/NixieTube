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
import 'package:logging/logging.dart';

import '../sys/version.dart';
import 'http_client.dart';

final _log = Logger('nixietube.updater');

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
  Updater({Dio? dio}) : _dio = dio ?? newHttpClient();

  final Dio _dio;

  /// Queries the GitHub releases API for the latest release and compares
  /// its version against [appVersion]. Returns [UpdateInfo] when a newer
  /// release exists, null when up to date or on any error. Never throws.
  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final res = await _dio.getUri(
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
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        _log.warning(
          'Update check HTTP ${res.statusCode}: ${res.statusMessage}',
        );
        return null;
      }

      final data = res.data;
      final json = data is String ? jsonDecode(data) as Map? : data as Map?;
      if (json == null) return null;

      final tagName = json['tag_name'] as String? ?? '';
      final version = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;
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
      _log.warning('Update check failed: $e');
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

  /// Downloads the [UpdateInfo] asset to the same directory as the
  /// running AppImage and atomically replaces the executable with it.
  /// Returns the final path on success, null on failure. Never throws.
  ///
  /// The file is written as `<executable>.new` alongside the running
  /// AppImage, made executable, then renamed over it. On Linux the
  /// running process keeps its old inode, so the update takes effect on
  /// the next launch. If the running executable isn't an AppImage (the
  /// path doesn't end in `.AppImage`), the replace is skipped.
  Future<String?> applyUpdate(UpdateInfo info) async {
    final executable = File(Platform.executable);
    if (!executable.existsSync()) {
      _log.warning('Running executable not found: ${Platform.executable}');
      return null;
    }
    if (!executable.path.endsWith('.AppImage')) {
      _log.warning(
        'Not running from an AppImage: ${Platform.executable}',
      );
      return null;
    }
    final dir = executable.parent;
    final newFile = File(
      '${dir.path}/${executable.uri.pathSegments.last}.new',
    );

    try {
      await newFile.parent.create(recursive: true);
      await _dio.download(
        info.downloadUrl,
        newFile.path,
        onReceiveProgress: (received, total) {
          _log.info('Update download: $received / $total');
        },
      ).timeout(const Duration(minutes: 10));

      // Make the replacement executable.
      if (Platform.isLinux) {
        await Process.run('chmod', ['755', newFile.path]);
      }

      // Atomic replace on the same filesystem. The running process
      // keeps the old inode; the next launch uses the new one.
      await newFile.rename(executable.path);
      _log.info('Update applied: ${executable.path}');
      return executable.path;
    } catch (e) {
      _log.warning('Apply update failed: $e');
      try {
        if (await newFile.exists()) await newFile.delete();
      } catch (_) {}
      return null;
    }
  }
}
