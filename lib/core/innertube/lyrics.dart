// Timed lyrics from the public LRCLIB API (no key required), plus the
// provider's album name (used only as a fallback; YouTube metadata is
// preferred). Ported from `Net.kt` (`fetchLyricsAndAlbum` and friends).

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../sys/http_client.dart';
import '../models/models.dart';
import 'inner_tube.dart' show InnerTube;
import 'json.dart';

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
final Dio _sharedClient = newHttpClient();

/// GETs [url] with a retry + backoff for transient failures
/// (rate limits, 5xx, dropped connections). A 404 or a
/// successful response is returned as-is.
Future<Response<String>> _getWithRetry(Dio client, Uri url) async {
  var delay = lrclibRetryDelay;
  for (var attempt = 0; ; attempt++) {
    Response<String>? res;
    try {
      res = await client
          .getUri<String>(
            url,
            options: Options(headers: {'User-Agent': _lrclibUa}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      if (attempt >= _lrclibRetries) rethrow;
    }
    if (res != null &&
        (!_retryable(res.statusCode ?? 0) || attempt >= _lrclibRetries)) {
      return res;
    }
    await Future<void>.delayed(delay);
    delay = delay * 2;
  }
}

/// One LRCLIB lyric candidate with the metadata used to rank it.
class _Candidate {
  _Candidate(
    this.lines,
    this.album,
    this.title,
    this.artist,
    this.durationSec, {
    this.id,
  });

  final List<LyricLine> lines;
  final String? album;
  final String title;
  final String artist;
  final int durationSec;

  /// LRCLIB entry id, for de-duplicating merged search rounds.
  final int? id;

  /// True when this candidate's title/artist match the requested track.
  /// Titles match normalized-equal, or with every parenthesized /
  /// bracketed segment stripped — either side may carry "(extended)"
  /// or "[Remix]" credits the other lacks. Artists match when either
  /// token set contains the other, so "UK Apache, SHY FX" still hits
  /// a "UK Apache"-only entry and vice versa.
  bool matches(String requestedTitle, String requestedArtist) {
    final wantTitle = normalizeLrc(requestedTitle);
    final gotTitle = normalizeLrc(title);
    final wantBase = _baseTitle(requestedTitle);
    final gotBase = _baseTitle(title);
    final titleOk =
        (wantTitle.isNotEmpty && wantTitle == gotTitle) ||
        (wantBase.isNotEmpty && wantBase == gotBase);
    if (!titleOk) return false;
    final requested = normalizeLrc(requestedArtist);
    final actual = normalizeLrc(artist);
    if (requested.isEmpty || actual.isEmpty) return requested.isEmpty;
    final requestedTokens = _tokens(requested);
    final actualTokens = _tokens(actual);
    if (actualTokens.containsAll(requestedTokens) ||
        requestedTokens.containsAll(actualTokens)) {
      return true;
    }
    // Punctuation-asymmetric credits ("ACDC" vs "AC/DC"): fall
    // back to spaceless containment either way.
    final rf = requested.replaceAll(' ', '');
    final af = actual.replaceAll(' ', '');
    return af.contains(rf) || rf.contains(af);
  }
}

/// Normalizes a title/artist for fuzzy matching by stripping features,
/// editions and punctuation. Artist separators (slash, ampersand,
/// comma, …) become spaces BEFORE punctuation is stripped, so
/// "knock2/dillon" tokenizes as two artists instead of gluing
/// into "knock2dillon".
String normalizeLrc(String value) {
  var n = value.toLowerCase();
  n = n.replaceAll(
    RegExp(r'''\s*[\(\[]?(feat\.?|ft\.?|with|con)\b[^)\]]*[\)\]]?'''),
    '',
  );
  n = n.replaceAll(
    RegExp(
      r'\s*[–—-]\s*(remaster|remix|edit|live|acoustic|sped up|slowed|mix|version|single|ep|extended)\b.*$',
    ),
    '',
  );
  n = n.replaceAll(RegExp(r'[/&,;+×•|]+'), ' ');
  n = n.replaceAll(RegExp(r'[^a-z0-9 ]'), '');
  n = n.replaceAll(RegExp(r'\s+'), ' ');
  return n.trim();
}

/// Title with every parenthesized/bracketed segment removed, then
/// normalized: "rampage (extended) (feat. DJ SS)" and "rampage"
/// both become "rampage", tolerating edition leftovers on either
/// side of the comparison.
String _baseTitle(String title) => normalizeLrc(
  title
      .replaceAll(RegExp(r'\([^)]*\)'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), ''),
);

/// Space-separated tokens of an already-normalized string.
Set<String> _tokens(String normalized) =>
    normalized.split(' ').where((t) => t.isNotEmpty).toSet();

/// First artist chunk ("UK Apache, SHY FX" → "UK Apache") for the
/// simplified fallback query.
String _primaryArtist(String artist) {
  final parts = artist.split(
    RegExp(
      r'\s*(?:,|&|;|/|[+×]|\bfeat\.?|\bft\.?|\bwith\b)\s*',
      caseSensitive: false,
    ),
  );
  final first = parts.firstWhere((p) => p.trim().isNotEmpty, orElse: () => '');
  final t = first.trim();
  return t.isEmpty ? artist.trim() : t;
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
  final id = el['id'];
  return _Candidate(
    _lyricsFrom(el),
    album.isEmpty ? null : album,
    title,
    artist,
    durationSec,
    id: id is num ? id.toInt() : null,
  );
}

/// True when any line is timestamped.
bool _hasSyncedLines(List<LyricLine> lines) =>
    lines.any((line) => line.timeMs >= 0);

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
Future<({List<LyricLine> lines, String? album, bool ok})> fetchLyricsAndAlbum(
  String artist,
  String title,
  String album,
  int durationSec, {
  Dio? dio,
}) async {
  final client = dio ?? _sharedClient;
  try {
    Future<_Candidate?> tryGet(String url) async {
      try {
        final res = await _getWithRetry(client, Uri.parse(url));
        return _candidateFrom(jsonDecode(res.data ?? ''));
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
    // A synced direct hit wins immediately. A plain-only one is
    // kept as fallback while search looks for a synced cut of
    // the same song.
    _Candidate? fallback;
    String? fallbackAlbum;
    if (direct != null && direct.matches(title, artist)) {
      fallbackAlbum = direct.album;
      if (direct.lines.isNotEmpty) {
        if (_hasSyncedLines(direct.lines)) {
          return (lines: direct.lines, album: direct.album, ok: true);
        }
        fallback = direct;
      }
    }
    final searchParams = {'track_name': title, 'artist_name': artist};
    // Search LRCLIB with progressively simpler queries: the verbatim
    // YTM metadata first (exact-ish hits, cheapest when it lands),
    // then the normalized title (YTM titles like "[Chase & Status
    // Remix] (feat. IRAH)" otherwise match nothing server-side),
    // then normalized title plus the primary artist (featured
    // credits otherwise filter everything out). Stops at the first
    // round yielding synced lyrics; queries identical to an
    // earlier round are skipped.
    final normTitle = normalizeLrc(title);
    final queries = <Map<String, String>>[searchParams];
    if (normTitle.isNotEmpty && normTitle != title.toLowerCase()) {
      queries.add({'track_name': normTitle, 'artist_name': artist});
    }
    final primaryArtist = _primaryArtist(artist);
    if (primaryArtist.isNotEmpty &&
        primaryArtist.toLowerCase() != artist.trim().toLowerCase()) {
      queries.add({
        'track_name': normTitle.isNotEmpty ? normTitle : title,
        'artist_name': primaryArtist,
      });
    }
    final seenIds = <int>{};
    final candidates = <_Candidate>[];
    for (final params in queries) {
      try {
        final res = await _getWithRetry(
          client,
          Uri.parse(
            'https://lrclib.net/api/search?${Uri(queryParameters: params).query}',
          ),
        );
        final arr = jsonDecode(res.data ?? '');
        if (arr is List) {
          for (final el in arr) {
            final c = _candidateFrom(el);
            if (c == null || !c.matches(title, artist)) continue;
            final id = c.id;
            if (id != null && !seenIds.add(id)) continue;
            candidates.add(c);
          }
        }
      } catch (_) {}
      if (candidates.any((c) => _hasSyncedLines(c.lines))) break;
    }
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
      return (lines: best.lines, album: best.album ?? fallbackAlbum, ok: true);
    }
    return (lines: fallback?.lines ?? <LyricLine>[], album: fallbackAlbum, ok: true);
  } catch (_) {
    rethrow;
  } finally {
    // Injected clients belong to the caller; the shared
    // one lives for the app's lifetime (like Kotlin's).
    if (dio != null) client.close();
  }
}

/// Fetches lyric lines for the given track metadata.
Future<List<LyricLine>> fetchLyrics(
  String artist,
  String title,
  String album,
  int durationSec, {
  Dio? dio,
}) async {
  final res = await fetchLyricsAndAlbum(
    artist,
    title,
    album,
    durationSec,
    dio: dio,
  );
  return res.lines;
}

// ---------- YouTube Music lyrics ----------

/// Lyrics provider options for the Now Playing lyrics tab.
enum LyricsSource {
  /// Community lyrics from LRCLIB, timestamped when the match is synced.
  lrclib('LRCLIB'),

  /// Official lyrics from YouTube Music (Musixmatch), untimed lines.
  ytmusic('YT Music');

  const LyricsSource(this.label);

  /// Button-group label.
  final String label;

  /// Parses a persisted key, falling back to LRCLIB.
  static LyricsSource fromKey(String key) {
    for (final s in LyricsSource.values) {
      if (s.name == key) return s;
    }
    return LyricsSource.lrclib;
  }
}

const _ytmLyricsUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) '
    'Gecko/20100101 Firefox/88.0';
const _ytmLyricsOrigin = 'https://music.youtube.com';
const _ytmLyricsBase = 'https://music.youtube.com/youtubei/v1';

/// Page type of the watch-next Lyrics tab endpoint.
const _ytmLyricsPageType = 'MUSIC_PAGE_TYPE_TRACK_LYRICS';

/// Finds the lyrics-page browseId in a `next` response: the watch-next
/// tab whose endpoint page type is track-lyrics. Null when YTM has no
/// lyrics for the track (the tab is missing or marked unselectable).
String? ytmLyricsBrowseId(dynamic res) {
  final tabs = nav(res, const [
    'contents',
    'singleColumnMusicWatchNextResultsRenderer',
    'tabbedRenderer',
    'watchNextTabbedResultsRenderer',
    'tabs',
  ]);
  if (tabs is! List) return null;
  String? titled;
  for (final t in tabs) {
    if (t is! Map) continue;
    final renderer = t['tabRenderer'];
    if (renderer is! Map) continue;
    final endpoint = renderer['endpoint'];
    final browse = endpoint is Map ? endpoint['browseEndpoint'] : null;
    if (browse is! Map) continue;
    final id = browse['browseId'];
    if (id is! String || id.isEmpty) continue;
    if (renderer['unselectable'] == true) continue;
    final pageType = nav(browse, const [
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    if (pageType == _ytmLyricsPageType) return id;
    if (renderer['title'] == 'Lyrics') titled ??= id;
  }
  return titled;
}

/// Parses YT Music lyrics text from a lyrics-browse response: the
/// `musicDescriptionShelfRenderer` runs concatenated, one untimed line
/// per non-blank row. Empty when YTM has no lyrics (the unavailable
/// message renders a different shelf).
List<LyricLine> ytmLyricsFromJson(dynamic res) {
  final sections = nav(res, const [
    'contents',
    'sectionListRenderer',
    'contents',
  ]);
  if (sections is! List) return [];
  final buf = StringBuffer();
  for (final s in sections) {
    if (s is! Map) continue;
    final shelf = s['musicDescriptionShelfRenderer'];
    if (shelf is! Map) continue;
    final runs = nav(shelf, const ['description', 'runs']);
    if (runs is! List) continue;
    for (final r in runs) {
      if (r is Map && r['text'] is String) buf.write(r['text']);
    }
  }
  return buf
      .toString()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .map((line) => LyricLine(timeMs: -1, text: line.trim()))
      .toList();
}

/// Fetches lyrics from YouTube Music for [videoId]: the `next`
/// response's Lyrics tab gives a browseId whose page carries the
/// provider's (untimed) lyrics text. Empty when YTM has none.
Future<List<LyricLine>> fetchYtmLyrics(String videoId, {Dio? dio}) async {
  final client = dio ?? _sharedClient;
  try {
    Future<String> post(String path, Map<String, dynamic> body) async {
      final res = await client
          .postUri<String>(
            Uri.parse('$_ytmLyricsBase/$path?alt=json'),
            data: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': InnerTube.clientVersion(),
                  'hl': 'en',
                },
              },
              ...body,
            }),
            options: Options(
              headers: {
                'User-Agent': _ytmLyricsUa,
                'Origin': _ytmLyricsOrigin,
                'Content-Type': 'application/json',
              },
            ),
          )
          .timeout(const Duration(seconds: 30));
      return res.data ?? '';
    }

    final browseId = ytmLyricsBrowseId(
      await decodeJsonResponse(await post('next', {'videoId': videoId})),
    );
    if (browseId == null) return [];
    return ytmLyricsFromJson(
      await decodeJsonResponse(await post('browse', {'browseId': browseId})),
    );
  } catch (_) {
    rethrow;
  } finally {
    // Injected clients belong to the caller; the shared
    // one lives for the app's lifetime (like Kotlin's).
    if (dio != null) client.close();
  }
}
