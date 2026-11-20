// MusicBrainz metadata lookups: release facts for the album info panel.
//
// The public web service needs no auth, but it does require a descriptive
// User-Agent; results are cached per artist/album pair and never retried
// in a loop, so a cold panel costs at most one request.

import 'dart:convert' show jsonDecode;

import 'package:dio/dio.dart';

import 'http_client.dart' show newResilientClient;
import 'version.dart' show appVersion;

/// MusicBrainz web-service root.
const musicBrainzApiUrl = 'https://musicbrainz.org/ws/2/';

/// A release looked up by artist and title.
class MusicBrainzRelease {
  const MusicBrainzRelease({
    this.date = '',
    this.country = '',
    this.label = '',
    this.primaryType = '',
    this.secondaryTypes = const [],
    this.disambiguation = '',
    this.mbid = '',
  });

  /// Release date as MusicBrainz reports it: `YYYY`, `YYYY-MM` or
  /// `YYYY-MM-DD`.
  final String date;
  final String country;
  final String label;
  final String primaryType;
  final List<String> secondaryTypes;
  final String disambiguation;
  final String mbid;
}

/// MusicBrainz client for release metadata.
class MusicBrainzService {
  MusicBrainzService({Dio? dio}) : _dio = dio ?? newResilientClient();

  final Dio _dio;
  final Map<String, MusicBrainzRelease> _cache = {};

  /// Looks up [album] by [artist] and returns the best release match, or
  /// null when nothing matches or the request fails. [year] (the year the
  /// album page reported) breaks ties between editions.
  Future<MusicBrainzRelease?> lookupRelease(
    String artist,
    String album, {
    String? year,
  }) async {
    final cleanArtist = artist.trim();
    final cleanAlbum = album.trim();
    final cleanYear = year?.trim() ?? '';
    if (cleanArtist.isEmpty || cleanAlbum.isEmpty) return null;
    final key =
        '${cleanArtist.toLowerCase()}|${cleanAlbum.toLowerCase()}|$cleanYear';
    final cached = _cache[key];
    if (cached != null) return cached;

    final Map<String, dynamic>? data;
    try {
      final res = await _dio
          .get(
            '${musicBrainzApiUrl}release/',
            queryParameters: {
              'query':
                  'release:"${_escape(cleanAlbum)}" AND artist:"${_escape(cleanArtist)}"',
              'fmt': 'json',
              'limit': '5',
            },
            options: Options(headers: {'User-Agent': _userAgent}),
          )
          .timeout(_timeout);
      data = _decode(res.data);
    } catch (_) {
      return null;
    }
    if (data == null) return null;
    final releases = data['releases'];
    if (releases is! List) return null;

    MusicBrainzRelease? best;
    var bestScore = -1;
    for (final raw in releases) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final release = _parse(map);
      if (release == null) continue;
      var score = 0;
      final title = _string(map['title'])?.toLowerCase() ?? '';
      if (title == cleanAlbum.toLowerCase()) score += 2;
      if (cleanYear.isNotEmpty && release.date.startsWith(cleanYear)) {
        score += 4;
      }
      // Prefer the earliest date when scores tie, so a plain album page
      // lands on the original release rather than a later reissue.
      if (best == null ||
          score > bestScore ||
          (score == bestScore && _earlier(release.date, best.date))) {
        best = release;
        bestScore = score;
      }
    }
    if (best == null) return null;
    _remember(key, best);
    return best;
  }

  static bool _earlier(String a, String b) {
    if (a.isEmpty) return false;
    if (b.isEmpty) return true;
    return a.compareTo(b) < 0;
  }

  void _remember(String key, MusicBrainzRelease release) {
    if (_cache.length >= _cacheCap && !_cache.containsKey(key)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = release;
  }

  MusicBrainzRelease? _parse(Map<String, dynamic> best) {
    final group = best['release-group'];
    final rg = group is Map ? Map<String, dynamic>.from(group) : null;
    final labels = best['label-info'];
    String label = '';
    if (labels is List) {
      for (final raw in labels) {
        if (raw is! Map) continue;
        final info = raw['label'];
        if (info is Map && info['name'] is String) {
          label = info['name'] as String;
          break;
        }
      }
    }
    final secondary = <String>[];
    final rawSecondary = rg?['secondary-types'];
    if (rawSecondary is List) {
      for (final t in rawSecondary) {
        if (t is String && t.isNotEmpty) secondary.add(t);
      }
    }
    final date =
        _string(best['date']) ?? _string(rg?['first-release-date']) ?? '';
    if (date.isEmpty && label.isEmpty && rg == null) return null;
    return MusicBrainzRelease(
      date: date,
      country: _string(best['country']) ?? '',
      label: label,
      primaryType: _string(rg?['primary-type']) ?? '',
      secondaryTypes: secondary,
      disambiguation:
          _string(best['disambiguation']) ??
          _string(rg?['disambiguation']) ??
          '',
      mbid: _string(best['id']) ?? '',
    );
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Map<String, dynamic>? _decode(Object? data) {
    final decoded = data is String ? jsonDecode(data) : data;
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Escapes a Lucene query term: MusicBrainz search uses a query parser,
  /// so embedded quotes and backslashes must not break the query.
  static String _escape(String value) =>
      value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

  static const _cacheCap = 100;
  static const _timeout = Duration(seconds: 8);
  static final _userAgent =
      'NixieTube/$appVersion (https://github.com/TheTinkerersHaven/NixieTube)';
}
