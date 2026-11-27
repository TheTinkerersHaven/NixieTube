// On-disk cache for playable audio.
//
// Two sources feed it, and both matter for a flaky connection:
//
// * a full download of the tracks queued after the current one, asked for
//   when playback starts, so `next` works with no network at all;
// * a capture of whatever the loopback proxy streams for the track being
//   played, so listening to a song once stores it without downloading it
//   a second time.
//
// A track is only ever served back once its file is complete: a partial
// file is a `.part` and stays invisible to playback. Files are evicted
// oldest-first past a size cap, which the captures and downloads refresh
// on use, so what survives is what the queue is about to play.

import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import '../../sys/log.dart';
import '../../sys/paths.dart';

final _log = TaggedLog('cache');

/// One in-flight capture of a proxied playback stream.
class CacheCapture {
  CacheCapture._(this._cache, this._part, this._sink, this._total);

  final AudioCache _cache;
  final File _part;
  final IOSink _sink;
  final int? _total;
  bool _closed = false;

  /// Appends bytes as they are relayed to the engine.
  void add(List<int> chunk) {
    if (_closed) return;
    try {
      _sink.add(chunk);
    } catch (_) {}
  }

  /// Promotes the file to a cache hit when the whole track went through.
  ///
  /// A partial one is kept: the bytes it holds are exactly what a seek
  /// back inside the track needs, and dropping them is what made every
  /// backward seek wait for the network again. It is dropped when the
  /// next track takes over (see [AudioCache.dropCapturesExcept]).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache._capturing.remove(_part.path);
    try {
      await _sink.flush();
      await _sink.close();
    } catch (_) {}
    final total = _total;
    try {
      final length = await _part.length();
      if (total != null && total > 0 && length == total) {
        await _cache._promote(_part);
      }
    } catch (error) {
      _log.d('capture close failed: $error');
    }
  }
}

/// Downloads and serves the audio of tracks that have already been played
/// or are about to be.
class AudioCache {
  AudioCache({
    required this.resolveUrl,
    this.isEnabled,
    this.dirPath,
    this.maxBytes,
  });

  /// Resolves a raw (unproxied) media URL for [videoId], under a fresh
  /// visitor so the download is not sharing the playback URL's budget.
  final Future<String?> Function(String videoId) resolveUrl;

  /// Size cap; the oldest files go first once it is exceeded. A
  /// callback rather than a number because the setting can move while
  /// the app runs. Null means [defaultMaxBytes].
  final int Function()? maxBytes;

  static const defaultMaxBytes = 512 * 1024 * 1024;

  /// Bytes per upstream request. The per-URL budget on the stricter media
  /// URLs is about a megabyte, so a half-megabyte chunk leaves room for
  /// the request that follows it.
  static const _chunkSize = 512 * 1024;

  /// How many times one download may re-resolve its URL before giving up.
  static const _maxResolves = 6;

  static const _extension = '.audio';

  /// Extension of an in-progress file; never served.
  static const _partial = '.part';

  /// Whether caching is on, consulted per call: the setting can flip at
  /// runtime from Settings.
  final bool Function()? isEnabled;

  /// Where the files live. Defaults to `audio` under the app cache dir.
  final String? dirPath;

  /// Video ids with a download running, so a capture does not fight one
  /// for the same file.
  final Set<String> _downloading = {};

  /// Paths with a capture open. The capture file is a contiguous run
  /// from byte 0, so a second writer would interleave into it: a seek
  /// that lands on the same offset as an in-flight request gets no
  /// capture rather than two.
  final Set<String> _capturing = {};

  /// Partials this run wrote bytes into, so a seek is only ever answered
  /// from what this session already pulled down — never from a leftover
  /// of an earlier one, which a different bitrate could have produced.
  final Set<String> _written = {};

  /// Active downloads, so asking twice for the same track is free.
  final Map<String, Future<void>> _active = {};

  /// Whether caching is on. Consulted per call: the setting can flip at
  /// runtime from Settings.
  bool get enabled => isEnabled?.call() ?? true;

  /// The directory, created on demand so a run that never caches leaves
  /// nothing behind.
  Directory _directory() => Directory(_dirPath())..createSync(recursive: true);

