// Pure-Dart artwork pipeline: integrity-checked disk cache with failure
// tracking. Downloads thumbnails, center-crops non-square covers (a square
// as tall as the thumbnail, centered), and exposes stable cropped files.
// Square thumbnails are kept untouched. Cache layout matches the Kotlin app
// (`art2` + generation suffixes), so both frontends share on-disk renders.
// Decode/crop work runs on worker isolates and nothing decoded is retained
// in memory.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;

import '../../sys/http_client.dart';
import '../../sys/paths.dart';

const maxFailureKeys = 2000;

/// Consecutive download failures before a URL is skipped.
const maxFailures = 3;

/// Rewrites a thumbnail URL to request a ~540px cover, preserving the
/// source aspect ratio. Forcing a square box (`=w540-h540`) makes the
/// image service letterbox/crop non-square art server-side before we ever
/// see the true rectangle — which crops too close. Keeping the ratio
/// means a non-square thumbnail arrives non-square, and the client-side
/// center-square (as tall as the thumbnail) decides the crop instead.
String upgradeArt(String url) {
  final re = RegExp(r'=w(\d+)-h(\d+)([^?]*)$');
  final m = re.firstMatch(url);
  if (m == null) return url;
  final w = int.tryParse(m.group(1) ?? '') ?? 0;
  final h = int.tryParse(m.group(2) ?? '') ?? 0;
  if (w <= 0 || h <= 0) return url;
  const target = 540;
  final nh = ((target * h) / w).round().clamp(1, 1 << 31);
  final suffix = m.group(3) ?? '';
  return url.replaceRange(m.start, m.end, '=w$target-h$nh$suffix');
}

String _originalArt(String url) =>
    url.replaceAll(RegExp(r'=w\d+-h\d+[^?]*'), '');

/// Rewrites Google image size params up to [targetWidth]; never downscales.
String upscaleArtworkUrl(String url, int targetWidth) {
  final re = RegExp(r'=w(\d+)(?:-h(\d+))?');
  final m = re.firstMatch(url);
  if (m == null) return '$url=w$targetWidth';
  final full = m.group(0)!;
  final w = int.tryParse(m.group(1) ?? '') ?? 0;
  if (w >= targetWidth) return url;
  final h = int.tryParse(m.group(2) ?? '') ?? 0;
  final replacement = (w > 0 && h > 0)
      ? '=w$targetWidth-h${((targetWidth * h) ~/ w).clamp(1, 1 << 31)}'
      : '=w$targetWidth';
  return url.replaceFirst(full, replacement);
}

/// Checks payload completeness (JPEG must end with EOI) to keep partial
/// downloads out of the cache.
bool looksComplete(List<int> bytes) {
  if (bytes.length < 4) return false;
  final isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
  if (!isJpeg) return true;
  final n = bytes.length;
  return bytes[n - 2] == 0xFF && bytes[n - 1] == 0xD9;
}

String _sha1Hex(String url) => sha1.convert(utf8.encode(url)).toString();

/// Centered-square crop as an owned buffer: for a non-square thumbnail the
/// square is as tall as the thumbnail (landscape) or as wide (portrait),
/// centered on the larger axis — the `crop=min(iw,ih)` centre crop. Square
/// thumbnails are returned unchanged.
/// `copyCrop` copies pixels, so the source frame is droppable and offcuts
/// never sit in memory.
///
/// Runs after [removeLetterbox] in the decode path (see [_decode]), so by
/// the time the geometry applies, baked-in black bars are already gone
/// and this stays a pure centre crop.
img.Image centerSquare(img.Image src) {
  final w = src.width;
  final h = src.height;
  if (w <= 0 || h <= 0 || w == h) return src.clone();
  if (w > h) {
    return img.copyCrop(src, x: (w - h) ~/ 2, y: 0, width: h, height: h);
  }
  return img.copyCrop(src, x: 0, y: (h - w) ~/ 2, width: w, height: w);
}

img.Image? _decode(List<int> bytes, {bool cropSquare = true}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  return cropSquare ? centerSquare(removeLetterbox(decoded)) : decoded;
}

/// Near-black channel ceiling for bar detection. YouTube bars are pure
/// black; a small tolerance absorbs JPEG ringing at the seam.
const _barBlackCeiling = 10;

