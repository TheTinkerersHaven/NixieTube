// Pure metadata helpers ported from the Kotlin client's companion logic
// (artist fixup, album inference, durations, music/region filters).
//
// No networking here — pure helpers the InnerTube client calls.

import 'dart:io' show Platform;

import '../models/models.dart';

/// YouTube topic id for music.
const musicTopicId = '/m/04rlf';

/// The deleted/private video stub id, never a real track.
const deletedVideoId = 'UCBR8-60-B28hp2BmDPdntcQ';

/// Lowercases, maps every non-alphanumeric run to a single space, trims.
String canonical(String value) {
  final buf = StringBuffer();
  for (final c in value.runes) {
    final ch = String.fromCharCode(c);
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(ch)) {
      buf.write(ch.toLowerCase());
    } else if (!buf.toString().endsWith(' ')) {
      buf.write(' ');
    }
  }
  return buf.toString().split(RegExp(r'\s+')).join(' ').trim();
}

bool _isFourDigitYear(String v) =>
    v.length == 4 &&
    (v.startsWith('19') || v.startsWith('20')) &&
    int.tryParse(v) != null;

/// True when a subtitle token is release metadata rather than a
/// credit ("Single", "EP", "2024", "Official Audio"). Used to keep
/// type/year tags out of artist names.
bool isReleaseNoise(String value) {
  const noise = {
    'release',
    'single',
    'ep',
    'album',
    'compilation',
    'music',
    'song',
    'video',
    'official',
    'audio',
    'lyrics',
    'lyric video',
  };
  final v = canonical(value);
  if (noise.contains(v)) return true;
  return _isFourDigitYear(v);
}

/// True for auto-generated distributor channels ("Release",
/// "Release - Topic") as opposed to real artist channels.
bool isGenericReleaseOwner(String owner) {
  final t = owner.trim().toLowerCase();
  return t == 'release' || t == 'release - topic';
}

/// True for a bare release-type token ("album", "single", "EP").
bool isReleaseTypeTag(String value) {
  const tags = {'album', 'single', 'compilation', 'mixtape', 'ep'};
  return tags.contains(canonical(value));
}

/// True when a subtitle mentions a release type anywhere, including
/// the spellings the token check misses ("E.P.", "eptrack"). Broader
/// than [isReleaseTypeTag] for free-form subtitles.
bool hasReleaseType(String value) {
  final compact = value.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  final tokens = canonical(value).split(' ');
  return isReleaseTypeTag(value) ||
      tokens.any(
        (t) =>
            t == 'album' ||
            t == 'single' ||
            t == 'compilation' ||
            t == 'mixtape',
      ) ||
      value.toLowerCase().contains('e.p.') ||
      compact == 'ep' ||
      compact.contains('eptrack');
}

/// True when [track]'s credit is the generic distributor placeholder
/// ("Release") rather than a real artist.
///
/// Distributor uploads ("Release - Topic" channels) often carry no
/// artist in their tags, so `fixup` falls back to the
/// placeholder and only InnerTube's watch-next panel names the real
/// credit. Such tracks need [InnerTube.enrichTrack] to heal.
bool hasGenericReleaseArtist(Track track) {
  if (track.artists.isEmpty) return true;
  return canonical(track.artistNames()) == 'release';
}

/// "Daft Punk - Topic" -> "Daft Punk", "AdeleVEVO" -> "Adele".
String normalizeArtist(String name) {
  var n = name.trim();
  if (n.length > 8 && n.toLowerCase().endsWith(' - topic')) {
    n = n.substring(0, n.length - 8).trim();
  }
  if (n.length > 4 && n.toUpperCase().endsWith('VEVO')) {
    n = n.substring(0, n.length - 4).trim();
  }
  return n.trim().isEmpty ? name : n;
}

const _versionWords = {
  'live',
  'remaster',
  'remastered',
  'remix',
  'edit',
  'mix',
  'acoustic',
  'unplugged',
  'demo',
  'extended',
  'vip',
  'bootleg',
  'cover',
  'instrumental',
  'karaoke',
  'sped up',
  'slowed',
  'nightcore',
};

