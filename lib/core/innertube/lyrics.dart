// Timed lyrics from the public LRCLIB API (no key required), plus the
// provider's album name (used only as a fallback; YouTube metadata is
// preferred). Ported from `Net.kt` (`fetchLyricsAndAlbum` and friends).

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

const _lrclibUa = 'NixieTube/1.0';

/// How many extra attempts a flaky LRCLIB call gets.
const _lrclibRetries = 2;

/// Delay before the first retry; doubles on each further one.
/// Tests shrink it to zero.
Duration lrclibRetryDelay = const Duration(milliseconds: 800);

/// Status codes worth retrying: rate limiting (429) and
/// transient server errors. Anything else — a 404 is LRCLIB's
/// "no such lyrics" answer — is final.
bool _retryable(int status) => status == 429 || status >= 500;

/// Shared HTTP client, mirroring the Kotlin client's single
/// lifetime client: keeps connections warm across lookups
/// instead of handshaking per track change.
final http.Client _sharedClient = http.Client();

/// GETs [url] with a retry + backoff for transient failures
/// (rate limits, 5xx, dropped connections). A 404 or a
/// successful response is returned as-is.
Future<http.Response> _getWithRetry(http.Client client, Uri url) async {
  var delay = lrclibRetryDelay;
  for (var attempt = 0;; attempt++) {
    http.Response? res;
    try {
      res = await client
          .get(url, headers: {'User-Agent': _lrclibUa})
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      if (attempt >= _lrclibRetries) rethrow;
    }
    if (res != null &&
        (!_retryable(res.statusCode) || attempt >= _lrclibRetries)) {
      return res;
    }
    await Future<void>.delayed(delay);
    delay = delay * 2;
  }
}

/// One LRCLIB lyric candidate with the metadata used to rank it.
class _Candidate {
  _Candidate(this.lines, this.album, this.title, this.artist, this.durationSec);

  final List<LyricLine> lines;
  final String? album;
  final String title;
  final String artist;
  final int durationSec;

  /// True when this candidate's title/artist match the requested track.
  bool matches(String requestedTitle, String requestedArtist) {
    if (normalizeLrc(title) != normalizeLrc(requestedTitle)) return false;
    final requested = normalizeLrc(requestedArtist);
    final actual = normalizeLrc(artist);
    if (requested.isEmpty || actual.isEmpty) return requested.isEmpty;
    if (requested == actual) return true;
    final requestedTokens = requested
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    final actualTokens = actual.split(' ').where((t) => t.isNotEmpty).toSet();
    return requestedTokens.isNotEmpty &&
        actualTokens.containsAll(requestedTokens);
  }
}

/// Normalizes a title/artist for fuzzy matching by stripping features,
/// editions and punctuation.
String normalizeLrc(String value) {
  var n = value.toLowerCase();
  n = n.replaceAll(
    RegExp(r'''\s*[\(\[]?(feat\.?|ft\.?|with|con)\b[^)\]]*[\)\]]?'''),
    '',
  );
  n = n.replaceAll(
    RegExp(
      r'\s*[–—-]\s*(remaster|remix|edit|live|acoustic|sped up|slowed|mix|version|single|ep)\b.*$',
    ),
    '',
  );
  n = n.replaceAll(RegExp(r'[^a-z0-9 ]'), '');
  n = n.replaceAll(RegExp(r'\s+'), ' ');
  return n.trim();
}

_Candidate? _candidateFrom(dynamic el) {
  if (el is! Map) return null;
  final title = (el['trackName'] is String
      ? (el['trackName'] as String).trim()
      : '');
  final artist = (el['artistName'] is String
      ? (el['artistName'] as String).trim()
      : '');
  if (title.isEmpty || artist.isEmpty) return null;
  var album = el['albumName'] is String
      ? (el['albumName'] as String).trim()
      : '';
  if (album.isEmpty) album = '';
  final duration = el['duration'];
  final durationSec = duration is num
      ? duration.toInt()
      : int.tryParse((duration as String?) ?? '') ?? 0;
  return _Candidate(
    _lyricsFrom(el),
    album.isEmpty ? null : album,
    title,
    artist,
    durationSec,
  );
}