  String _dirPath() => dirPath ?? '${cacheDirPath()}/audio';

  String _pathOf(String videoId) => '${_dirPath()}/$videoId$_extension';

  /// The complete cached file for [videoId], or null when there is none.
  /// Touches the file so a replay keeps it out of the eviction order.
  File? completeFile(String videoId) {
    if (!enabled || videoId.isEmpty) return null;
    final file = File(_pathOf(videoId));
    try {
      if (!file.existsSync()) return null;
      file.setLastModifiedSync(DateTime.now());
      return file;
    } catch (_) {
      return null;
    }
  }

  /// The bytes already captured for [videoId], for the proxy to answer a
  /// seek from disk: the in-progress `.part` file and where it ends.
  ///
  /// A capture only ever appends where the previous one stopped, so the
  /// file is a contiguous run from byte 0 and any offset below its
  /// length is already on disk.
  ({File file, int length})? capturedPrefix(String videoId, {int? total}) {
    if (!enabled || videoId.isEmpty) return null;
    if (_downloading.contains(videoId)) return null;
    final file = File('${_dirPath()}/$videoId$_extension$_partial');
    if (!_written.contains(file.path)) return null;
    try {
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length <= 0) return null;
      // Longer than the stream it would be spliced into: leftovers of a
      // different one, not a prefix of this track.
      if (total != null && total > 0 && length > total) return null;
      return (file: file, length: length);
    } catch (_) {
      return null;
    }
  }

  /// Drops the partial captures of every track but [keepVideoId].
  ///
  /// A partial file is only useful while its track is the one playing,
  /// so the bytes a seek can reuse are the current track's alone. A
  /// capture still writing its file is left alone; its own close decides
  /// what becomes of it.
  void dropCapturesExcept(String keepVideoId) {
    final dir = Directory(_dirPath());
    if (!dir.existsSync()) return;
    final keep = '$keepVideoId$_extension$_partial';
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith(_partial) || name == keep) continue;
        if (_capturing.contains(entity.path)) continue;
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    } catch (error) {
      _log.d('capture sweep failed: $error');
    }
  }

  /// Downloads [videoId] into the cache. Never throws; one download per
  /// track at a time, and a track already cached is not fetched again.
  Future<void> download(String videoId) {
    if (!enabled || videoId.isEmpty) return Future.value();
    if (completeFile(videoId) != null) return Future.value();
    final running = _active[videoId];
    if (running != null) return running;
    final done = _download(videoId);
    _active[videoId] = done;
    return done.whenComplete(() => _active.remove(videoId));
  }

  Future<void> _download(String videoId) async {
    if (_downloading.contains(videoId)) return;
    _downloading.add(videoId);
    final target = File(_pathOf(videoId));
    final part = File('${target.path}$_partial');
    IOSink? sink;
    HttpClient? client;
    try {
      _directory();
      sink = part.openWrite();
      client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 20);
      String? source = await resolveUrl(videoId);
      if (source == null) return;
      var total = _lengthOf(source);
      var written = 0;
      var resolves = 1;
      var current = source;
      while (total == null || written < total) {
        final int? end = total == null
            ? null
            : min(written + _chunkSize, total) - 1;
        final response = await _get(client, current, written, end);
        final status = response.statusCode;
        if (status == HttpStatus.forbidden ||
            status == HttpStatus.unauthorized ||
            status == HttpStatus.notFound) {
          await _drain(response);
          if (resolves++ >= _maxResolves) break;
          final fresh = await resolveUrl(videoId);
          if (fresh == null) break;
          current = fresh;
          total ??= _lengthOf(fresh);
          continue;
        }
        if (status != HttpStatus.ok &&
            status != HttpStatus.partialContent) {
          await _drain(response);
          break;
        }
        total ??= _totalOf(response);
        var got = 0;
        await for (final chunk in response) {
          sink.add(chunk);
          got += chunk.length;
        }
        written += got;
        // A short read that reports no length is all there is.
        if (got == 0) break;
        if (total == null && status == HttpStatus.ok) break;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total != null && await part.length() == total) {
        await _promote(part);
      } else {
        await part.delete();
      }
    } catch (error) {
      _log.d('download $videoId failed: $error');
      try {
        await sink?.close();
      } catch (_) {}
      try {
        await part.delete();
      } catch (_) {}
    } finally {
      client?.close(force: true);
      _downloading.remove(videoId);
    }
  }

  /// Starts capturing a proxied playback stream at [startOffset].
  ///
  /// Returns null when there is nothing worth capturing: caching off, the
  /// track already complete, a download already running for it, or a
  /// request that does not continue where the captured file ends (a seek,
  /// which would leave a hole in the file).
  CacheCapture? beginCapture(
    String videoId,
    int startOffset, {
    int? total,
  }) {
    if (!enabled || videoId.isEmpty) return null;
    if (_downloading.contains(videoId)) return null;
    if (File(_pathOf(videoId)).existsSync()) return null;
    try {
      final dir = _directory();
      final part = File('${dir.path}/$videoId$_extension$_partial');
      final captured = part.existsSync() ? part.lengthSync() : 0;
      if (startOffset == 0) {
        if (captured > 0) part.deleteSync();
      } else if (startOffset != captured) {
        return null;
      }
      if (!_capturing.add(part.path)) return null;
      _written.add(part.path);
      try {
        return CacheCapture._(
          this,
          part,
          part.openWrite(mode: FileMode.append),
          total,
        );
      } catch (_) {
        _capturing.remove(part.path);
        rethrow;
      }
    } catch (error) {
      _log.d('capture $videoId unavailable: $error');
      return null;
    }
  }

  /// Makes [part] the cache entry for its track and trims the cache.
  Future<void> _promote(File part) async {
    final target = File(
      part.path.substring(0, part.path.length - _partial.length),
    );
    try {
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } catch (error) {
      _log.d('promote failed: $error');
      return;
    }
    await trim();
  }

  /// Deletes the oldest cached files until the cache fits the cap.
  Future<void> trim() async {
    final cap = maxBytes?.call() ?? defaultMaxBytes;
    final dir = Directory(_dirPath());
    if (!dir.existsSync()) return;
    try {
      final entries = <({File file, DateTime at, int size})>[];
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        // A partial capture counts too: it is on the same disk budget
        // and is only worth keeping while its track is the one playing.
        if (_capturing.contains(entity.path)) continue;
        final stat = await entity.stat();
        total += stat.size;
        entries.add((file: entity, at: stat.modified, size: stat.size));
      }
      if (total <= cap) return;
      entries.sort((a, b) => a.at.compareTo(b.at));
      for (final entry in entries) {
        if (total <= cap) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {}
      }
    } catch (error) {
      _log.d('trim failed: $error');
    }
  }

  /// Bytes currently held on disk.
  int usedBytes() {
    final dir = Directory(_dirPath());
    if (!dir.existsSync()) return 0;
    var total = 0;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += entity.lengthSync();
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }

  /// Drops every cached track.
  Future<void> clear() async {
    final dir = Directory(_dirPath());
    if (!dir.existsSync()) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (error) {
      _log.d('clear failed: $error');
    }
  }

  Future<HttpClientResponse> _get(
    HttpClient client,
    String source,
    int start,
    int? end,
  ) async {
    final request = await client.getUrl(Uri.parse(source));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    );
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.rangeHeader,
      end == null ? 'bytes=$start-' : 'bytes=$start-$end',
    );
    return request.close();
  }

  /// The media URL's own `clen` parameter, which every googlevideo URL
  /// carries; null when the URL does not say.
  static int? _lengthOf(String url) {
    final value = int.tryParse(
      Uri.tryParse(url)?.queryParameters['clen'] ?? '',
    );
    if (value == null || value <= 0) return null;
    return value;
  }

  /// Total length from a `206` response: `content-range: bytes 0-1/1234`,
  /// or the plain length of a full body.
  static int? _totalOf(HttpClientResponse response) {
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    if (range != null) {
      final total = int.tryParse(range.split('/').last.trim());
      if (total != null && total > 0) return total;
    }
    final length = response.contentLength;
    return length > 0 ? length : null;
  }

  static Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } catch (_) {}
  }
}
