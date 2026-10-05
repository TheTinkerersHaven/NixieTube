// InnerTube response parsers, ported from Kotlin `InnerTube.kt`.
//
// Pure functions over decoded JSON (`json.dart` navigation). Network calls
// stay in `inner_tube.dart`; search ranking that needs extra fetches calls
// back through helpers here.

import '../models/models.dart';
import 'json.dart';
import 'metadata.dart' show canonical;

/// Lowercases, maps every non-alphanumeric run to a space, trims.
/// (Kotlin `canonicalMetadata`; identical to `metadata.canonical`.)
String canonicalMetadata(String value) => canonical(value);

int? intOrNull(dynamic node) => node is int ? node : null;

/// "m:ss" (or "h:mm:ss") to seconds; 0 when unparseable.
int toDurationSec(String s) {
  final parts = <int>[];
  for (final p in s.split(':')) {
    final v = int.tryParse(p);
    if (v == null) return 0;
    parts.add(v);
  }
  if (parts.isEmpty) return 0;
  var acc = 0;
  for (final p in parts) {
    acc = acc * 60 + p;
  }
  return acc;
}

/// Thumbnails from a raw `thumbnails` array; entries without a URL are skipped.
List<Thumbnail> parseThumbnailList(dynamic arr) {
  if (arr is! List) return [];
  final out = <Thumbnail>[];
  for (final it in arr) {
    final url = str(nav(it, const ['url']));
    if (url == null) continue;
    out.add(
      Thumbnail(
        url,
        width: intOrNull(nav(it, const ['width'])) ?? 0,
        height: intOrNull(nav(it, const ['height'])) ?? 0,
      ),
    );
  }
  return out;
}

/// First `thumbnails` array found anywhere under [node].
List<Thumbnail> parseThumbnails(dynamic node) {
  final arr = findFirst(node, 'thumbnails');
  if (arr is! List) return [];
  return parseThumbnailList(arr);
}

RatingStatus parseLikeRating(dynamic item) {
  final overlay = str(
    nav(item, const [
      'menu',
      'menuRenderer',
      'topLevelButtons',
      0,
      'likeButtonRenderer',
      'likeStatus',
    ]),
  );
  if (overlay != null) return RatingStatus.fromValue(overlay);
  final menuItems = nav(item, const ['menu', 'menuRenderer', 'items']);
  if (menuItems is! List) return RatingStatus.unknown;
  for (final entry in menuItems) {
    final toggle = nav(entry, const ['toggleMenuServiceItemRenderer']);
    final service =
        nav(toggle, const ['defaultServiceEndpoint']) ??
        nav(entry, const ['menuServiceItemRenderer', 'serviceEndpoint']);
    final status = str(nav(service, const ['likeEndpoint', 'status']));
    if (status != null && status.trim().isNotEmpty) {
      return RatingStatus.fromValue(status);
    }
  }
  return RatingStatus.unknown;
}

final _durationRe = RegExp(r'\d{1,3}:\d{2}(:\d{2})?');

final _viewsRe = RegExp(
  r'\d[\d.,\s]*(mila|mln|k|m|b)?\s*(views|views|riproduzioni|'
  r'visualizzazioni|vues|vistas|aufrufe|weergaven|reproducciones|visualiza|'
  r'visualizações|streams?|plays|再生|조회수|просмотров)',
  caseSensitive: false,
);

const _typeLabels = {
  'Song',
  'Video',
  'Album',
  'Single',
  'EP',
  'Release',
  'Artist',
  'Playlist',
  'Podcast',
  'Episode',
  'Profile',
  'Channel',
};

final _skipWordsRe = RegExp(
  r'\b(views|plays|subscribers|followers|listeners)\b',
  caseSensitive: false,
);

final _featureCreditRe = RegExp(
  r'(?:\(|\[|\b)(?:feat\.?|ft\.?|featuring|w/)\s+[^)\]]+(?:\)|\])?',
  caseSensitive: false,
);
final _featureSegmentRe = RegExp(
  r'''\s*[\(\[]?(?:feat\.?|ft\.?|featuring|w/)\s+[^)\]]+[\)\]]?''',
  caseSensitive: false,
);
final _creditStripRe = RegExp(
  r'^(feat\.?|ft\.?|featuring)\s+',
  caseSensitive: false,
);

bool hasFeaturedCredit(String value) => _featureCreditRe.hasMatch(value);

String preferredTrackTitle(String current, String candidate) {
  final oldTitle = current.trim();
  final newTitle = candidate.trim();
  if (newTitle.isEmpty) return oldTitle;
  if (oldTitle.isEmpty) return newTitle;
  final oldHasFeature = hasFeaturedCredit(oldTitle);
  final newHasFeature = hasFeaturedCredit(newTitle);
  if (newHasFeature && !oldHasFeature) return newTitle;
  if (newHasFeature &&
      oldHasFeature &&
      canonicalMetadata(oldTitle.replaceAll(_featureSegmentRe, '')) ==
          canonicalMetadata(newTitle.replaceAll(_featureSegmentRe, ''))) {
    return newTitle;
  }
  return oldTitle;
}