/// Minimum share of sampled pixels reading near-black for a row or
/// column to count as bar.
const _barUniformity = 0.98;

/// Minimum surviving fraction per axis: an all-black cover keeps its
/// frame instead of collapsing to nothing.
const _barMinRetain = 0.5;

/// Strips baked-in letterbox/pillarbox bars (black bands facing each
/// other) so masked-as-square frames resolve to their content box.
/// Conservative by design: single-edge darkness (vignettes, fades)
/// never trims, content above the black ceiling never counts, and the
/// surviving box must keep at least half of each axis. A genuinely
/// black cover therefore passes through untouched.
img.Image removeLetterbox(img.Image src) {
  final w = src.width;
  final h = src.height;
  if (w <= 0 || h <= 0) return src;
  bool dark(int x, int y) {
    final px = src.getPixel(x, y);
    if (px.a.toInt() < 128) return false;
    return px.r.toInt() <= _barBlackCeiling &&
        px.g.toInt() <= _barBlackCeiling &&
        px.b.toInt() <= _barBlackCeiling;
  }

  // A row/column counts as bar when ~every sampled pixel is black;
  // ~64 samples per line regardless of size.
  bool lineDark(bool horizontal, int fixed, int len) {
    var step = len ~/ 64;
    if (step < 1) step = 1;
    var darks = 0;
    var total = 0;
    for (var i = 0; i < len; i += step) {
      total++;
      if (horizontal ? dark(i, fixed) : dark(fixed, i)) darks++;
    }
    return total > 0 && darks / total >= _barUniformity;
  }

  var top = 0;
  while (top < h && lineDark(true, top, w)) {
    top++;
  }
  var bottom = 0;
  while (bottom < h - top && lineDark(true, h - 1 - bottom, w)) {
    bottom++;
  }
  var left = 0;
  while (left < w && lineDark(false, left, h)) {
    left++;
  }
  var right = 0;
  while (right < w - left && lineDark(false, w - 1 - right, h)) {
    right++;
  }
  // Bars must face each other.
  final vertical = top > 0 && bottom > 0;
  final horizontal = left > 0 && right > 0;
  if (!vertical && !horizontal) return src;
  final x0 = horizontal ? left : 0;
  final x1 = horizontal ? w - right : w;
  final y0 = vertical ? top : 0;
  final y1 = vertical ? h - bottom : h;
  if (x1 - x0 < (w * _barMinRetain).ceil() ||
      y1 - y0 < (h * _barMinRetain).ceil()) {
    return src;
  }
  if (x0 == 0 && y0 == 0 && x1 == w && y1 == h) return src;
  return img.copyCrop(src, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
}

/// Cover palette for tinted backdrops: average colors of a
/// 5x5 grid over the cover (row-major: TL→BR). Port of
/// Kotlin `coverBands`, extended from 3 horizontal bands
/// to 25 points so the wash can follow the whole artwork.
/// Null when the image is empty.
///
/// The sampling window is inset from the edges: border,
/// vignette and letterbox-remnant pixels would otherwise
/// dominate the outer rows and columns.
List<(int, int, int)>? coverBands(img.Image src) {
  if (src.width <= 0 || src.height <= 0) return null;
  const size = 48;
  final thumb = img.copyResize(
    src,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
  const inset = size ~/ 8;
  const grid = 5;
  final region = size - inset * 2;
  final out = <(int, int, int)>[];
  for (var bandY = 0; bandY < grid; bandY++) {
    final y0 = inset + (region * bandY) ~/ grid;
    final y1 = inset + (region * (bandY + 1)) ~/ grid;
    for (var bandX = 0; bandX < grid; bandX++) {
      final x0 = inset + (region * bandX) ~/ grid;
      final x1 = inset + (region * (bandX + 1)) ~/ grid;
      var red = 0;
      var green = 0;
      var blue = 0;
      var n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final px = thumb.getPixel(x, y);
          red += px.r.toInt();
          green += px.g.toInt();
          blue += px.b.toInt();
          n++;
        }
      }
      if (n == 0) return null;
      out.add((red ~/ n, green ~/ n, blue ~/ n));
    }
  }
  return out;
}

/// Job kinds for the persistent artwork workers.
const _jobSquare = 0;
const _jobBanner = 1;
const _jobCropPng = 2;

