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
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

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
/// centered on the larger axis; square thumbnails are returned unchanged.
/// `copyCrop` copies pixels, so the source frame is droppable and offcuts
/// never sit in memory.
///
/// No uniform-area detection happens here: cover art itself can contain
/// solid regions, so the crop is purely geometric — center the square on
/// the received rectangle and keep already-square thumbnails as-is.
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
  return cropSquare ? centerSquare(decoded) : decoded;
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

void _decodeSquareEntry(List<dynamic> args) {
  final SendPort port = args[0] as SendPort;
  try {
    port.send(_decode(args[1] as Uint8List));
  } catch (_) {
    port.send(null);
  }
}

void _decodeBannerEntry(List<dynamic> args) {
  final SendPort port = args[0] as SendPort;
  try {
    port.send(_decode(args[1] as Uint8List, cropSquare: false));
  } catch (_) {
    port.send(null);
  }
}

void _renderCropPngEntry(List<dynamic> args) {
  final SendPort port = args[0] as SendPort;
  try {
    final rendered = _decode(args[1] as Uint8List);
    port.send(rendered == null ? null : img.encodePng(rendered));
  } catch (_) {
    port.send(null);
  }
}

/// Runs [entry] with [message] on a worker isolate, returning its reply.
/// Image work never blocks the UI thread this way.
Future<T?> _onWorker<T>(
  void Function(List<dynamic>) entry,
  Uint8List message,
) async {
  final port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(entry, [port.sendPort, message]);
    final result = await port.first.timeout(const Duration(seconds: 30));
    return result as T?;
  } catch (_) {
    return null;
  } finally {
    port.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// Decodes + crops raw bytes to a square cover on a worker isolate, so
/// image work never blocks the UI thread.
Future<img.Image?> _decodeSquareIsolate(List<int> bytes) =>
    _onWorker<img.Image>(_decodeSquareEntry, Uint8List.fromList(bytes));

/// Decodes raw bytes to an uncropped banner on a worker isolate.
Future<img.Image?> _decodeBannerIsolate(List<int> bytes) =>
    _onWorker<img.Image>(_decodeBannerEntry, Uint8List.fromList(bytes));

/// Renders raw bytes to a cropped PNG on a worker isolate.
Future<Uint8List?> _renderCropPngIsolate(List<int> bytes) =>
    _onWorker<Uint8List>(_renderCropPngEntry, Uint8List.fromList(bytes));

/// Pure-Dart artwork pipeline: integrity-checked disk cache with
/// failure tracking. Decoded bitmaps are never retained in memory —
/// Flutter's image cache plus the on-disk renders are the caches, and all
/// decode/crop work runs on worker isolates.
class ArtworkStore {
  ArtworkStore({http.Client? httpClient, String? cacheDirPath})
    : _client = httpClient ?? http.Client(),
      _dirPath = cacheDirPath ?? '${cacheDir().path}/art2' {
    Directory(_dirPath).createSync(recursive: true);
  }

  final http.Client _client;
  final String _dirPath;
  final Map<String, int> _failures = {};
  final Map<String, int> _sourceFailures = {};
  final Map<String, Future<dynamic>> _inflight = {};

  void close() => _client.close();

  String _rawFile(String url) => '$_dirPath/${_sha1Hex(url)}.img';
  String _sourceFile(String url) => '$_dirPath/${_sha1Hex(url)}.source3.img';
  // `.crop2`: bump when the crop algorithm changes so previously rendered
  // (possibly mis-cropped) files are re-rendered with the new logic.
  String _croppedFile(String url) => '$_dirPath/${_sha1Hex(url)}.crop2.png';

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

  List<int>? _readCachedBytes(String path) {
    try {
      final raw = File(path).readAsBytesSync();
      if (!looksComplete(raw)) {
        try {
          File(path).deleteSync();
        } catch (_) {}
        return null;
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  void _writeAtomically(String path, List<int> bytes) {
    try {
      final tmp =
          '$path.tmp.${DateTime.now().microsecondsSinceEpoch}.${_tmpNonce()}';
      File(tmp).writeAsBytesSync(bytes, flush: true);
      File(tmp).renameSync(path);
    } catch (_) {}
  }

  Future<List<int>?> _tryDownload(String url) async {
    try {
      final effectiveUrl = url.startsWith('//') ? 'https:$url' : url;
      final res = await _client.get(Uri.parse(effectiveUrl));
      final bytes = res.bodyBytes;
      if (bytes.length > 100 && looksComplete(bytes)) return bytes;
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
  Future<img.Image?> image(String url) {
    if (url.trim().isEmpty) return Future.value();
    if ((_failures[url] ?? 0) >= maxFailures) return Future.value();
    return _keyed('img:$url', () async {
      var bytes = _readCachedBytes(_rawFile(url));
      if (bytes == null) {
        bytes = await _download(url);
        if (bytes == null) {
          _noteFailure(_failures, url);
          return null;
        }
        _writeAtomically(_rawFile(url), bytes);
      }
      try {
        return await _decodeSquareIsolate(bytes);
      } catch (_) {
        return null;
      }
    });
  }

  /// Original, uncropped banner image at served aspect ratio.
  Future<img.Image?> source(String url) {
    if (url.trim().isEmpty) return Future.value();
    if ((_sourceFailures[url] ?? 0) >= maxFailures) {
      return Future.value();
    }
    return _keyed('src:$url', () async {
      var bytes = _readCachedBytes(_sourceFile(url));
      if (bytes == null) {
        bytes = await _downloadSource(url);
        if (bytes == null) {
          _noteFailure(_sourceFailures, url);
          return null;
        }
        _writeAtomically(_sourceFile(url), bytes);
      }
      try {
        return await _decodeBannerIsolate(bytes);
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
  Future<File?> file(String url) {
    if (url.trim().isEmpty) return Future.value();
    return _keyed('file:$url', () async {
      final target = File(_croppedFile(url));
      try {
        if (target.existsSync() && target.lengthSync() > 0) {
          return target;
        }
      } catch (_) {}
      var bytes = _readCachedBytes(_rawFile(url));
      if (bytes == null) {
        bytes = await _download(url);
        if (bytes == null) {
          _noteFailure(_failures, url);
          return null;
        }
        _writeAtomically(_rawFile(url), bytes);
      }
      Uint8List? png;
      try {
        png = await _renderCropPngIsolate(bytes);
      } catch (_) {
        png = null;
      }
      if (png == null) {
        _noteFailure(_failures, url);
        return null;
      }
      try {
        _writeAtomically(target.path, png);
      } catch (_) {
        _noteFailure(_failures, url);
        return null;
      }
      return target;
    });
  }

  /// Cropped file only if already rendered on disk.
  File? cachedFile(String url) {
    if (url.trim().isEmpty) return null;
    try {
      final target = File(_croppedFile(url));
      if (target.existsSync() && target.lengthSync() > 0) return target;
      return null;
    } catch (_) {
      return null;
    }
  }
}

int _tmpNonceSuffix = 0;

/// Process-unique temp-file suffix.
int _tmpNonce() => (_tmpNonceSuffix = (_tmpNonceSuffix + 1) & 0xFFFF);