bool isBylineNoise(String value) {
  final v = canonicalMetadata(value);
  const plain = {
    '',
    'and',
    'feat',
    'ft',
    'with',
    'music',
    'audio',
    'official',
    'lyrics',
    'lyric video',
  };
  if (plain.contains(v)) return true;
  if (_typeLabels.any((t) => canonicalMetadata(t) == v)) return true;
  if (RegExp(r'(19|20)\d{2}').hasMatch(v) && v.length == 4) return true;
  if (RegExp(r'^\d{1,3}:\d{2}(:\d{2})?$').hasMatch(v)) return true;
  return RegExp(
    r'\b(views|plays|likes|subscribers|followers|listeners|streams)\b',
    caseSensitive: false,
  ).hasMatch(value);
}

/// Single-token joiners between linked artists ("A x B"): never an artist
/// credit on their own. Multi-word credits ("Camo & Krooked") pass through.
bool isCreditConjunction(String value) {
  if (value.contains(RegExp(r'\s'))) return false;
  const joins = {
    'x',
    'e',
    'y',
    'et',
    'vs',
    'versus',
    'meets',
    'pres',
    'presents',
  };
  return joins.contains(canonicalMetadata(value));
}

/// First linked channel (artist/owner) across header run lists.
ArtistRef? channelRefFromRuns(List<dynamic> runLists) {
  for (final runs in runLists) {
    if (runs is! List) continue;
    for (final run in runs) {
      final id = str(
        nav(run, const ['navigationEndpoint', 'browseEndpoint', 'browseId']),
      );
      if (id != null && id.startsWith('UC')) {
        final name = (str(nav(run, const ['text'])) ?? '').trim();
        if (name.isNotEmpty) return ArtistRef(name, browseId: id);
      }
    }
  }
  return null;
}

/// Plain-text fallback for headers with no linked channel. Composite runs
/// carrying bullets are skipped, as are digit-leading runs (counts, years).
ArtistRef? plainRefFromRuns(List<dynamic> runLists) {
  for (final runs in runLists) {
    if (runs is! List) continue;
    for (final run in runs) {
      final text = (str(nav(run, const ['text'])) ?? '').trim();
      if (text.isEmpty) continue;
      if (text.contains('•') || text.contains('·')) continue;
      if ('0123456789'.contains(text[0])) continue;
      if (isBylineNoise(text)) continue;
      return ArtistRef(text);
    }
  }
  return null;
}

final _releaseYearRe = RegExp(r'(?<!\d)(?:19|20)\d{2}(?!\d)');

/// First release year in an album header subtitle ("Album • 2015").
String detectReleaseYear(String text) =>
    _releaseYearRe.firstMatch(text)?.group(0) ?? '';

ReleaseKind? detectReleaseKind(String text) {
  final tokens = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toSet();
  if (tokens.contains('ep')) return ReleaseKind.ep;
  if (tokens.contains('single')) return ReleaseKind.single;
  if (tokens.contains('compilation')) return ReleaseKind.compilation;
  if (tokens.contains('mixed')) return ReleaseKind.mixed;
  if (tokens.contains('album')) return ReleaseKind.album;
  return null;
}

String? firstVideoId(dynamic runs) {
  if (runs is! List) return null;
  for (final run in runs) {
    final id = str(
      nav(run, const ['navigationEndpoint', 'watchEndpoint', 'videoId']),
    );
    if (id != null) return id;
  }
  return null;
}