/// Persistent worker main: one warm isolate per pool, listening for jobs
/// and replying on each job's own reply port. Spawned once and reused,
/// so artwork loads never pay an isolate spawn per decode.
void _workerMain(List<dynamic> args) {
  final SendPort announce = args[0] as SendPort;
  final int kind = args[1] as int;
  final jobs = ReceivePort();
  announce.send(jobs.sendPort);
  jobs.listen((dynamic message) {
    final job = message as List<dynamic>;
    final SendPort replyTo = job[0] as SendPort;
    final Uint8List bytes = job[1] as Uint8List;
    try {
      switch (kind) {
        case _jobBanner:
          replyTo.send(_decode(bytes, cropSquare: false));
        case _jobCropPng:
          final rendered = _decode(bytes);
          replyTo.send(rendered == null ? null : img.encodePng(rendered));
        default:
          replyTo.send(_decode(bytes));
      }
    } catch (_) {
      replyTo.send(null);
    }
    // This worker is free again: re-offer it so the pool can dispatch the
    // next queued job. Without this the pool only ever sees each worker
    // idle once and stalls after its first `_poolSize` jobs.
    announce.send(jobs.sendPort);
  });
}

/// Workers per pool. Two keep short decodes pipelined without paying the
/// per-job spawn cost.
const _poolSize = 2;

/// Lazily-spawned pool of persistent worker isolates for one job kind.
/// Jobs are dispatched FIFO to idle workers; each reply routes through its
/// own ReceivePort, so results can't be misattributed. No isolates exist
/// until the first job (tests that never decode pay no spawn cost).
class _ArtPool {
  _ArtPool(this._kind);

  final int _kind;

  ReceivePort? _announce;
  final List<Future<Isolate>> _isolates = [];
  final List<SendPort> _idle = [];
  final List<(SendPort, Uint8List)> _jobs = [];

  void _ensureStarted() {
    if (_announce != null) return;
    _announce = ReceivePort()
      ..listen((dynamic p) {
        _idle.add(p as SendPort);
        _drain();
      });
    for (var i = 0; i < _poolSize; i++) {
      _isolates.add(Isolate.spawn(_workerMain, [_announce!.sendPort, _kind]));
    }
  }

  void _drain() {
    while (_idle.isNotEmpty && _jobs.isNotEmpty) {
      final worker = _idle.removeLast();
      final job = _jobs.removeAt(0);
      worker.send([job.$1, job.$2]);
    }
  }

  /// Runs [bytes] through the pool's job kind, resolving to its reply.
  Future<T?> run<T>(Uint8List bytes) {
    _ensureStarted();
    final reply = ReceivePort();
    _jobs.add((reply.sendPort, bytes));
    _drain();
    return reply.first
        .timeout(const Duration(seconds: 30))
        .then((dynamic v) => v as T?)
        .whenComplete(reply.close);
  }

  void dispose() {
    _announce?.close();
    for (final f in _isolates) {
      unawaited(f.then((iso) => iso.kill(priority: Isolate.immediate)));
    }
    _isolates.clear();
    _idle.clear();
    _jobs.clear();
  }
}

/// Pure-Dart artwork pipeline: integrity-checked disk cache with
/// failure tracking. Decoded bitmaps are never retained in memory —
/// Flutter's image cache plus the on-disk renders are the caches, and all
/// decode/crop work runs on worker isolates.
class ArtworkStore {
  ArtworkStore({Dio? dio, String? cacheDirPath})
    : _dio = dio ?? newHttpClient(),
      _dirPath = cacheDirPath ?? '${cacheDir().path}/art2',
      _squarePool = _ArtPool(_jobSquare),
      _bannerPool = _ArtPool(_jobBanner),
      _cropPool = _ArtPool(_jobCropPng) {
    // Ensure directory exists - use sync for constructor, but this is fine
    // as it only happens once during initialization
    Directory(_dirPath).createSync(recursive: true);
  }

  final Dio _dio;
  final String _dirPath;
  final Map<String, int> _failures = {};
  final Map<String, int> _sourceFailures = {};
  final Map<String, Future<dynamic>> _inflight = {};

  final _ArtPool _squarePool;
  final _ArtPool _bannerPool;
  final _ArtPool _cropPool;