/// Extracts lyric lines from one LRCLIB JSON object, preferring synced
/// over plain lyrics.
List<LyricLine> _lyricsFrom(dynamic el) {
  if (el is! Map) return [];
  final synced = el['syncedLyrics'];
  if (synced is String && synced.trim().isNotEmpty) {
    final parsed = parseLrc(synced);
    if (parsed.isNotEmpty) return parsed;
  }
  final plain = el['plainLyrics'];
  if (plain is String && plain.trim().isNotEmpty) {
    return plain
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .map((line) => LyricLine(timeMs: -1, text: line))
        .toList();
  }
  return [];
}

final _lrcRe = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\](.*)');

/// Parses synced `[mm:ss.xx] text` lyric lines, skipping blank rows.
List<LyricLine> parseLrc(String lrc) {
  final out = <LyricLine>[];
  for (final line in lrc.split('\n')) {
    final m = _lrcRe.firstMatch(line.trim());
    if (m == null) continue;
    final min = int.tryParse(m.group(1) ?? '');
    final sec = int.tryParse(m.group(2) ?? '');
    if (min == null || sec == null) continue;
    final fracStr = (m.group(3) ?? '').padRight(3, '0').substring(0, 3);
    final frac = int.tryParse(fracStr) ?? 0;
    final text = (m.group(4) ?? '').trim();
    if (text.isEmpty) continue;
    out.add(LyricLine(timeMs: min * 60000 + sec * 1000 + frac, text: text));
  }
  return out;
}

/// Fetches lyrics from LRCLIB, preferring a direct match and falling back
/// to the best search hit. Returns the lines with the provider's album name
/// (null when nothing matches or on failure).
Future<({List<LyricLine> lines, String? album})> fetchLyricsAndAlbum(
  String artist,
  String title,
  String album,
  int durationSec, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? _sharedClient;
  try {
    Future<_Candidate?> tryGet(String url) async {
      try {
        final res = await _getWithRetry(
          client,
          Uri.parse(url),
        );
        return _candidateFrom(jsonDecode(res.body));
      } catch (_) {
        return null;
      }
    }

    final params = {
      'artist_name': artist,
      'track_name': title,
      if (album.trim().isNotEmpty) 'album_name': album,
      if (durationSec > 0) 'duration': '$durationSec',
    };
    final direct = await tryGet(
      'https://lrclib.net/api/get?${Uri(queryParameters: params).query}',
    );
    final directAlbum = (direct != null && direct.matches(title, artist))
        ? direct.album
        : null;
    if (direct != null &&
        direct.matches(title, artist) &&
        direct.lines.isNotEmpty) {
      return (lines: direct.lines, album: direct.album);
    }
    final searchParams = {'track_name': title, 'artist_name': artist};
    List<_Candidate> candidates = [];
    try {
      final res = await _getWithRetry(
        client,
        Uri.parse(
          'https://lrclib.net/api/search?${Uri(queryParameters: searchParams).query}',
        ),
      );
      final arr = jsonDecode(res.body);
      if (arr is List) {
        candidates = arr
            .map(_candidateFrom)
            .whereType<_Candidate>()
            .where((c) => c.matches(title, artist))
            .toList();
      }
    } catch (_) {}
    _Candidate? best;
    int bestScore0 = -1;
    int bestScore1 = -1;
    int bestScore2 = -1;
    for (final c in candidates) {
      final s0 = c.lines.any((line) => line.timeMs >= 0) ? 1 : 0;
      final s1 = (durationSec > 0 && c.durationSec > 0)
          ? 100 - (c.durationSec - durationSec).abs().clamp(0, 100)
          : 0;
      final s2 = (c.album == null || c.album!.isEmpty) ? 0 : 1;
      if (s0 > bestScore0 ||
          (s0 == bestScore0 &&
              (s1 > bestScore1 || (s1 == bestScore1 && s2 > bestScore2)))) {
        best = c;
        bestScore0 = s0;
        bestScore1 = s1;
        bestScore2 = s2;
      }
    }
    if (best != null) {
      return (lines: best.lines, album: best.album ?? directAlbum);
    }
    return (lines: <LyricLine>[], album: directAlbum);
  } catch (_) {
    return (lines: <LyricLine>[], album: null);
  } finally {
    // Injected clients belong to the caller; the shared
    // one lives for the app's lifetime (like Kotlin's).
    if (httpClient != null) client.close();
  }
}

/// Fetches lyric lines for the given track metadata.
Future<List<LyricLine>> fetchLyrics(
  String artist,
  String title,
  String album,
  int durationSec, {
  http.Client? httpClient,
}) async {
  final res = await fetchLyricsAndAlbum(
    artist,
    title,
    album,
    durationSec,
    httpClient: httpClient,
  );
  return res.lines;
}