String? _artistFromTags(String title, List<String> tags) {
  final titleKey = canonical(title);
  for (final tag in tags) {
    final key = canonical(tag);
    if (key.isNotEmpty && key != titleKey && !isReleaseNoise(key)) {
      final t = tag.trim();
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}

/// Reconciles a title/owner pair into an (artist, title) pair.
/// Topic channels already carry the real artist; distributor
/// "Release - Topic" channels do not, so video tags win there. Label
/// uploads titled "Artist - Track" split, unless the suffix is a version
/// word ("Song - Live"), which stays put.
({String artist, String title}) fixup(
  String title,
  String rawOwner,
  List<String> tags,
) {
  final cleanTitle = title.trim();
  final ownerArtist = normalizeArtist(rawOwner);
  if (isGenericReleaseOwner(rawOwner)) {
    return (
      artist: _artistFromTags(cleanTitle, tags) ?? ownerArtist,
      title: cleanTitle,
    );
  }
  if (rawOwner.toLowerCase().endsWith(' - topic')) {
    return (artist: ownerArtist, title: cleanTitle);
  }
  final split = cleanTitle.indexOf(' - ');
  if (split < 0) return (artist: ownerArtist, title: cleanTitle);
  final candidate = cleanTitle.substring(0, split).trim();
  final suffix = cleanTitle.substring(split + 3).trim();
  if (candidate.isEmpty || candidate.length > 60 || suffix.isEmpty) {
    return (artist: ownerArtist, title: cleanTitle);
  }
  final suffixHead = suffix.split(RegExp(r'[ \(\[]')).first.toLowerCase();
  if (_versionWords.contains(suffixHead)) {
    return (artist: ownerArtist, title: cleanTitle);
  }
  return (artist: candidate, title: suffix);
}

String? _nonEmpty(String s) => s.isEmpty ? null : s;

String? albumFromTags(
  String title,
  String artist,
  String rawOwner,
  List<String> tags,
) {
  if (!isGenericReleaseOwner(rawOwner) || tags.isEmpty) return null;
  final titleKey = canonical(title);
  final artistKey = canonical(artist);
  final meaningful = tags.where((tag) {
    final key = canonical(tag);
    return key.isNotEmpty && key != titleKey && !isReleaseNoise(key);
  }).toList();
  final meaningfulKeys = meaningful.map(canonical).toSet();
  final titleIndex = tags.indexWhere((t) => canonical(t) == titleKey);
  if (titleIndex > 0) {
    final beforeTitle = tags
        .sublist(0, titleIndex)
        .where((tag) => meaningfulKeys.contains(canonical(tag)))
        .toList();
    final separateType = tags
        .sublist(0, titleIndex)
        .indexWhere(isReleaseTypeTag);
    if (separateType >= 0) {
      final beforeType = tags
          .sublist(0, separateType)
          .where((tag) => meaningfulKeys.contains(canonical(tag)))
          .toList();
      if (beforeType.length == 1 && canonical(beforeType[0]) == artistKey) {
        return _nonEmpty(title.trim());
      }
      return null;
    }
    final explicitType = beforeTitle.any(hasReleaseType);
    if (explicitType && beforeTitle.isNotEmpty) {
      return _nonEmpty(beforeTitle.last.trim());
    }
    if (beforeTitle.length == 1 && canonical(beforeTitle[0]) == artistKey) {
      return _nonEmpty(title.trim());
    }
  }
  if (tags.any((t) => canonical(t) == titleKey) &&
      meaningful.length <= 1 &&
      meaningful.isNotEmpty &&
      canonical(meaningful.first) == artistKey) {
    return _nonEmpty(title.trim());
  }
  return null;
}

/// Release kind for distributor uploads, which carry no kind in
/// their tags. A same-named album on a generic channel is a single
/// by construction; otherwise the album title plus tags decide.
ReleaseKind? albumKindFromTags(
  String title,
  String? album,
  String rawOwner,
  List<String> tags,
) {
  if (album == null || !isGenericReleaseOwner(rawOwner)) return null;
  if (canonical(album) == canonical(title)) return ReleaseKind.single;
  final text = ([album, ...tags]).join(' ');
  final canon = canonical(text);
  final tokens = canon.split(' ').toSet();
  if (tokens.contains('ep') || text.toLowerCase().contains('e.p.')) {
    return ReleaseKind.ep;
  }
  if (tokens.contains('single')) return ReleaseKind.single;
  if (tokens.contains('compilation')) return ReleaseKind.compilation;
  if (tokens.contains('album')) return ReleaseKind.album;
  return null;
}

/// ISO-8601 durations ("PT4M13S") to seconds; 0 when unparseable.
int isoDuration(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return 0;
  // Unanchored find, like Kotlin: trailing garbage after a valid prefix
  // still parses.
  final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(v);
  if (m == null) return 0;
  final h = int.tryParse(m.group(1) ?? '') ?? 0;
  final min = int.tryParse(m.group(2) ?? '') ?? 0;
  final s = int.tryParse(m.group(3) ?? '') ?? 0;
  return h * 3600 + min * 60 + s;
}

bool _isRegionBlocked(Map video, String region) {
  if (region.trim().isEmpty) return false;
  final content = video['contentDetails'];
  final rr = content is Map ? content['regionRestriction'] : null;
  if (rr is! Map) return false;
  final blocked = (rr['blocked'] as List?)?.whereType<String>().toList() ?? [];
  if (blocked.contains(region)) return true;
  final allowed = rr['allowed'] as List?;
  if (allowed != null) {
    return !allowed.whereType<String>().any((c) => c == region);
  }
  return false;
}

/// Keep iff YouTube classifies the video as music and it plays in-region.
bool keepTrack(Map video, String region) {
  final snippet = video['snippet'];
  if (snippet is Map && snippet['categoryId'] == '10') return true;
  final details = video['topicDetails'];
  if (details is! Map) return false;
  final ids = (details['relevantTopicIds'] as List?)?.whereType<String>() ?? [];
  if (ids.contains(musicTopicId)) return !_isRegionBlocked(video, region);
  final cats = (details['topicCategories'] as List?)?.whereType<String>() ?? [];
  if (cats.isEmpty || !cats.any((c) => c.toLowerCase().contains('music'))) {
    return false;
  }
  return !_isRegionBlocked(video, region);
}

/// System region for region-restriction filtering: the default locale's
/// country, else US (mirrors Kotlin `Locale.getDefault().country`).
String systemRegion() {
  final locale = Platform.localeName; // e.g. "it_IT"
  final country = locale.split('_').skip(1).firstOrNull;
  final code = (country ?? '').split(RegExp(r'[.@]')).first.toUpperCase();
  if (code.length == 2 && RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
    return code;
  }
  return 'US';
}