  void close() {
    _dio.close();
    _squarePool.dispose();
    _bannerPool.dispose();
    _cropPool.dispose();
  }

  /// Deletes every cached artwork file (raw bytes and rendered crops) so
  /// the next display re-downloads and re-renders from scratch. Also
  /// resets the failure skip-lists and the banner memo: without this,
  /// previously-failed URLs would stay skipped and banners would keep
  /// serving stale bytes, so the clear would only partly take. Used by
  /// the Settings "Clear artwork cache" debug action (which additionally
  /// evicts Flutter's in-memory image cache — same-path re-renders
  /// would otherwise decode from memory and look unchanged).
  void clearCache() {
    _failures.clear();
    _sourceFailures.clear();
    _bannerPng.clear();
    try {
      final dir = Directory(_dirPath);
      if (dir.existsSync()) {
        for (final entry in dir.listSync()) {
          try {
            entry.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // `.img3`/`.crop5`: bump to invalidate the artwork cache — previously
  // cached bytes/renders (from earlier crop-logic experiments) are
  // re-fetched and re-rendered with the current pipeline. crop5 adds
  // letterbox stripping to the render, so pre-fix crops (with baked-in
  // black bars, e.g. in playlist collages) must not be reused.
  String _rawFile(String url) => '$_dirPath/${_sha1Hex(url)}.img3';
  String _sourceFile(String url) => '$_dirPath/${_sha1Hex(url)}.source3.img';
  String croppedFilePath(String url) => '$_dirPath/${_sha1Hex(url)}.crop5.png';



  void _noteFailure(Map<String, int> failures, String url) {
    failures[url] = (failures[url] ?? 0) + 1;
    while (failures.length > maxFailureKeys) {
      failures.remove(failures.keys.first);
    }
  }

  /// Runs [block] coalesced per URL so concurrent requests for one URL
  /// share a single download/decode.
  Future<T> _keyed<T>(String url, Future<T> Function() block) {
    final existing = _inflight[url];
    if (existing != null) return existing as Future<T>;
    final future = block();
    _inflight[url] = future;
    future.whenComplete(() {
      if (identical(_inflight[url], future)) _inflight.remove(url);
    });
    return future;
  }

  /// Asynchronously reads cached bytes from file with integrity check.
  /// Returns null if file doesn't exist, is incomplete, or can't be read.
  Future<List<int>?> _readCachedBytesAsync(String path) async {
    try {
      final raw = await File(path).readAsBytes();
      if (!looksComplete(raw)) {
        try {
          await File(path).delete();
        } catch (_) {}
        return null;
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// Asynchronously writes bytes to file atomically using temp file + rename.
  /// This prevents corruption if the write is interrupted.
  Future<bool> _writeAtomicallyAsync(String path, List<int> bytes) async {
    try {
      final tmp =
          '$path.tmp.${DateTime.now().microsecondsSinceEpoch}.${_tmpNonce()}';
      final file = File(tmp);
      await file.writeAsBytes(bytes, flush: true);
      await file.rename(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>?> _tryDownload(String url) async {
    try {
      final effectiveUrl = url.startsWith('//') ? 'https:$url' : url;
      // Bounded like every other request: a stalled GET must fail
      // (placeholder + one retry) instead of shimmering forever.
      final res = await _dio
          .getUri<List<int>>(
            Uri.parse(effectiveUrl),
            options: Options(responseType: ResponseType.bytes),
          )
          .timeout(const Duration(seconds: 30));
      final bytes = res.data;
      if (bytes != null && bytes.length > 100 && looksComplete(bytes)) {
        return bytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<int>?> _download(String url) async {
    final upgraded = upgradeArt(url);
    if (upgraded != url) {
      final bytes = await _tryDownload(upgraded);
      if (bytes != null) return bytes;
    }
    return _tryDownload(url);
  }

  /// Decoded square cover for [url], downloading and caching on miss.
  /// Decode runs on a worker isolate; nothing decoded is retained.
  /// Uses async file operations to prevent UI thread blocking.
  Future<img.Image?> image(String url) {
    if (url.trim().isEmpty) return Future.value();
    if ((_failures[url] ?? 0) >= maxFailures) return Future.value();
    return _keyed('img:$url', () async {
      var bytes = await _readCachedBytesAsync(_rawFile(url));
      if (bytes == null) {
        bytes = await _download(url);
        if (bytes == null) {
          _noteFailure(_failures, url);
          return null;
        }
        await _writeAtomicallyAsync(_rawFile(url), bytes);
      }
      try {
        return await _squarePool.run<img.Image>(Uint8List.fromList(bytes));
      } catch (_) {
        return null;
      }
    });
  }

  /// Finished banner PNG bytes for [url] at display width, memoized:
  /// list tiles unmount on scroll and remount constantly, and without
  /// this every return trip re-decoded, re-encoded and re-decoded the
  /// banner (the visible second-long reload). FIFO-capped; banners are
  /// ~1MB each at display size.
  final Map<String, Future<Uint8List>> _bannerPng = {};
  static const _bannerPngCap = 8;

  Future<Uint8List> bannerPng(String url, {int width = 1280}) {
    final key = '$width|$url';
    final hit = _bannerPng[key];
    if (hit != null) return hit;
    if (_bannerPng.length >= _bannerPngCap) {
      _bannerPng.remove(_bannerPng.keys.first);
    }
    Future<Uint8List> build() async {
      final image = await source(url);
      if (image == null) return Uint8List(0);
      final sized = image.width > width
          ? img.copyResize(image, width: width)
          : image;
      try {
        return Uint8List.fromList(img.encodePng(sized));
      } catch (_) {
        return Uint8List(0);
      }
    }

    final future = build();
    _bannerPng[key] = future;
    return future;
  }

  /// Original, uncropped banner image at served aspect ratio.
  /// Uses async file operations to prevent UI thread blocking.
  Future<img.Image?> source(String url) {
    if (url.trim().isEmpty) return Future.value();
    if ((_sourceFailures[url] ?? 0) >= maxFailures) {
      return Future.value();
    }
    return _keyed('src:$url', () async {
      var bytes = await _readCachedBytesAsync(_sourceFile(url));
      if (bytes == null) {
        bytes = await _downloadSource(url);
        if (bytes == null) {
          _noteFailure(_sourceFailures, url);
          return null;
        }
        await _writeAtomicallyAsync(_sourceFile(url), bytes);
      }
      try {
        return await _bannerPool.run<img.Image>(Uint8List.fromList(bytes));
      } catch (_) {
        return null;
      }
    });
  }

  Future<List<int>?> _downloadSource(String url) async {
    for (final candidate in [
      upscaleArtworkUrl(url, 1920),
      url,
      _originalArt(url),
    ]) {
      final bytes = await _tryDownload(candidate);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Stable cropped PNG file for [url], rendering on first use.
  /// Uses async file operations to prevent UI thread blocking.
  Future<File?> file(String url) {
    if (url.trim().isEmpty) return Future.value();
    return _keyed('file:$url', () async {
      final target = File(croppedFilePath(url));
      try {
        if (await target.exists() && await target.length() > 0) {
          return target;
        }
      } catch (_) {}
      var bytes = await _readCachedBytesAsync(_rawFile(url));
      if (bytes == null) {
        bytes = await _download(url);
        if (bytes == null) {
          _noteFailure(_failures, url);
          return null;
        }
        await _writeAtomicallyAsync(_rawFile(url), bytes);
      }
      Uint8List? png;
      try {
        png = await _cropPool.run<Uint8List>(Uint8List.fromList(bytes));
      } catch (_) {
        png = null;
      }
      if (png == null) {
        _noteFailure(_failures, url);
        return null;
      }
      if (!await _writeAtomicallyAsync(target.path, png)) {
        _noteFailure(_failures, url);
        return null;
      }
      return target;
    });
  }

  /// Cropped file only if already rendered on disk.
  /// Uses async file check to prevent UI thread blocking.
  Future<File?> cachedFile(String url) async {    if (url.trim().isEmpty) return null;
    try {
      final target = File(croppedFilePath(url));
      if (await target.exists() && await target.length() > 0) return target;
      return null;
    } catch (_) {
      return null;
    }
  }
}

int _tmpNonceSuffix = 0;

/// Process-unique temp-file suffix.
int _tmpNonce() => (_tmpNonceSuffix = (_tmpNonceSuffix + 1) & 0xFFFF);