/// Parses a `musicResponsiveListItemRenderer` row into a track.
Track? parseListItem(dynamic li) {
  final flex = nav(li, const ['flexColumns']);
  if (flex is! List) return null;
  final cols = <List>[];
  for (final col in flex) {
    final runs = nav(col, const [
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
    if (runs is List) cols.add(runs);
  }
  if (cols.isEmpty) return null;
  final titleRuns = cols[0];
  final title = runsText(titleRuns);
  String? videoId = firstVideoId(titleRuns);
  String? playlistId;
  if (videoId == null) {
    final watch = nav(li, const ['navigationEndpoint', 'watchEndpoint']);
    videoId = str(nav(watch, const ['videoId']));
    playlistId = str(nav(watch, const ['playlistId']));
  }
  if (videoId == null) return null;
  final radioId = 'RDAMVM$videoId';

  final artists = <ArtistRef>[];
  final plainGroups = <String>[];
  final plainGroup = StringBuffer();
  AlbumRef? album;
  var duration = 0;
  var views = '';

  void flushPlainGroup() {
    final value = plainGroup.toString().trim();
    if (value.isNotEmpty) plainGroups.add(value);
    plainGroup.clear();
  }

  // Pre-scan: which bullet-separated segments carry artist/album endpoints?
  final segmentHasArtist = <bool>[false];
  final segmentHasRelease = <bool>[false];
  for (final col in cols.skip(1)) {
    for (final run in col) {
      final text = (str(nav(run, const ['text'])) ?? '').trim();
      if (text == '•' || text == '·') {
        segmentHasArtist.add(false);
        segmentHasRelease.add(false);
        continue;
      }
      final bid = str(
        nav(run, const ['navigationEndpoint', 'browseEndpoint', 'browseId']),
      );
      if (bid != null && bid.startsWith('UC')) {
        segmentHasArtist[segmentHasArtist.length - 1] = true;
      }
      if (bid != null && bid.startsWith('MPRE')) {
        segmentHasRelease[segmentHasRelease.length - 1] = true;
      }
    }
  }
  var segmentIdx = 0;

  for (final col in cols.skip(1)) {
    for (final run in col) {
      final text = (str(nav(run, const ['text'])) ?? '').trim();
      if (text.isEmpty) continue;
      if (text == '•' || text == '·') {
        flushPlainGroup();
        segmentIdx++;
        continue;
      }
      if (views.isEmpty && _viewsRe.hasMatch(text)) {
        views = text;
        continue;
      }
      if (_durationRe.hasMatch(text)) {
        duration = toDurationSec(text);
        continue;
      }
      final browseId = str(
        nav(run, const ['navigationEndpoint', 'browseEndpoint', 'browseId']),
      );
      if (browseId != null && browseId.startsWith('UC')) {
        flushPlainGroup();
        artists.add(ArtistRef(text, browseId: browseId));
      } else if (browseId != null && browseId.startsWith('MPRE')) {
        flushPlainGroup();
        album = AlbumRef(
          text,
          browseId: browseId,
          kind: detectReleaseKind(text),
        );
      } else if (browseId == null &&
          !isBylineNoise(text) &&
          !_skipWordsRe.hasMatch(text)) {
        final inArtistZone =
            segmentIdx < segmentHasArtist.length &&
            segmentHasArtist[segmentIdx] &&
            !(segmentIdx < segmentHasRelease.length &&
                segmentHasRelease[segmentIdx]);
        final credit = text
            .replaceAll(_creditStripRe, '')
            .trim()
            .replaceAll(RegExp(r'[,;:]+$'), '');
        final isArtistCredit =
            inArtistZone &&
            credit.isNotEmpty &&
            !isBylineNoise(credit) &&
            !isCreditConjunction(credit);
        if (isArtistCredit) {
          artists.add(ArtistRef(credit));
        } else {
          // Runs before the first bullet form one artist credit; runs after
          // a bullet are a separate release field.
          if (plainGroup.isNotEmpty) plainGroup.write(' ');
          plainGroup.write(text);
        }
      }
    }
  }
  flushPlainGroup();
  if (artists.isEmpty) {
    if (plainGroups.isNotEmpty) artists.add(ArtistRef(plainGroups.first));
    if (album == null) {
      for (final g in plainGroups.skip(1)) {
        if (canonicalMetadata(g) != canonicalMetadata(title)) {
          album = AlbumRef(g, kind: detectReleaseKind(g));
          break;
        }
      }
    }
  }
  final rating = parseLikeRating(li);
  final seen = <String>{};
  final distinctArtists = <ArtistRef>[];
  for (final a in artists) {
    if (seen.add(a.name)) distinctArtists.add(a);
  }
  String? artistId;
  for (final a in distinctArtists) {
    if (a.browseId != null && a.browseId!.startsWith('UC')) {
      artistId = a.browseId;
      break;
    }
  }
  return Track(
    videoId: videoId,
    title: title,
    artists: distinctArtists,
    album: album,
    durationSec: duration,
    thumbnails: parseThumbnails(li),
    playlistId: playlistId,
    radioPlaylistId: radioId,
    artistId: artistId,
    views: views,
    rating: rating,
  );
}

/// Parses a watch-next `playlistPanelVideoRenderer` row into a track.
Track? parsePanelVideo(dynamic item) {
  final title = runsText(nav(item, const ['title', 'runs']));
  final videoId = str(
    nav(item, const ['navigationEndpoint', 'watchEndpoint', 'videoId']),
  );
  if (videoId == null) return null;
  final byline =
      nav(item, const ['longBylineText', 'runs']) ??
      nav(item, const ['shortBylineText', 'runs']);
  final runs = byline is List ? byline : const [];
  final artists = <ArtistRef>[];
  AlbumRef? album;
  for (final run in runs) {
    final text = (str(nav(run, const ['text'])) ?? '').trim();
    if (text.isEmpty || text == '•') continue;
    final id = str(
      nav(run, const ['navigationEndpoint', 'browseEndpoint', 'browseId']),
    );
    if (id != null && id.startsWith('UC')) {
      artists.add(ArtistRef(text, browseId: id));
    } else if (id != null && id.startsWith('MPRE')) {
      album = AlbumRef(text, browseId: id, kind: detectReleaseKind(text));
    }
  }
  final pieces = runs
      .map((r) => str(nav(r, const ['text'])) ?? '')
      .join(' ')
      .split(RegExp(r'\s*[•·]\s*'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (artists.isEmpty) {
    final plain = pieces.where((p) => !isBylineNoise(p)).toList();
    if (plain.isNotEmpty) artists.add(ArtistRef(plain.first));
    if (album == null) {
      for (final p in plain.skip(1)) {
        if (canonicalMetadata(p) != canonicalMetadata(title)) {
          album = AlbumRef(p, kind: detectReleaseKind(p));
          break;
        }
      }
    }
  }
  var duration = toDurationSec(
    runsText(nav(item, const ['lengthText', 'runs'])),
  );
  if (duration <= 0) {
    duration = toDurationSec(
      str(nav(item, const ['lengthText', 'simpleText'])) ?? '',
    );
  }
  final rating = parseLikeRating(item);
  final seen = <String>{};
  final distinctArtists = <ArtistRef>[];
  for (final a in artists) {
    if (seen.add(a.name)) distinctArtists.add(a);
  }
  String? artistId;
  for (final a in distinctArtists) {
    if (a.browseId != null && a.browseId!.startsWith('UC')) {
      artistId = a.browseId;
      break;
    }
  }
  return Track(
    videoId: videoId,
    title: title,
    artists: distinctArtists,
    album: album,
    durationSec: duration,
    thumbnails: parseThumbnails(item),
    radioPlaylistId: 'RDAMVM$videoId',
    artistId: artistId,
    rating: rating,
  );
}

/// Parses a home-feed element into a shelf, or null when unsupported/empty.
Shelf? parseShelf(dynamic el) {
  if (el is! Map) return null;
  final carousel = el['musicCarouselShelfRenderer'];
  if (carousel is Map) {
    final title = runsText(
      nav(carousel, const [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'title',
        'runs',
      ]),
    );
    if (title.isEmpty) return null;
    final contents = nav(carousel, const ['contents']);
    final items = <ShelfItem>[];
    if (contents is List) {
      for (final it in contents) {
        final item = parseShelfItem(it);
        if (item != null) items.add(item);
      }
    }
    if (items.isEmpty) return null;
    return Shelf(title, items);
  }
  final musicShelf = el['musicShelfRenderer'];
  if (musicShelf is Map) {
    var title = runsText(nav(musicShelf, const ['title', 'runs']));
    final contents = nav(musicShelf, const ['contents']);
    final items = <ShelfItem>[];
    if (contents is List) {
      for (final it in contents) {
        final li = nav(it, const ['musicResponsiveListItemRenderer']);
        if (li == null) continue;
        final t = parseListItem(li);
        if (t != null) items.add(ShelfItem.song(t));
      }
    }
    if (items.isEmpty) return null;
    if (title.isEmpty) title = 'Songs';
    return Shelf(title, items);
  }
  return null;
}

/// Parses a shelf content element into a song or browse item.
ShelfItem? parseShelfItem(dynamic el) {
  if (el is! Map) return null;
  final twoRow = el['musicTwoRowItemRenderer'];
  if (twoRow is Map) {
    final title = runsText(nav(twoRow, const ['title', 'runs']));
    final subtitle = runsText(nav(twoRow, const ['subtitle', 'runs']));
    final thumbs = parseThumbnails(twoRow);
    final watchVideoId = str(
      nav(twoRow, const ['navigationEndpoint', 'watchEndpoint', 'videoId']),
    );
    if (watchVideoId != null) {
      final playlistId = str(
        nav(twoRow, const [
          'navigationEndpoint',
          'watchEndpoint',
          'playlistId',
        ]),
      );
      // Subtitle runs carry the real credits ("Artist • Album" with
      // linked UC/MPRE ids). Using the whole subtitle string as one
      // artist name (the old behavior) produced credits like
      // "Artist • Album", so parse the runs like list rows do and
      // only fall back to the leading bullet segment when unlinked.
      final subtitleRuns = nav(twoRow, const ['subtitle', 'runs']);
      final artists = <ArtistRef>[];
      AlbumRef? album;
      if (subtitleRuns is List) {
        for (final run in subtitleRuns) {
          final text = (str(nav(run, const ['text'])) ?? '').trim();
          if (text.isEmpty || text == '•' || text == '·') continue;
          final id = str(
            nav(run, const [
              'navigationEndpoint',
              'browseEndpoint',
              'browseId',
            ]),
          );
          if (id != null && id.startsWith('UC')) {
            artists.add(ArtistRef(text, browseId: id));
          } else if (id != null && id.startsWith('MPRE')) {
            album ??= AlbumRef(
              text,
              browseId: id,
              kind: detectReleaseKind(text),
            );
          }
        }
      }
      if (artists.isEmpty) {
        final parts = subtitle
            .split(RegExp(r'\s*[•·]\s*'))
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty && !isBylineNoise(p))
            .toList();
        if (parts.isNotEmpty) artists.add(ArtistRef(parts.first));
      }
      return ShelfItem.song(
        Track(
          videoId: watchVideoId,
          title: title.isEmpty ? subtitle : title,
          artists: artists,
          album: album,
          thumbnails: thumbs,
          playlistId: playlistId,
          radioPlaylistId: 'RDAMVM$watchVideoId',
        ),
      );
    }
    final endpoint = nav(twoRow, const [
      'navigationEndpoint',
      'browseEndpoint',
    ]);
    final browseId = str(nav(endpoint, const ['browseId']));
    if (browseId != null) {
      return ShelfItem.browse(
        title: title,
        subtitle: subtitle,
        browseId: browseId,
        thumbnails: thumbs,
        kind: detectReleaseKind(subtitle),
        browseParams: str(nav(endpoint, const ['params'])),
      );
    }
    return null;
  }
  final li = el['musicResponsiveListItemRenderer'];
  if (li != null) {
    final t = parseListItem(li);
    if (t != null) return ShelfItem.song(t);
  }
  return null;
}

dynamic _browseEndpointFromRuns(dynamic runs) {
  if (runs is! List) return null;
  for (final run in runs) {
    final ep = nav(run, const ['navigationEndpoint', 'browseEndpoint']);
    if (ep != null) return ep;
  }
  return null;
}

dynamic _albumEndpointFromRuns(dynamic runs) {
  if (runs is! List) return null;
  for (final run in runs) {
    final ep = nav(run, const ['navigationEndpoint', 'browseEndpoint']);
    final id = str(nav(ep, const ['browseId']));
    if (id != null && id.startsWith('MPRE')) return ep;
  }
  return null;
}

String? _browseIdFromRuns(dynamic runs) =>
    str(nav(_browseEndpointFromRuns(runs), const ['browseId']));

String? _browseParamsFromRuns(dynamic runs) =>
    str(nav(_browseEndpointFromRuns(runs), const ['params']));

String? _artistBrowseId(dynamic runs) {
  final id = _browseIdFromRuns(runs);
  return (id != null && id.startsWith('UC')) ? id : null;
}

/// Adds an artist entry from a shelf title run when it links to a channel.
void addArtistSearchResult(
  Map<String, List<ShelfItem>> out,
  dynamic shelf,
  String title,
  dynamic titleRuns,
) {
  final genericTitle =
      title.isEmpty ||
      title.toLowerCase() == 'top result' ||
      title.toLowerCase() == 'results' ||
      title.toLowerCase() == 'artist';
  if (genericTitle) return;
  final browseId = _artistBrowseId(titleRuns);
  if (browseId == null || !browseId.startsWith('UC')) return;
  final artists = out.putIfAbsent('Artists', () => []);
  final exists = artists.any(
    (it) => it is BrowseItem && it.browseId == browseId,
  );
  if (!exists) {
    artists.add(
      ShelfItem.browse(
        title: title,
        subtitle: 'Artist',
        browseId: browseId,
        thumbnails: parseThumbnails(nav(shelf, const ['thumbnail'])),
        browseParams: _browseParamsFromRuns(titleRuns),
      ),
    );
  }
}

/// Adds an album entry from a card header when it links to a release.
void addAlbumSearchResult(
  Map<String, List<ShelfItem>> out,
  dynamic shelf,
  String title,
  dynamic titleRuns,
) {
  if (title.isEmpty) return;
  var endpoint = _albumEndpointFromRuns(titleRuns);
  if (endpoint == null) {
    final tap = nav(shelf, const ['onTap', 'browseEndpoint']);
    final id = str(nav(tap, const ['browseId']));
    if (id != null && id.startsWith('MPRE')) endpoint = tap;
  }
  if (endpoint == null) return;
  final browseId = str(nav(endpoint, const ['browseId']));
  if (browseId == null) return;
  final subtitle = runsText(nav(shelf, const ['subtitle', 'runs']));
  final releases = out.putIfAbsent('Albums', () => []);
  final exists = releases.any(
    (it) => it is BrowseItem && it.browseId == browseId,
  );
  if (!exists) {
    releases.add(
      ShelfItem.browse(
        title: title,
        subtitle: subtitle,
        browseId: browseId,
        thumbnails: parseThumbnails(nav(shelf, const ['thumbnail'])),
        kind: detectReleaseKind(subtitle),
        browseParams: str(nav(endpoint, const ['params'])),
      ),
    );
  }
}

/// Parses a list row into a browse entry, or null when it has no browse id.
BrowseItem? parseBrowseItem(dynamic li) {
  final flex = nav(li, const ['flexColumns']);
  if (flex is! List) return null;
  final cols = <List>[];
  for (final col in flex) {
    final runs = nav(col, const [
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
    if (runs is List) cols.add(runs);
  }
  if (cols.isEmpty) return null;
  final title = runsText(cols[0]);
  // Prefer the item-level endpoint: rows embed related entities' ids in
  // their runs (e.g. album rows carry the artist's UC id).
  final itemEndpoint = nav(li, const ['navigationEndpoint', 'browseEndpoint']);
  String? browseId = str(nav(itemEndpoint, const ['browseId']));
  String? browseParams = str(nav(itemEndpoint, const ['params']));
  if (browseId == null) {
    outer:
    for (final col in cols) {
      for (final run in col) {
        final endpoint = nav(run, const [
          'navigationEndpoint',
          'browseEndpoint',
        ]);
        browseId = str(nav(endpoint, const ['browseId']));
        browseParams = str(nav(endpoint, const ['params']));
        if (browseId != null) break outer;
      }
    }
  }
  if (browseId == null) return null;
  final subtitle = cols.skip(1).map(runsText).join(' ');
  return BrowseItem(
    title: title,
    subtitle: subtitle,
    browseId: browseId,
    thumbnails: parseThumbnails(li),
    kind: detectReleaseKind(subtitle),
    browseParams: browseParams,
  );
}

/// Merges one search-result shelf into the categorized output map.
void parseSearchShelf(
  Map<dynamic, dynamic> obj,
  Map<String, List<ShelfItem>> out,
) {
  final shelf = obj['musicShelfRenderer'];
  if (shelf is Map) {
    final titleRuns = nav(shelf, const ['title', 'runs']);
    var title = runsText(titleRuns);
    if (title.isEmpty) title = 'Results';
    addArtistSearchResult(out, shelf, title, titleRuns);
    final contents = nav(shelf, const ['contents']);
    final items = <ShelfItem>[];
    if (contents is List) {
      for (final it in contents) {
        final li = nav(it, const ['musicResponsiveListItemRenderer']);
        if (li == null) continue;
        final song = parseListItem(li);
        if (song != null) {
          items.add(ShelfItem.song(song));
        } else {
          final b = parseBrowseItem(li);
          if (b != null) items.add(b);
        }
      }
    }
    if (items.isNotEmpty) {
      out.putIfAbsent(title, () => []).addAll(items);
    }
  }
  final card = obj['musicCardShelfRenderer'];
  if (card is Map) {
    final titleRuns = nav(card, const ['title', 'runs']);
    final rawItems = <ShelfItem>[];
    final contents = nav(card, const ['contents']);
    if (contents is List) {
      for (final it in contents) {
        final li = nav(it, const ['musicResponsiveListItemRenderer']);
        if (li == null) continue;
        final song = parseListItem(li);
        if (song != null) {
          rawItems.add(ShelfItem.song(song));
        } else {
          final b = parseBrowseItem(li);
          if (b != null) rawItems.add(b);
        }
      }
    }
    var title = runsText(titleRuns);
    if (title.isEmpty) title = 'Top result';
    addArtistSearchResult(out, card, title, titleRuns);
    // Top-result cards often omit the artist on every row (the card itself
    // *is* the artist). Backfill from the card title, except for generic
    // headers.
    final generic =
        title.toLowerCase() == 'top result' || title.toLowerCase() == 'results';
    final items = (!generic)
        ? rawItems.map((item) {
            if (item is SongItem && item.track.artists.isEmpty) {
              return ShelfItem.song(
                item.track.copyWith(artists: [ArtistRef(title)]),
              );
            }
            return item;
          }).toList()
        : rawItems;
    if (items.isNotEmpty) {
      out.putIfAbsent(title, () => []).addAll(items);
    }
    // Exact-match cards sometimes carry no rows at all, just the entity
    // header. Surface a linked album the same way so exact album searches
    // never come back empty.
    if (!generic) {
      addAlbumSearchResult(out, card, title, titleRuns);
    }
  }
}

/// Builds an album detail from a `browse` response, or null when the header
/// or shelf is missing. Track rows are backfilled from the header.
AlbumDetail? buildAlbum(dynamic res, String browseId) {
  final header =
      findFirst(res, 'musicDetailHeaderRenderer') ??
      findFirst(res, 'musicResponsiveHeaderRenderer');
  if (header is! Map) return null;
  final shelf = findFirst(res, 'musicShelfRenderer');
  final albumTitle = runsText(nav(header, const ['title', 'runs']));
  final subtitle = runsText(nav(header, const ['subtitle', 'runs']));
  var description = runsText(nav(header, const ['description', 'runs']));
  if (description.isEmpty) description = subtitle;
  if (description == subtitle) description = '';
  final headerThumbs = parseThumbnails(header);
  final headerArtist =
      channelRefFromRuns([
        nav(header, const ['subtitle', 'runs']),
        nav(header, const ['straplineTextOne', 'runs']),
        nav(header, const ['straplineTextTwo', 'runs']),
        nav(header, const ['secondSubtitle', 'runs']),
      ]) ??
      plainRefFromRuns([
        nav(header, const ['subtitle', 'runs']),
        nav(header, const ['straplineTextOne', 'runs']),
        nav(header, const ['straplineTextTwo', 'runs']),
        nav(header, const ['secondSubtitle', 'runs']),
      ]);
  final kind = detectReleaseKind(subtitle) ?? detectReleaseKind(description);
  final year = detectReleaseYear(subtitle);
  final tracks = <Track>[];
  final contents = nav(shelf, const ['contents']);
  if (contents is List) {
    for (final it in contents) {
      final li = nav(it, const ['musicResponsiveListItemRenderer']);
      if (li == null) continue;
      var track = parseListItem(li);
      if (track == null) continue;
      if (track.thumbnails.isEmpty && headerThumbs.isNotEmpty) {
        track = track.copyWith(thumbnails: headerThumbs);
      }
      // Only linked header artists backfill track rows: stamping an
      // unlinked credit (e.g. Various Artists) would poison artist-based
      // matching downstream.
      final linkedHeader = headerArtist?.browseId != null ? headerArtist : null;
      if (track.artists.isEmpty && linkedHeader != null) {
        track = track.copyWith(
          artists: [linkedHeader],
          artistId: () => linkedHeader.browseId,
        );
      }
      if (track.album == null && albumTitle.isNotEmpty) {
        track = track.copyWith(
          album: AlbumRef(
            albumTitle,
            browseId: browseId,
            kind: kind,
            year: year,
          ),
        );
      } else if (track.album != null &&
          track.album!.year.isEmpty &&
          year.isNotEmpty) {
        final a = track.album!;
        track = track.copyWith(
          album: AlbumRef(
            a.name,
            browseId: a.browseId,
            kind: a.kind,
            year: year,
          ),
        );
      }
      tracks.add(track);
    }
  }
  return AlbumDetail(
    title: albumTitle,
    subtitle: subtitle,
    description: description,
    thumbnails: headerThumbs,
    tracks: tracks,
    kind: kind,
    year: year,
    artist: headerArtist,
  );
}

/// Builds an artist detail from a `browse` response.
ArtistDetail? buildArtist(dynamic res) {
  final header =
      findFirst(res, 'musicImmersiveHeaderRenderer') ??
      findFirst(res, 'musicVisualHeaderRenderer');
  if (header is! Map) return null;
  var subscribers = runsText(
    nav(findFirst(res, 'subscriptionButtonRenderer'), const ['text', 'runs']),
  );
  if (subscribers.isEmpty) {
    subscribers = runsText(
      nav(findFirst(res, 'subscriptionButtonRenderer'), const [
        'longBylineText',
        'runs',
      ]),
    );
  }
  Map? topShelf;
  for (final s in findAll(res, 'musicShelfRenderer')) {
    if (s is Map &&
        runsText(nav(s, const ['title', 'runs'])).toLowerCase() ==
            'top songs') {
      topShelf = s;
      break;
    }
  }
  topShelf ??= findFirst(res, 'musicShelfRenderer');
  final topSongs = <Track>[];
  final topContents = nav(topShelf, const ['contents']);
  if (topContents is List) {
    for (final it in topContents) {
      final li = nav(it, const ['musicResponsiveListItemRenderer']);
      if (li == null) continue;
      final t = parseListItem(li);
      if (t != null) topSongs.add(t);
    }
  }
  final songsEndpoint = nav(topShelf, const [
    'bottomEndpoint',
    'browseEndpoint',
  ]);
  final titleEndpoint = nav(topShelf, const ['title', 'runs']);
  final songsPlaylistId =
      str(nav(songsEndpoint, const ['browseId'])) ??
      _browseIdFromRuns(titleEndpoint);
  final songsPlaylistParams =
      str(nav(songsEndpoint, const ['params'])) ??
      _browseParamsFromRuns(titleEndpoint);

  final albums = <BrowseItem>[];
  final singlesAndEps = <BrowseItem>[];
  final relatedPlaylists = <BrowseItem>[];
  final similarArtists = <BrowseItem>[];

  List<BrowseItem> carouselItems(dynamic shelf) {
    final out = <BrowseItem>[];
    final contents = nav(shelf, const ['contents']);
    if (contents is! List) return out;
    for (final element in contents) {
      final item = nav(element, const ['musicTwoRowItemRenderer']);
      if (item == null) continue;
      final endpoint = nav(item, const [
        'navigationEndpoint',
        'browseEndpoint',
      ]);
      final id = str(nav(endpoint, const ['browseId']));
      if (id == null) continue;
      final subtitle = runsText(nav(item, const ['subtitle', 'runs']));
      out.add(
        BrowseItem(
          title: runsText(nav(item, const ['title', 'runs'])),
          subtitle: subtitle,
          browseId: id,
          thumbnails: parseThumbnails(item),
          kind: detectReleaseKind(subtitle),
          browseParams: str(nav(endpoint, const ['params'])),
        ),
      );
    }
    return out;
  }

  for (final shelf in findAll(res, 'musicCarouselShelfRenderer')) {
    final title = runsText(
      nav(shelf, const [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'title',
        'runs',
      ]),
    );
    final items = carouselItems(shelf);
    if (items.isEmpty) continue;
    final tokens = canonicalMetadata(title)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    List<BrowseItem> destination;
    if (tokens.contains('album') || tokens.contains('albums')) {
      destination = albums;
    } else if (tokens.contains('single') ||
        tokens.contains('singles') ||
        tokens.contains('ep') ||
        tokens.contains('eps')) {
      destination = singlesAndEps;
    } else if (tokens.contains('playlist') ||
        tokens.contains('playlists') ||
        tokens.contains('featured')) {
      destination = relatedPlaylists;
    } else if (tokens.contains('fan') ||
        tokens.contains('fans') ||
        tokens.contains('similar')) {
      destination = similarArtists;
    } else if (items.any((it) => it.browseId.startsWith('UC'))) {
      destination = similarArtists;
    } else if (items.any((it) => it.browseId.startsWith('VL'))) {
      destination = relatedPlaylists;
    } else {
      destination = albums;
    }
    destination.addAll(items);
  }

  List<BrowseItem> distinctById(List<BrowseItem> items) {
    final seen = <String>{};
    return items.where((it) => seen.add(it.browseId)).toList();
  }

  return ArtistDetail(
    name: runsText(nav(header, const ['title', 'runs'])),
    description: runsText(nav(header, const ['description', 'runs'])),
    thumbnails: parseThumbnails(header),
    topSongs: topSongs,
    albums: distinctById(albums),
    singlesAndEps: distinctById(singlesAndEps),
    relatedPlaylists: distinctById(relatedPlaylists),
    similarArtists: distinctById(similarArtists),
    songsPlaylistId: songsPlaylistId,
    songsPlaylistParams: songsPlaylistParams,
    subscribers: subscribers,
  );
}

/// Builds a playlist detail from a `browse` response, or null when the
/// track shelf is missing.
PlaylistDetail? buildPlaylist(dynamic res) {
  final editable = findFirst(res, 'musicEditablePlaylistDetailHeaderRenderer');
  final editableHeader = editable is Map
      ? nav(editable, const ['header'])
      : null;
  final header =
      findFirst(editableHeader, 'musicResponsiveHeaderRenderer') ??
      findFirst(editableHeader, 'musicDetailHeaderRenderer') ??
      findFirst(res, 'musicResponsiveHeaderRenderer') ??
      findFirst(res, 'musicDetailHeaderRenderer') ??
      findFirst(res, 'musicHeaderRenderer') ??
      editable;
  final shelf =
      findFirst(res, 'musicPlaylistShelfRenderer') ??
      findFirst(res, 'musicShelfRenderer');
  if (shelf is! Map) return null;
  final tracks = <Track>[];
  final contents = nav(shelf, const ['contents']);
  if (contents is List) {
    for (final it in contents) {
      final li = nav(it, const ['musicResponsiveListItemRenderer']);
      if (li == null) continue;
      final t = parseListItem(li);
      if (t != null) tracks.add(t);
    }
  }
  final micro = nav(res, const ['microformat', 'microformatDataRenderer']);
  var title = '';
  if (header is Map) {
    title = runsText(nav(header, const ['title', 'runs']));
    if (title.isEmpty) {
      title = runsText(
        nav(header, const [
          'header',
          'musicDetailHeaderTitleRenderer',
          'title',
          'runs',
        ]),
      );
    }
  }
  if (title.isEmpty) title = str(nav(micro, const ['title'])) ?? '';
  var subtitle = '';
  if (header is Map) {
    subtitle = runsText(nav(header, const ['subtitle', 'runs']));
  }
  if (subtitle.isEmpty) {
    subtitle = str(nav(micro, const ['description'])) ?? '';
  }
  var thumbnails = header is Map ? parseThumbnails(header) : <Thumbnail>[];
  if (thumbnails.isEmpty) {
    thumbnails = parseThumbnails(
      nav(res, const ['background', 'musicThumbnailRenderer']),
    );
  }
  if (thumbnails.isEmpty) {
    thumbnails = parseThumbnails(nav(micro, const ['thumbnail']));
  }
  if (thumbnails.isEmpty) {
    thumbnails = parseThumbnails(micro);
  }
  if (thumbnails.isEmpty && tracks.isNotEmpty) {
    thumbnails = tracks.first.thumbnails;
  }
  final author = header is Map
      ? (channelRefFromRuns([
              nav(header, const ['subtitle', 'runs']),
              nav(header, const ['straplineTextOne', 'runs']),
              nav(header, const ['straplineTextTwo', 'runs']),
              nav(header, const ['secondSubtitle', 'runs']),
            ]) ??
            plainRefFromRuns([
              nav(header, const ['subtitle', 'runs']),
              nav(header, const ['straplineTextOne', 'runs']),
              nav(header, const ['straplineTextTwo', 'runs']),
              nav(header, const ['secondSubtitle', 'runs']),
            ]))
      : null;
  return PlaylistDetail(
    title: title,
    subtitle: subtitle,
    thumbnails: thumbnails,
    tracks: tracks,
    author: author,
  );
}

/// First non-empty artwork from the playlist header/background/microformat,
/// trying the PL/VL id variants is the caller's job.
List<Thumbnail> playlistArtworkThumbs(dynamic res) {
  final editable = findFirst(res, 'musicEditablePlaylistDetailHeaderRenderer');
  final editableHeader = editable is Map
      ? nav(editable, const ['header'])
      : null;
  final header =
      findFirst(editableHeader, 'musicResponsiveHeaderRenderer') ??
      findFirst(editableHeader, 'musicDetailHeaderRenderer') ??
      findFirst(res, 'musicResponsiveHeaderRenderer') ??
      findFirst(res, 'musicDetailHeaderRenderer') ??
      findFirst(res, 'musicHeaderRenderer') ??
      editable;
  var thumbs = header is Map ? parseThumbnails(header) : <Thumbnail>[];
  if (thumbs.isEmpty) {
    thumbs = parseThumbnails(
      nav(res, const ['background', 'musicThumbnailRenderer']),
    );
  }
  if (thumbs.isEmpty) {
    thumbs = parseThumbnails(
      nav(res, const ['microformat', 'microformatDataRenderer', 'thumbnail']),
    );
  }
  if (thumbs.isEmpty) {
    thumbs = parseThumbnails(
      nav(res, const ['microformat', 'microformatDataRenderer']),
    );
  }
  if (thumbs.isEmpty) {
    final shelf =
        findFirst(res, 'musicPlaylistShelfRenderer') ??
        findFirst(res, 'musicShelfRenderer');
    final contents = nav(shelf, const ['contents']);
    if (contents is List && contents.isNotEmpty) {
      final firstItem = nav(contents.first, const [
        'musicResponsiveListItemRenderer',
      ]);
      if (firstItem != null) {
        thumbs = parseThumbnails(firstItem);
      }
    }
  }
  return thumbs;
}

/// Watch-next panel tracks from a `next` response.
List<Track> panelsOf(dynamic res) {
  final tabs = nav(res, const [
    'contents',
    'singleColumnMusicWatchNextResultsRenderer',
    'tabbedRenderer',
    'watchNextTabbedResultsRenderer',
    'tabs',
  ]);
  if (tabs is! List || tabs.isEmpty) return [];
  final panels = nav(tabs.first, const [
    'tabRenderer',
    'content',
    'musicQueueRenderer',
    'content',
    'playlistPanelRenderer',
    'contents',
  ]);
  if (panels is! List) return [];
  final out = <Track>[];
  for (final p in panels) {
    final t = parsePanelVideo(nav(p, const ['playlistPanelVideoRenderer']));
    if (t != null) out.add(t);
  }
  return out;
}
