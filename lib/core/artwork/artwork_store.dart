// Pure-Dart artwork pipeline: integrity-checked disk cache with failure
// tracking. Downloads thumbnails and exposes stable rendered files;
// square tiles display YouTube's own square art (or fetched album art)
// exactly as served — no client-side crop and no bar trimming — so a
// cover that ships with its own black border keeps it. Decode work runs
// on worker isolates and nothing decoded is retained in memory.

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

/// Age after which a cached artwork file no longer earns its disk
/// space: files older than this are deleted on the next startup's
/// prune pass and simply re-download on demand if they are used again.
const artworkMaxAge = Duration(days: 30);

/// Soft ceiling for the whole artwork cache. A prune pass that finds
/// more than this on disk deletes the oldest files until the cache is
/// back under it, so a long browsing session cannot bloat the disk.
/// (A 30-day age and this cap keep the store bounded even when the app
/// runs for weeks between restarts.)
const artworkMaxBytes = 512 << 20;

/// Consecutive download failures before a URL is skipped. Each failure
/// is already the end of a retry ladder ([newResilientClient] retries
/// transient statuses and transport blips several times), so this is
/// the last resort: a url must fail its whole budget this many times
/// before the session stops trying it. Cleared by `clearCache`.
const maxFailures = 5;

/// `maxresdefault.jpg` guess for `i.ytimg.com` video stills: the Data
/// API often lists only `hqdefault` (480px) while the 1280px still
/// exists. Tried first, original kept as fallback (a 404 lands as a
/// normal response and falls through the same null path).
String? maxResGuess(String url) {
  final m = RegExp(r'https://i\.ytimg\.com/vi/([^/]+)/').firstMatch(url);
  if (m == null || url.contains('maxresdefault')) return null;
  return 'https://i.ytimg.com/vi/${m.group(1)}/maxresdefault.jpg';
}

/// Rewrites a thumbnail URL to request a ~1080px cover, preserving the
/// source aspect ratio (the server clamps to the original when it is
/// smaller, so this never invents pixels). Tiles decode up to
/// 360px×devicePixelRatio, and anything smaller upscales into grain.
/// Forcing a square box (`=w540-h540`) makes the image service
/// letterbox/crop non-square art server-side before we ever see the
/// true rectangle — which crops too close. Keeping the ratio means a
/// non-square thumbnail arrives non-square, and callers pick a true
/// square (YouTube square art or album art) instead.
String upgradeArt(String url) {
  final re = RegExp(r'=w(\d+)-h(\d+)([^?]*)$');
  final m = re.firstMatch(url);
  if (m == null) return url;
  final w = int.tryParse(m.group(1) ?? '') ?? 0;
  final h = int.tryParse(m.group(2) ?? '') ?? 0;
  if (w <= 0 || h <= 0) return url;
  const target = 1080;
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

/// A PNG file header, used to identify stored bytes — not to parse them.
const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Numbers a payload's container from its magic bytes: every stored
/// file is named for the format it actually holds, so file paths (and
/// the URIs built on them, like MPRIS artwork) report correctly.
String _extensionFor(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return '.jpg';
  if (bytes.length >= _pngSignature.length) {
    var isPng = true;
    for (var i = 0; i < _pngSignature.length; i++) {
      if (bytes[i] != _pngSignature[i]) {
        isPng = false;
        break;
      }
    }
    if (isPng) return '.png';
  }
  // RIFF....WEBP
  final isWebp =
      bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
  if (isWebp) return '.webp';
  return '.img';
}

/// How many header bytes a size sniff may read: enough for any
/// JFIF header this cache writes (ours carry no EXIF thumbnails).
const _headerReadMax = 128 << 10;

/// Pixel dimensions parsed straight from the container header: PNG's
/// IHDR word-pair, and JPEG's SOFn segment found by walking the marker
/// list (baseline and progressive). WebP and unknown containers return
/// null — the callers decode those unbounded rather than guess an
/// aspect ratio.
(int, int)? _sizeFromHeader(List<int> bytes) {
  int read16(int i) => (bytes[i] << 8) | bytes[i + 1];
  int read32(int i) =>
      (bytes[i] << 24) |
      (bytes[i + 1] << 16) |
      (bytes[i + 2] << 8) |
      bytes[i + 3];
  // PNG: signature, then the IHDR chunk header (length 13, "IHDR",
  // then two big-endian 32-bit words: width, height) at 16..24.
  if (bytes.length >= 24) {
    var isPng = true;
    for (var i = 0; i < _pngSignature.length; i++) {
      if (bytes[i] != _pngSignature[i]) {
        isPng = false;
        break;
      }
    }
    if (isPng) {
      final width = read32(16);
      final height = read32(20);
      if (width > 0 && height > 0) return (width, height);
    }
  }
  // JPEG: skip the SOI, walk each marker's length until a SOFn; the
  // height then width sit two bytes into the segment header.
  if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var i = 2;
    while (i + 9 <= bytes.length) {
      if (bytes[i] != 0xFF) break;
      final marker = (bytes[i] << 8) | bytes[i + 1];
      if (marker >= 0xFFC0 && marker <= 0xFFCF) {
        // SOF0..SOF15 except DHT/C4, JPG/C8, DAC/CC carry dimensions.
        if (marker != 0xFFC4 && marker != 0xFFC8 && marker != 0xFFCC) {
          final height = read16(i + 5);
          final width = read16(i + 7);
          if (width > 0 && height > 0) return (width, height);
          break;
        }
      }
      // APPn/COM and segment framing skip by declared length.
      if (marker == 0xFFD8 || marker == 0xFFD9 || (marker & 0x00F8) == 0xFFD0) {
        i += 2; // standalone markers carry no length
        continue;
      }
      i += 2 + read16(i + 2);
    }
  }
  return null;
}

/// Decodes image bytes exactly as served — no client-side crop and no
/// bar trimming. A cover that ships with its own black frame (square
/// art with a printed border) keeps it; tiles show YouTube's own square
/// art as-is rather than cropping it.
img.Image? _decode(List<int> bytes) {
  try {
    return img.decodeImage(Uint8List.fromList(bytes));
  } catch (_) {
    return null;
  }
}

/// Re-encodes an image payload as a JPEG at quality 85 on a worker
/// isolate, so the disk cache stores a compact copy instead of the
/// full-resolution original (which can be several MB). Returns the
/// original bytes unchanged when decoding fails or the payload is
/// already small enough that re-encoding would not help. Lossless
/// PNGs (transparency) are kept as-is.
Future<Uint8List> _compressBytes(Uint8List bytes) async {
  if (bytes.length < 64 * 1024) return bytes;
  // Only re-encode JPEGs; PNGs are already compressed and re-encoding
  // them to JPEG would cost quality for no benefit (and could break
  // callers that rely on lossless pixels).
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return bytes;
  }
  try {
    return await Isolate.run<Uint8List>(() {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      if (decoded.hasAlpha) return bytes;
      try {
        return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
      } catch (_) {
        return bytes;
      }
    });
  } catch (_) {
    return bytes;
  }
}

/// Cover palette for tinted backdrops: average colors of a
/// 5x5 grid over the cover (row-major: TL→BR). Port of
/// Kotlin `coverBands`, extended from 3 horizontal bands
/// to 25 points so the wash can follow the whole artwork.
/// Null when the image is empty.
///
/// The sampling window is inset from the edges: border and vignette
/// pixels would otherwise dominate the outer rows and columns.
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

/// Persistent worker main: one warm isolate per pool, listening for jobs
/// and replying on each job's own reply port. Spawned once and reused,
/// so artwork loads never pay an isolate spawn per decode.
void _workerMain(List<dynamic> args) {
  final SendPort announce = args[0] as SendPort;
  final jobs = ReceivePort();
  announce.send(jobs.sendPort);
  jobs.listen((dynamic message) {
    final job = message as List<dynamic>;
    final SendPort replyTo = job[0] as SendPort;
    final Uint8List bytes = job[1] as Uint8List;
    try {
      // Banner and image jobs share one decode (full frame, never
      // cropped or trimmed). Tile renders no longer produce a
      // separate file: the UI decodes directly from the cached
      // (compressed) source bytes.
      final rendered = _decode(bytes);
      replyTo.send(rendered);
    } catch (_) {
      replyTo.send(null);
    }
    // This worker is free again: re-offer it so the pool can dispatch
    // the next queued job. Without this the pool only ever sees each
    // worker idle once and stalls after its first `_poolSize` jobs.
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
  _ArtPool();

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
      _isolates.add(Isolate.spawn(_workerMain, [_announce!.sendPort]));
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
/// decode work runs on worker isolates.
class ArtworkStore {
  ArtworkStore({
    Dio? dio,
    String? cacheDirPath,
    this.maxAge = artworkMaxAge,
    this.maxBytes = artworkMaxBytes,
  }) : _dio = dio ?? newResilientClient(),
       _dirPath = cacheDirPath ?? '${cacheDir().path}/art2',
       _imagePool = _ArtPool(),
       _bannerPool = _ArtPool() {
    // Ensure directory exists - use sync for constructor, but this is fine
    // as it only happens once during initialization
    Directory(_dirPath).createSync(recursive: true);
    // Startup prune is async and unawaited: an old file's deletion can
    // wait a frame, and construction must not block the first display.
    unawaited(prune());
  }

  /// cached artwork older than this is deleted by [prune].
  final Duration maxAge;

  /// Files beyond this total are evicted oldest-first by [prune].
  /// Defaults to [artworkMaxBytes]; tests pass a smaller value.
  final int maxBytes;

  final Dio _dio;
  final String _dirPath;
  final Map<String, int> _failures = {};
  final Map<String, int> _sourceFailures = {};
  final Map<String, Future<dynamic>> _inflight = {};

  /// Stems whose on-disk file has been located (and, after [_store],
  /// where it was written). Memoized so repeated checks (MPRIS polls
  /// its artwork path, the library re-renders) never stat the disk;
  /// [clearCache] drops the memo with the files it points at.
  final Map<String, String> _resolved = {};

  /// Stems whose header size has been read ([_headerReadMax] bytes),
  /// so a tile's bounded decode target is resolved from disk once.
  final Map<String, (int, int)> _sizes = {};

  final _ArtPool _imagePool;
  final _ArtPool _bannerPool;

  /// Shuts down the HTTP client and the worker pools. In-flight jobs
  /// fail fast; call once at app/test teardown.
  void close() {
    _dio.close();
    _imagePool.dispose();
    _bannerPool.dispose();
  }

  /// Deletes every cached artwork file (raw bytes and tile renders) so
  /// the next display re-downloads and re-renders from scratch. Also
  /// resets the failure skip-lists, the path memo and the banner memo:
  /// without this, previously-failed URLs would stay skipped, paths
  /// would point at deleted files, and banners would keep serving stale
  /// bytes, so the clear would only partly take. Used by the Settings
  /// "Clear artwork cache" debug action (which additionally evicts
  /// Flutter's in-memory image cache — same-path re-renders would
  /// otherwise decode from memory and look unchanged).
  void clearCache() {
    _failures.clear();
    _sourceFailures.clear();
    _resolved.clear();
    _sizes.clear();
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

  // Naming: `{sha}<ext>` (and `{sha}.source<ext>` for banner sources),
  // where <ext> reports the stored format (jpg/png/webp, .img when
  // nothing matched). The legacy `{sha}.img4` and `{sha}.source4.img`
  // names are still read, so files written by earlier releases keep
  // serving until [prune] ages them out.
  String _stem(String url) => '$_dirPath/${_sha1Hex(url)}';

  /// On-disk path of the cached (compressed) source bytes for [url].
  /// Tiles and the UI decode directly from this file, so there is no
  /// separate rendered copy on disk. Format-suffix resolved via the
  /// memo (or a bounded sync probe); the legacy name is the fallback
  /// while a download is still in flight.
  String tileFilePath(String url) {
    final stem = _stem(url);
    final hit = _resolved[stem];
    if (hit != null && hit.isNotEmpty) return hit;
    for (final path in _variants(stem, '$stem.img4')) {
      try {
        if (File(path).existsSync()) {
          _resolved[stem] = path;
          _capResolved();
          return path;
        }
      } catch (_) {}
    }
    return '$stem.img4';
  }

  /// Suffixes a stored file may carry, tried in read order.
  static const _readExts = ['.jpg', '.png', '.webp', '.img'];

  /// Every name the stem's payload could live under right now: the
  /// current format suffixes plus the generation's legacy name.
  List<String> _variants(String stem, String legacy) => [
    for (final ext in _readExts) '$stem$ext',
    legacy,
  ];

  void _capResolved() {
    while (_resolved.length > maxFailureKeys) {
      _resolved.remove(_resolved.keys.first);
    }
  }

  /// Path of the stored file for [stem], found from the memo or by
  /// probing the current and legacy names once. Null when nothing is
  /// stored (the negative result is not memoized: the file can appear
  /// the moment a download finishes).
  Future<String?> _cachedPath(String stem, String legacy) async {
    final hit = _resolved[stem];
    if (hit != null) return hit;
    for (final path in _variants(stem, legacy)) {
      try {
        if (await File(path).exists()) {
          _resolved[stem] = path;
          _capResolved();
          return path;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Reads the stored bytes for [stem] through the memoized probe.
  /// Null when nothing is stored, or the memoized file vanished (it is
  /// forgotten there so a re-probe can find a re-rendered copy).
  Future<List<int>?> _readCached(String stem, String legacy) async {
    final path = await _cachedPath(stem, legacy);
    if (path == null) return null;
    final bytes = await _readCachedBytesAsync(path);
    if (bytes == null && _resolved[stem] == path) {
      // The memoized path is unreadable; the integrity check already
      // deleted the incomplete file. Forget it.
      _resolved.remove(stem);
    }
    return bytes;
  }

  /// Stores [bytes] for [stem], naming the file for the format the
  /// bytes actually carry, and removes every other name (legacy ones
  /// included) so one URL maps to exactly one file. Returns the path.
  Future<String> _store(String stem, String legacy, List<int> bytes) async {
    final path = '$stem${_extensionFor(bytes)}';
    await _writeAtomicallyAsync(path, bytes);
    for (final variant in _variants(stem, legacy)) {
      if (variant == path) continue;
      try {
        final f = File(variant);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _resolved[stem] = path;
    _capResolved();
    return path;
  }

  /// Deletes cached artwork older than [maxAge], then trims the
  /// contents back under [maxBytes] by deleting the oldest files
  /// first. Runs unawaited at startup; safe to call again, and a file
  /// that vanishes under the pass (a `.tmp` rename or a clear) is
  /// skipped, not reported.
  Future<void> prune() async {
    try {
      final dir = Directory(_dirPath);
      if (!dir.existsSync()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      final keep = <(File, DateTime, int)>[];
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        try {
          final modified = entry.lastModifiedSync();
          if (modified.isBefore(cutoff)) {
            try {
              await entry.delete();
            } catch (_) {}
            continue;
          }
          keep.add((entry, modified, await entry.length()));
        } catch (_) {}
      }
      var total = 0;
      for (final (_, _, size) in keep) {
        total += size;
      }
      if (total <= maxBytes) return;
      keep.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (file, _, size) in keep) {
        if (total <= maxBytes) break;
        try {
          await file.delete();
          total -= size;
        } catch (_) {
          // Deleted by a concurrent clear or prune pass under us:
          // treat a vanished file as removed, or its phantom bytes
          // would keep evicting newer files than needed.
          try {
            if (!file.existsSync()) total -= size;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

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
    unawaited(
      future.whenComplete(() {
        if (identical(_inflight[url], future)) unawaited(_inflight.remove(url));
      }),
    );
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
      // Error pages (404 HTML and friends) must not pass as art: the
      // download chain falls through to the next candidate instead.
      final contentType = res.headers.value('content-type') ?? '';
      if (contentType.startsWith('text/')) return null;
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
    final guess = maxResGuess(url);
    if (guess != null) {
      final bytes = await _tryDownload(guess);
      if (bytes != null) return bytes;
    }
    final upgraded = upgradeArt(url);
    if (upgraded != url) {
      final bytes = await _tryDownload(upgraded);
      if (bytes != null) return bytes;
    }
    return _tryDownload(url);
  }

  /// Decoded cover for [url] (whole frame, uncropped), downloading and
  /// caching on miss. Decode runs on a worker isolate; nothing decoded
  /// is retained. Uses async file operations to prevent UI thread
  /// blocking.
  Future<img.Image?> image(String url) {
    if (url.trim().isEmpty) return Future.value();
    if ((_failures[url] ?? 0) >= maxFailures) return Future.value();
    return _keyed('img:$url', () async {
      final stem = _stem(url);
      final legacy = '$stem.img4';
      var bytes = await _readCached(stem, legacy);
      if (bytes == null) {
        bytes = await _download(url);
        if (bytes == null) {
          _noteFailure(_failures, url);
          return null;
        }
        final compressed = await _compressBytes(Uint8List.fromList(bytes));
        await _store(stem, legacy, compressed);
        bytes = compressed;
      }
      try {
        return await _imagePool.run<img.Image>(Uint8List.fromList(bytes));
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
      unawaited(_bannerPng.remove(_bannerPng.keys.first));
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
      final stem = '${_stem(url)}.source';
      final legacy = '${stem}4.img'; // legacy: `{sha}.source4.img`
      var bytes = await _readCached(stem, legacy);
      if (bytes == null) {
        bytes = await _downloadSource(url);
        if (bytes == null) {
          _noteFailure(_sourceFailures, url);
          return null;
        }
        final compressed = await _compressBytes(Uint8List.fromList(bytes));
        await _store(stem, legacy, compressed);
        bytes = compressed;
      }
      try {
        return await _bannerPool.run<img.Image>(Uint8List.fromList(bytes));
      } catch (_) {
        return null;
      }
    });
  }

  Future<List<int>?> _downloadSource(String url) async {
    final candidates = <String>[
      upscaleArtworkUrl(url, 1920),
      url,
      _originalArt(url),
    ];
    final guess = maxResGuess(url);
    if (guess != null) candidates.insert(0, guess);
    // Deduplicate while preserving order (upgrades can no-op).
    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate)) continue;
      final bytes = await _tryDownload(candidate);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Whole-frame render for [url] (the single stored file), downloading
  /// on miss. Uses async file operations to prevent UI thread blocking.
  Future<File?> file(String url) {
    if (url.trim().isEmpty) return Future.value();
    return _keyed('file:$url', () async {
      final stem = _stem(url);
      final legacy = '$stem.img4';
      final cachedPath = await _cachedPath(stem, legacy);
      if (cachedPath != null) {
        final target = File(cachedPath);
        try {
          if (await target.length() > 0) return target;
        } catch (_) {}
        // The memoized path vanished (pruned or cleared under us).
        if (_resolved[stem] == cachedPath) _resolved.remove(stem);
      }
      var bytes = await _readCached(stem, legacy);
      if (bytes == null) {
        bytes = await _download(url);
        if (bytes == null) {
          _noteFailure(_failures, url);
          return null;
        }
        final compressed = await _compressBytes(Uint8List.fromList(bytes));
        final path = await _store(stem, legacy, compressed);
        return File(path);
      }
      // Reads only happen when the file existed; the probe memoized
      // its path.
      final memo = _resolved[stem];
      return memo == null ? null : File(memo);
    });
  }

  /// The stored file only if it is already on disk.
  /// Uses async file check to prevent UI thread blocking.
  Future<File?> cachedFile(String url) async {
    if (url.trim().isEmpty) return null;
    final stem = _stem(url);
    final path = await _cachedPath(stem, '$stem.img4');
    if (path == null) return null;
    return File(path);
  }

  /// Pixel size of the stored file for [url], read from the container
  /// header alone (no full decode, no isolate), memoized per URL.
  /// Null when the format's header is not understood or carries no
  /// dimensions.
  ///
  /// Tiles bound their decodes to the box they actually show, which
  /// needs the source's aspect ratio: a 16:9 still must decode its
  /// WIDTH so its height still reaches the box short side, a portrait
  /// frame the other way round a square cover straight. Guessing costs
  /// either crispness (too small on the short side) or memory (a
  /// 1080px bitmap for a 200px tile).
  Future<(int, int)?> tileSize(String url) async {
    if (url.trim().isEmpty) return null;
    final stem = _stem(url);
    final hit = _sizes[stem];
    if (hit != null) return hit;
    final path = await _cachedPath(stem, '$stem.img4');
    if (path == null) return null;
    try {
      final raf = await File(path).open();
      try {
        final length = await raf.length();
        if (length == 0) return null;
        final bytes = await raf.read(
          length > _headerReadMax ? _headerReadMax : length,
        );
        final dims = _sizeFromHeader(bytes);
        if (dims != null) {
          _sizes[stem] = dims;
          while (_sizes.length > maxFailureKeys) {
            _sizes.remove(_sizes.keys.first);
          }
        }
        return dims;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}

int _tmpNonceSuffix = 0;

/// Process-unique temp-file suffix.
int _tmpNonce() => (_tmpNonceSuffix = (_tmpNonceSuffix + 1) & 0xFFFF);
