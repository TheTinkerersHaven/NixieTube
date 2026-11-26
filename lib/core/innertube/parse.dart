// InnerTube response parsers.
//
// Pure functions over decoded JSON (`json.dart` navigation). Network calls
// stay in `inner_tube.dart`; search ranking that needs extra fetches calls
// back through helpers here.

import 'dart:math' show log;

import '../models/models.dart';
import 'json.dart';
import 'metadata.dart' show canonical;
import 'track_merge.dart';

/// Lowercases, maps every non-alphanumeric run to a space, trims.
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

/// The running time of a list row when it sits in the fixed columns.
///
/// Playlist and liked-songs rows keep the duration beside the title
/// (in `fixedColumns`) instead of inside the text columns, so
/// [parseListItem] cannot see it. Returns 0 when the row carries no
/// duration.
int parseRowDuration(dynamic li) {
  final fixed = nav(li, const ['fixedColumns']);
  if (fixed is! List) return 0;
  for (final col in fixed) {
    final runs = nav(col, const [
      'musicResponsiveListItemFixedColumnRenderer',
      'text',
      'runs',
    ]);
    if (runs is! List) continue;
    for (final run in runs) {
      final value = str(nav(run, const ['text']));
      if (value == null || !_durationRe.hasMatch(value)) continue;
      return toDurationSec(value);
    }
  }
  return 0;
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

/// First `thumbnails` array found anywhere under [node], plus the
/// API's own square crops (`croppedSquareThumbnailRenderer`, the same
/// fallback Metrolist reads) appended as extra candidates. Square
/// tiles then prefer an API-authored square over center-cropping a
/// wide frame, while largest-by-width selection (banners, MPRIS)
/// keeps the wide originals. Each call site passes a single item or
/// header node, so at most one crop array ever applies.
List<Thumbnail> parseThumbnails(dynamic node) {
  final arr = findFirst(node, 'thumbnails');
  if (arr is! List) return [];
  final out = parseThumbnailList(arr);
  final seen = out.map((t) => t.url).toSet();
  for (final r in findAll(node, 'croppedSquareThumbnailRenderer')) {
    final thumbs = nav(r, const ['thumbnail', 'thumbnails']);
    if (thumbs is! List) continue;
    for (final t in parseThumbnailList(thumbs)) {
      if (seen.add(t.url)) out.add(t);
    }
  }
  return out;
}

/// Current like state of a menu item. The *toggled* endpoint names
/// the state the toggle sits in; the *default* endpoint is the
/// transition away from it, so reading the default reports likes
/// for unliked songs and vice versa.
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
  // Toggle entries name the current state in `toggledServiceEndpoint`;
  // `defaultServiceEndpoint` is the transition away from it (reading the
  // default reports likes for unliked songs and vice versa). Like and
  // dislike live in separate toggles, so an INDIFFERENT like-toggle must
  // not shadow a DISLIKE elsewhere: prefer LIKE, then DISLIKE.
  var sawDislike = false;
  var sawIndifferent = false;
  RatingStatus? plainStatus;
  for (final entry in menuItems) {
    final toggle = nav(entry, const ['toggleMenuServiceItemRenderer']);
    if (toggle != null) {
      final toggled = str(
        nav(toggle, const ['toggledServiceEndpoint', 'likeEndpoint', 'status']),
      );
      if (toggled == null || toggled.trim().isEmpty) {
        // No toggled endpoint (e.g. library/pin toggles): skip rather
        // than report the default inverted.
        continue;
      }
      final current = RatingStatus.fromValue(toggled);
      if (current == RatingStatus.like) return current;
      if (current == RatingStatus.dislike) {
        sawDislike = true;
      } else if (current == RatingStatus.indifferent) {
        sawIndifferent = true;
      }
      // Unknown toggled values fall through to the priority below.
      continue;
    }
    final status = str(
      nav(entry, const [
        'menuServiceItemRenderer',
        'serviceEndpoint',
        'likeEndpoint',
        'status',
      ]),
    );
    if (status != null && status.trim().isNotEmpty && plainStatus == null) {
      plainStatus = RatingStatus.fromValue(status);
    }
  }
  if (sawDislike) return RatingStatus.dislike;
  if (sawIndifferent) return RatingStatus.indifferent;
  if (plainStatus != null) return plainStatus;
  return RatingStatus.unknown;
}

final _durationRe = RegExp(r'\d{1,3}:\d{2}(:\d{2})?');

final _viewsRe = RegExp(
  r'\d[\d.,\s]*(mila|mln|k|m|b)?\s*(views|riproduzioni|'
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

final _creditStripRe = RegExp(
  r'^(feat\.?|ft\.?|featuring)\s+',
  caseSensitive: false,
);

/// True when a byline run is metadata, not a credit: bare joiners
/// ("and", "feat"), type labels ("official", "lyric video"), years,
/// durations and count strings ("1.2M views"). Byline runs mix real
/// artist names with this noise, so every consumer filters first.
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
  if (v == 'public' ||
      v == 'unlisted' ||
      v == 'public playlist' ||
      v == 'unlisted playlist') {
    return true;
  }
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
        final lower = name.toLowerCase();
        if (name.isNotEmpty &&
            lower != 'public' &&
            lower != 'unlisted' &&
            lower != 'public playlist' &&
            lower != 'unlisted playlist') {
          return ArtistRef(name, browseId: id);
        }
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

/// Release kind from subtitle tokens ("Album • 2015", "Single").
/// Token order matters: 'ep' beats 'album' so "EP • Album" reads as an
/// EP. Null when no token matches — most artist bylines have none.
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

/// First watch video id linked from title runs, or null. Title and
/// artist runs share one array, so this scans for the first run that
/// actually carries a watch endpoint.
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

/// Builds a track from the fields a row renderer extracted.
///
/// The three row shapes (`musicResponsiveListItemRenderer`,
/// `playlistPanelVideoRenderer`, `musicTwoRowItemRenderer`) keep the
/// title, credits, duration and badges in different places, but the
/// track they describe is the same. Each parser extracts its own fields
/// and calls this, so artist dedup, the radio playlist id, the artist
/// channel id and credit/album interpretation live in one place.
Track? trackFromRow({
  required String? videoId,
  required String title,
  required List<List> creditColumns,
  List<Thumbnail> thumbnails = const [],
  String? playlistId,
  String? views,
  int? duration,
  RatingStatus rating = RatingStatus.unknown,
  bool explicit = false,
  bool detectViews = true,
  bool detectDuration = true,
  bool inferAlbumFromPlain = true,
  bool firstAlbumWins = false,
  bool fillArtistId = true,
}) {
  if (videoId == null || videoId.isEmpty) return null;
  final credits = _readRowCredits(
    creditColumns,
    title,
    detectViews: detectViews,
    detectDuration: detectDuration,
    inferAlbumFromPlain: inferAlbumFromPlain,
    firstAlbumWins: firstAlbumWins,
  );
  final artists = _distinctArtists(credits.artists);
  return Track(
    videoId: videoId,
    title: title,
    artists: artists,
    album: credits.album,
    durationSec: duration ?? credits.duration,
    thumbnails: thumbnails,
    playlistId: playlistId,
    radioPlaylistId: 'RDAMVM$videoId',
    artistId: fillArtistId ? _firstChannelId(artists) : null,
    views: views ?? credits.views,
    rating: rating,
    explicit: explicit,
  );
}

/// Parses a `musicResponsiveListItemRenderer` row into a track.
Track? parseListItem(dynamic li) {
  final cols = _listItemColumns(li);
  if (cols.isEmpty) return null;
  final titleRuns = cols[0];
  final identity = _listItemIdentity(li, titleRuns);
  if (identity == null) return null;
  return trackFromRow(
    videoId: identity.videoId,
    title: runsText(titleRuns),
    creditColumns: cols.skip(1).toList(),
    thumbnails: parseThumbnails(li),
    playlistId: identity.playlistId,
    rating: parseLikeRating(li),
    explicit: parseExplicit(li),
  );
}

/// The text runs of every flex column of a list row.
List<List> _listItemColumns(dynamic li) {
  final flex = nav(li, const ['flexColumns']);
  if (flex is! List) return const [];
  final cols = <List>[];
  for (final col in flex) {
    final runs = nav(col, const [
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
    if (runs is List) cols.add(runs);
  }
  return cols;
}

/// Adds the artist channels in [items] to [out]'s "Artists" section,
/// skipping ids that are already listed.
void _surfaceArtists(Map<String, List<ShelfItem>> out, List<ShelfItem> items) {
  for (final it in items) {
    if (it is! BrowseItem || !it.browseId.startsWith('UC')) continue;
    final artists = out.putIfAbsent('Artists', () => []);
    if (artists.any((a) => a is BrowseItem && a.browseId == it.browseId)) {
      continue;
    }
    artists.add(it);
  }
}

/// The video id of a list row, and the playlist it belongs to.
({String videoId, String? playlistId})? _listItemIdentity(
  dynamic li,
  List titleRuns,
) {
  final fromTitle = firstVideoId(titleRuns);
  if (fromTitle != null) return (videoId: fromTitle, playlistId: null);
  final watch = nav(li, const ['navigationEndpoint', 'watchEndpoint']);
  final videoId = str(nav(watch, const ['videoId']));
  if (videoId == null) return null;
  return (videoId: videoId, playlistId: str(nav(watch, const ['playlistId'])));
}

/// One text/bullet segment of a byline, after splitting runs that pack
/// several segments into one string ("Artist • Album"). A bullet carries
/// no text and only separates segments.
class _CreditRun {
  const _CreditRun(this.text, {this.browseId, this.bullet = false});

  final String text;
  final String? browseId;
  final bool bullet;
}

/// Flattens row text columns into credit segments, splitting bullets
/// embedded inside a run. List rows already use separate bullet runs;
/// two-row subtitles often pack "Artist • Album" into one run. Linked
/// runs (a browse id) stay whole, since the link applies to the run.
List<_CreditRun> _creditRuns(List<List> columns) {
  final out = <_CreditRun>[];
  for (final col in columns) {
    for (final run in col) {
      final raw = (str(nav(run, const ['text'])) ?? '').trim();
      if (raw.isEmpty) continue;
      if (raw == '•' || raw == '·') {
        out.add(const _CreditRun('', bullet: true));
        continue;
      }
      final browseId = str(
        nav(run, const ['navigationEndpoint', 'browseEndpoint', 'browseId']),
      );
      if (browseId != null) {
        out.add(_CreditRun(raw, browseId: browseId));
        continue;
      }
      final pieces = raw.split(RegExp(r'\s*[•·]\s*'));
      for (var i = 0; i < pieces.length; i++) {
        if (i > 0) out.add(const _CreditRun('', bullet: true));
        final text = pieces[i].trim();
        if (text.isNotEmpty) out.add(_CreditRun(text));
      }
    }
  }
  return out;
}

/// The credits, duration and views carried by a row's text columns
/// (the title column excluded). [detectViews] and [detectDuration]
/// skip the text scans for renderers that carry those elsewhere (panel
/// bylines, two-row subtitles); [inferAlbumFromPlain] controls the
/// plain-text album fallback; [firstAlbumWins] keeps the first linked
/// album instead of the last.
({List<ArtistRef> artists, AlbumRef? album, int duration, String views})
_readRowCredits(
  List<List> columns,
  String title, {
  bool detectViews = true,
  bool detectDuration = true,
  bool inferAlbumFromPlain = true,
  bool firstAlbumWins = false,
}) {
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

  void setAlbum(AlbumRef candidate) {
    if (firstAlbumWins && album != null) return;
    album = candidate;
  }

  final segments = _creditSegmentFlags(columns);
  var segmentIdx = 0;

  for (final run in _creditRuns(columns)) {
    if (run.bullet) {
      flushPlainGroup();
      segmentIdx++;
      continue;
    }
    final text = run.text;
    if (text.isEmpty) continue;
    if (detectViews && views.isEmpty && _viewsRe.hasMatch(text)) {
      views = text;
      continue;
    }
    if (detectDuration && _durationRe.hasMatch(text)) {
      duration = toDurationSec(text);
      continue;
    }
    final browseId = run.browseId;
    if (browseId != null && browseId.startsWith('UC')) {
      flushPlainGroup();
      artists.add(ArtistRef(text, browseId: browseId));
    } else if (browseId != null && browseId.startsWith('MPRE')) {
      flushPlainGroup();
      setAlbum(
        AlbumRef(text, browseId: browseId, kind: detectReleaseKind(text)),
      );
    } else if (browseId == null &&
        !isBylineNoise(text) &&
        !_skipWordsRe.hasMatch(text)) {
      final credit = text
          .replaceAll(_creditStripRe, '')
          .trim()
          .replaceAll(RegExp(r'[,;:]+$'), '');
      if (_isArtistCredit(credit, segmentIdx, segments)) {
        artists.add(ArtistRef(credit));
      } else {
        // Runs before the first bullet form one artist credit; runs after
        // a bullet are a separate release field.
        if (plainGroup.isNotEmpty) plainGroup.write(' ');
        plainGroup.write(text);
      }
    }
  }
  flushPlainGroup();
  if (artists.isEmpty) {
    if (plainGroups.isNotEmpty) artists.add(ArtistRef(plainGroups.first));
    if (album == null && inferAlbumFromPlain) {
      for (final group in plainGroups.skip(1)) {
        if (canonicalMetadata(group) != canonicalMetadata(title)) {
          setAlbum(AlbumRef(group, kind: detectReleaseKind(group)));
          break;
        }
      }
    }
  }
  return (artists: artists, album: album, duration: duration, views: views);
}

/// Which bullet-separated credit segments carry artist or album links.
({List<bool> hasArtist, List<bool> hasRelease}) _creditSegmentFlags(
  List<List> columns,
) {
  final hasArtist = <bool>[false];
  final hasRelease = <bool>[false];
  for (final run in _creditRuns(columns)) {
    if (run.bullet) {
      hasArtist.add(false);
      hasRelease.add(false);
      continue;
    }
    final browseId = run.browseId;
    if (browseId != null && browseId.startsWith('UC')) {
      hasArtist[hasArtist.length - 1] = true;
    }
    if (browseId != null && browseId.startsWith('MPRE')) {
      hasRelease[hasRelease.length - 1] = true;
    }
  }
  return (hasArtist: hasArtist, hasRelease: hasRelease);
}

/// Whether [credit] in segment [segmentIdx] names an artist.
bool _isArtistCredit(
  String credit,
  int segmentIdx,
  ({List<bool> hasArtist, List<bool> hasRelease}) segments,
) {
  final inArtistZone =
      segmentIdx < segments.hasArtist.length &&
      segments.hasArtist[segmentIdx] &&
      !(segmentIdx < segments.hasRelease.length &&
          segments.hasRelease[segmentIdx]);
  return inArtistZone &&
      credit.isNotEmpty &&
      !isBylineNoise(credit) &&
      !isCreditConjunction(credit);
}

/// The artists of a row, without repeated names.
List<ArtistRef> _distinctArtists(List<ArtistRef> artists) {
  final seen = <String>{};
  final distinct = <ArtistRef>[];
  for (final artist in artists) {
    if (seen.add(artist.name)) distinct.add(artist);
  }
  return distinct;
}

/// The channel id of the first linked artist.
String? _firstChannelId(List<ArtistRef> artists) {
  for (final artist in artists) {
    final browseId = artist.browseId;
    if (browseId != null && browseId.startsWith('UC')) return browseId;
  }
  return null;
}

/// True when an item renderer carries the explicit badge: a `badges`
/// array holding a `musicInlineBadgeRenderer` whose icon is
/// `MUSIC_EXPLICIT_BADGE`. Only a UI badge — there is no dedicated
/// boolean field, and `videoDetails` never includes it, so tracks
/// fetched by id alone always read false. Missing `badges` means not
/// marked, not unknown.
bool parseExplicit(dynamic node) {
  final badges = nav(node, const ['badges']);
  if (badges is! List) return false;
  for (final b in badges) {
    final iconType = str(
      nav(b, const ['musicInlineBadgeRenderer', 'icon', 'iconType']),
    );
    if (iconType == 'MUSIC_EXPLICIT_BADGE') return true;
  }
  return false;
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
  var duration = toDurationSec(
    runsText(nav(item, const ['lengthText', 'runs'])),
  );
  if (duration <= 0) {
    duration = toDurationSec(
      str(nav(item, const ['lengthText', 'simpleText'])) ?? '',
    );
  }
  return trackFromRow(
    videoId: videoId,
    title: title,
    // A byline is one runs array; views and duration live elsewhere on
    // the panel (`lengthText`), so the credit scan must not treat them
    // as text columns.
    creditColumns: [runs],
    thumbnails: parseThumbnails(item),
    duration: duration,
    rating: parseLikeRating(item),
    explicit: parseExplicit(item),
    detectViews: false,
    detectDuration: false,
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
    return Shelf(title, items, continuation: _shelfContinuation(el, carousel));
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
    return Shelf(
      title,
      items,
      continuation: _shelfContinuation(el, musicShelf),
    );
  }
  return null;
}

/// Best-effort continuation token for [Shelf.continuation].
///
/// YouTube carries more-items tokens in different places depending on the
/// shelf renderer version: sometimes at the shelf element itself, sometimes
/// inside the renderer, and sometimes as the trailing
/// `continuationItemRenderer` of `contents`. Every path is tried and `null`
/// is returned when none is present, so a shelf without a token simply
/// never offers a load-more action.
String? _shelfContinuation(dynamic el, dynamic renderer) {
  String? token(dynamic node) {
    if (node is! Map) return null;
    final cont = nav(node, const ['continuation']);
    if (cont is Map) {
      final t = str(nav(cont, const ['token']));
      if (t?.isNotEmpty == true) return t;
    }
    return null;
  }

  final t = token(el);
  if (t?.isNotEmpty == true) return t;
  final r = token(renderer);
  if (r?.isNotEmpty == true) return r;

  // A trailing continuationItemRenderer in contents.
  final contents = nav(el, const ['contents']);
  if (contents is List && contents.isNotEmpty) {
    final last = contents.last;
    if (last is Map) {
      final ci = last['continuationItemRenderer'];
      if (ci is Map) {
        final ep = nav(ci, const ['continuationEndpoint']);
        final ct = str(nav(ep, const ['continuationToken']));
        if (ct?.isNotEmpty == true) return ct;
      }
    }
  }
  return null;
}

/// Mood filter titles from a home response's chip cloud
/// (`chipCloudChipRenderer` nodes, e.g. Relax/Workout/Party), deduped
/// case-insensitively in feed order. Empty when the response carries
/// no chips. Tapping a chip runs a plain search for its title, so
/// only the text is kept.
List<String> parseHomeMoods(dynamic res) {
  final out = <String>[];
  final seen = <String>{};
  for (final chip in findAll(res, 'chipCloudChipRenderer')) {
    final title = runsText(nav(chip, const ['text', 'runs'])).trim();
    if (title.isEmpty || !seen.add(title.toLowerCase())) continue;
    out.add(title);
  }
  return out;
}

/// Artist keys for shelf ranking: UC channel ids plus canonical
/// names, so feed items link to library artists with or without ids.
Set<String> shelfArtistKeys({
  required List<BrowseItem> artists,
  required List<Track> tracks,
}) {
  final out = <String>{};
  for (final a in artists) {
    if (a.browseId.isNotEmpty) out.add(a.browseId);
    final n = canonicalMetadata(a.title);
    if (n.isNotEmpty) out.add(n);
  }
  for (final t in tracks) {
    for (final a in t.artists) {
      final id = a.browseId;
      if (id != null && id.isNotEmpty) out.add(id);
      final n = canonicalMetadata(a.name);
      if (n.isNotEmpty) out.add(n);
    }
  }
  return out;
}

/// Orders home shelves by user-centricity, stable: shelves whose
/// items overlap the user's own tracks (history/liked ids), artists,
/// or personalized mix seeds come first; generic editorial shelves
/// (charts, new music with no overlap) keep feed order at the bottom.
/// An empty profile scores everything zero, preserving feed order —
/// so signed-out users see no change.
List<Shelf> rankShelvesByProfile(
  List<Shelf> shelves, {
  required Set<String> trackIds,
  required Set<String> artistKeys,
}) {
  bool artistHit(Track t) {
    for (final a in t.artists) {
      final id = a.browseId;
      if (id != null && id.isNotEmpty && artistKeys.contains(id)) {
        return true;
      }
      final n = canonicalMetadata(a.name);
      if (n.isNotEmpty && artistKeys.contains(n)) return true;
    }
    return false;
  }

  int score(ShelfItem item) {
    if (item is SongItem) {
      final t = item.track;
      var s = 0;
      if (t.videoId.isNotEmpty && trackIds.contains(t.videoId)) s += 3;
      if (artistHit(t)) s += 2;
      final pid = t.playlistId ?? '';
      if (pid.startsWith('RDEM') || pid.startsWith('RDCLAK')) s += 2;
      return s;
    }
    if (item is BrowseItem) {
      // Followed-artist channels surfacing in the feed.
      if (item.browseId.isNotEmpty && artistKeys.contains(item.browseId)) {
        return 3;
      }
    }
    return 0;
  }

  final indexed = [
    for (var i = 0; i < shelves.length; i++)
      (score: shelves[i].items.fold(0, (sum, it) => sum + score(it)), index: i),
  ];
  indexed.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.index.compareTo(b.index);
  });
  return [for (final e in indexed) shelves[e.index]];
}

/// Merges locally-played tracks ahead of a server history fetch.
/// Server history lags (or stalls) behind what just played, so local
/// recents missing from it go first, then the server list; deduped,
/// capped. Pure so reload merging stays unit-testable.
List<Track> mergeLocalRecents(
  List<Track> server,
  List<Track> local, {
  int cap = 100,
}) {
  final ids = <String>{for (final t in server) t.videoId};
  final out = [
    for (final t in local)
      if (t.videoId.isNotEmpty && !ids.contains(t.videoId)) t,
    ...server,
  ];
  final seen = <String>{};
  return [
    for (final t in out)
      if (seen.add(t.videoId)) t,
  ].take(cap).toList();
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
      // linked UC/MPRE ids). The shared row builder parses them like
      // list rows; a plain subtitle still falls back to its leading
      // segment, and a card never infers an album from unlinked text.
      final subtitleRuns = nav(twoRow, const ['subtitle', 'runs']);
      final runs = subtitleRuns is List ? subtitleRuns : const [];
      final track = trackFromRow(
        videoId: watchVideoId,
        title: title.isEmpty ? subtitle : title,
        creditColumns: [runs],
        thumbnails: thumbs,
        playlistId: playlistId,
        explicit: parseExplicit(twoRow),
        detectViews: false,
        detectDuration: false,
        inferAlbumFromPlain: false,
        firstAlbumWins: true,
        fillArtistId: false,
      );
      if (track != null) return ShelfItem.song(track);
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
  final cols = _listItemColumns(li);
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
    // Surface any artist channel (browseId UC*) as an Artists entry too,
    // so an artist match shows in the main results instead of only
    // behind the Artists chip.
    _surfaceArtists(out, items);
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
      // The top-result card is the closest match: surface it under a
      // dedicated "Exact Match" section so it stands apart from the
      // category shelves below.
      out.putIfAbsent('Exact Match', () => []).addAll(items);
    }
    _surfaceArtists(out, items);
    // Exact-match cards sometimes carry no rows at all, just the entity
    // header. Surface a linked album the same way so exact album searches
    // never come back empty.
    if (!generic) {
      addAlbumSearchResult(out, card, title, titleRuns);
      // If the card itself links to an artist channel, surface it too.
      final browseId = _artistBrowseId(titleRuns);
      if (browseId != null) {
        final artists = out.putIfAbsent('Artists', () => []);
        if (!artists.any((a) => a is BrowseItem && a.browseId == browseId)) {
          artists.add(
            ShelfItem.browse(
              title: title,
              subtitle: 'Artist',
              browseId: browseId,
              thumbnails: parseThumbnails(nav(card, const ['thumbnail'])),
              browseParams: _browseParamsFromRuns(titleRuns),
            ),
          );
        }
      }
    }
  }
}

/// Splits text runs into segments at the " • " separator runs — the
/// same splitBySeparator Metrolist/InnerTune apply to card subtitles,
/// which read "Song • Artist • Album • 3:45".
List<List> splitRunsBySeparator(dynamic runs) {
  if (runs is! List) return const [];
  final segments = <List>[];
  var current = <dynamic>[];
  for (final run in runs) {
    final text = run is Map ? str(run['text']) : null;
    if (text != null && text.trim() == '•') {
      segments.add(current);
      current = <dynamic>[];
    } else {
      current.add(run);
    }
  }
  segments.add(current);
  return segments;
}

/// Parses a search `musicCardShelfRenderer` — the "Top result" card —
/// into the single entity it stands for, the way Metrolist's
/// `fromMusicCardShelfRenderer` does: the entity comes from the card's
/// own `onTap` endpoint (watch → song, browse → artist/album/playlist),
/// the subtitle runs carry type • artists • album • duration, and the
/// card-level thumbnail is its art.
ShelfItem? parseSearchCardShelf(dynamic card) {
  if (card is! Map) return null;
  // The card title lives in its header; some variants repeat it at the
  // top level, so fall back to that.
  final headerTitle = nav(card, const [
    'header',
    'musicCardShelfHeaderBasicRenderer',
    'title',
    'runs',
  ]);
  final topTitle = nav(card, const ['title', 'runs']);
  final title = runsText(
    headerTitle is List && headerTitle.isNotEmpty
        ? headerTitle
        : (topTitle is List ? topTitle : null),
  );
  if (title.isEmpty) return null;
  final segments = splitRunsBySeparator(nav(card, const ['subtitle', 'runs']));
  final typeLabel = segments.isNotEmpty ? runsText(segments[0]) : '';
  final thumbNode = nav(card, const ['thumbnail']);
  final thumbnails = parseThumbnails(thumbNode ?? card);

  final onTap = nav(card, const ['onTap']);
  // Song card: the card itself links to a watch endpoint.
  final videoId = str(nav(onTap, const ['watchEndpoint', 'videoId']));
  if (videoId != null && videoId.isNotEmpty) {
    // Artists sit in the second subtitle segment; the linked names are
    // the runs at even indices ("oddElements" in Metrolist's port, which
    // despite the name filters index % 2 == 0 — names alternate with
    // ", " runs inside a segment).
    final artists = <ArtistRef>[];
    if (segments.length > 1) {
      final seg = segments[1];
      for (var i = 0; i < seg.length; i += 2) {
        final name = str(nav(seg[i], const ['text']));
        if (name == null || name.isEmpty) continue;
        artists.add(ArtistRef(name, browseId: _browseIdFromRuns([seg[i]])));
      }
    }
    // Album is the third segment's first run that links to a release.
    AlbumRef? album;
    if (segments.length > 2) {
      for (final run in segments[2]) {
        final id = _browseIdFromRuns([run]);
        final name = str(nav(run, const ['text']));
        if (id != null && id.startsWith('MPRE') && name != null) {
          album = AlbumRef(name, browseId: id);
          break;
        }
      }
    }
    // The duration is the last subtitle segment ("3:45").
    final durationText = segments.isNotEmpty ? runsText(segments.last) : '';
    final duration = _durationRe.hasMatch(durationText)
        ? toDurationSec(durationText)
        : 0;
    final explicitBadges = nav(card, const ['subtitleBadges']);
    var explicit = false;
    if (explicitBadges is List) {
      for (final b in explicitBadges) {
        if (str(nav(b, const [
              'musicInlineBadgeRenderer',
              'icon',
              'iconType',
            ])) ==
            'MUSIC_EXPLICIT_BADGE') {
          explicit = true;
          break;
        }
      }
    }
    return ShelfItem.song(
      Track(
        videoId: videoId,
        title: title,
        artists: artists,
        album: album,
        durationSec: duration,
        thumbnails: thumbnails,
        explicit: explicit,
      ),
    );
  }
  // Browse card: artist, album or playlist, decided by the browse id.
  final browseId = str(nav(onTap, const ['browseEndpoint', 'browseId']));
  if (browseId == null || browseId.isEmpty) return null;
  return ShelfItem.browse(
    title: title,
    subtitle: typeLabel.isNotEmpty ? typeLabel : runsText(nav(card, const ['subtitle', 'runs'])),
    browseId: browseId,
    thumbnails: thumbnails,
    kind: detectReleaseKind(typeLabel),
    browseParams: str(nav(onTap, const ['browseEndpoint', 'params'])),
  );
}

/// Ranks song search results against the raw [query], best match first.
///
/// YouTube answers "title + artist" queries (e.g. "kid again ivycomb")
/// with the right recording buried among partial title matches, so a
/// full-string title comparison alone never fires there. Each song
/// scores on token overlap between the query and its title/artists:
///
/// * the whole query names the title exactly (previous behavior kept),
/// * the query contains the full title as a phrase ("kid again" inside
///   "kid again ivycomb"),
/// * every title word appears in the query (word-order free),
/// * per-word title overlap, artist word overlap, and the dominant
///   (top-result/artist-section) artist recording.
///
/// Exact full-query title matches still outscore everything; ties keep
/// YouTube's order (stable sort), so plain single-word queries behave
/// exactly as before.
/// Log-scaled popularity bonus from a YouTube view-count string such as
/// "1,234,567 views", "1.2M views", "1.2B views". Returns 0 when the
/// count is missing or unparseable, so unknown popularity never outranks
/// a known one by accident; the bonus is capped so it can break ties
/// between equally-titled recordings but cannot override a real text
/// match advantage.
int _viewsBonus(String views) {
  if (views.isEmpty) return 0;
  final m = RegExp(r'([\d.,]+)\s*([KMBkmb]?)').firstMatch(views.trim());
  if (m == null) return 0;
  final numStr = m.group(1)!.replaceAll(',', '');
  final value = double.tryParse(numStr);
  if (value == null || value <= 0) return 0;
  final mult = switch (m.group(2)!.toUpperCase()) {
    'K' => 1e3,
    'M' => 1e6,
    'B' => 1e9,
    _ => 1.0,
  };
  final total = value * mult;
  // log10 of 1B = 9; scale to ~0..90 so a 1B-view original beats a
  // 10k-view cover (~40) by ~50 points, within the tie-break range.
  final logValue = (total <= 0) ? 0.0 : (log(total) / log(10));
  final scaled = (logValue * 10).round();
  return scaled.clamp(0, 90);
}

List<SongItem> rankSearchSongs(
  Iterable<SongItem> songs,
  String query, {
  Set<String> dominantIds = const {},
  Set<String> dominantNames = const {},
}) {
  final queryCanon = canonicalMetadata(query);
  if (queryCanon.isEmpty) return songs.toList();
  final queryTokens = queryCanon.split(' ').where((t) => t.isNotEmpty).toSet();

  bool isDominant(SongItem s) => s.track.artists.any((artist) {
    final key = canonicalMetadata(artist.name);
    return (artist.browseId != null &&
            artist.browseId!.isNotEmpty &&
            dominantIds.contains(artist.browseId)) ||
        (key.isNotEmpty && dominantNames.contains(key));
  });

  int score(SongItem s) {
    final titleCanon = canonicalMetadata(s.track.title);
    if (titleCanon.isEmpty) return 0;
    final titleTokens = titleCanon
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    final artistTokens = s.track.artists
        .expand((a) => canonicalMetadata(a.name).split(' '))
        .where((t) => t.isNotEmpty)
        .toSet();
    final titleHits = titleTokens.where(queryTokens.contains).length;
    final artistHits = artistTokens.where(queryTokens.contains).length;
    var points = titleHits + artistHits;
    if (titleCanon == queryCanon) points += 400;
    if (queryCanon.contains(titleCanon)) points += 200;
    if (titleTokens.every(queryTokens.contains)) points += 100;
    if (artistHits > 0) points += 50;
    if (isDominant(s)) points += 25;
    // Popularity: YouTube's view count is the only signal we have for
    // "which recording of this title is the canonical one" (e.g.
    // "Godzilla" → Eminem). Add a log-scaled bonus so a 1B-view
    // original outranks a 10k-view cover when text match is equal.
    points += _viewsBonus(s.track.views);
    return points;
  }

  final ranked = songs.toList();
  ranked.sort((a, b) => score(b).compareTo(score(a)));
  return ranked;
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
  final headerArtist = _headerArtist(header);
  final kind = detectReleaseKind(subtitle) ?? detectReleaseKind(description);
  final year = detectReleaseYear(subtitle);
  final tracks = <Track>[];
  final contents = nav(shelf, const ['contents']);
  if (contents is List) {
    for (final it in contents) {
      final li = nav(it, const ['musicResponsiveListItemRenderer']);
      if (li == null) continue;
      final parsed = parseListItem(li);
      if (parsed == null) continue;
      // Only linked header artists backfill track rows: stamping an
      // unlinked credit (e.g. Various Artists) would poison artist-based
      // matching downstream.
      final linkedHeader = headerArtist?.browseId != null ? headerArtist : null;
      // Header metadata fills only what the row lacks: thumbnails, a
      // linked artist, the album reference, and a missing year.
      var track = mergeTrack(
        parsed,
        Track(
          videoId: parsed.videoId,
          title: '',
          artists: linkedHeader != null ? [linkedHeader] : const [],
          album: albumTitle.isNotEmpty
              ? AlbumRef(albumTitle, browseId: browseId, kind: kind, year: year)
              : null,
          thumbnails: headerThumbs,
        ),
        const TrackMerge(
          artists: ArtistMerge.fillMissing,
          album: AlbumMerge.fillMissing,
          title: TitleMerge.keepCurrent,
          thumbnails: ThumbnailMerge.fillMissing,
          duration: false,
          explicit: false,
        ),
      );
      if (parsed.artists.isEmpty && linkedHeader != null) {
        track = track.copyWith(artistId: () => linkedHeader.browseId);
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
/// The browse items of an artist carousel shelf.
List<BrowseItem> _carouselItems(dynamic shelf) {
  final out = <BrowseItem>[];
  final contents = nav(shelf, const ['contents']);
  if (contents is! List) return out;
  for (final element in contents) {
    final item = nav(element, const ['musicTwoRowItemRenderer']);
    if (item == null) continue;
    final endpoint = nav(item, const ['navigationEndpoint', 'browseEndpoint']);
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

/// The list an artist carousel belongs to, by its title and its items.
List<BrowseItem> _carouselDestination(
  String title,
  List<BrowseItem> items, {
  required List<BrowseItem> albums,
  required List<BrowseItem> singlesAndEps,
  required List<BrowseItem> relatedPlaylists,
  required List<BrowseItem> similarArtists,
}) {
  final tokens = canonicalMetadata(title)
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toSet();
  if (tokens.contains('album') || tokens.contains('albums')) return albums;
  if (tokens.contains('single') ||
      tokens.contains('singles') ||
      tokens.contains('ep') ||
      tokens.contains('eps')) {
    return singlesAndEps;
  }
  if (tokens.contains('playlist') ||
      tokens.contains('playlists') ||
      tokens.contains('featured')) {
    return relatedPlaylists;
  }
  if (tokens.contains('fan') ||
      tokens.contains('fans') ||
      tokens.contains('similar')) {
    return similarArtists;
  }
  if (items.any((item) => item.browseId.startsWith('UC'))) {
    return similarArtists;
  }
  if (items.any((item) => item.browseId.startsWith('VL'))) {
    return relatedPlaylists;
  }
  return albums;
}

/// The browse items of a list, without repeated ids.
List<BrowseItem> _distinctById(List<BrowseItem> items) {
  final seen = <String>{};
  return items.where((item) => seen.add(item.browseId)).toList();
}

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
  // Prefer the shelf titled "top songs" (in any locale the word
  // "songs"/"tracks" appears), but fall back to the first shelf whose
  // contents actually parse as tracks — the title match alone misses
  // localized pages ("Canciones principales", "Top-Titel", ...).
  Map? topShelf;
  for (final s in findAll(res, 'musicShelfRenderer')) {
    if (s is! Map) continue;
    final title = runsText(nav(s, const ['title', 'runs'])).toLowerCase();
    if (title.contains('song') ||
        title.contains('track') ||
        title.contains('titel') ||
        title.contains('cancion') ||
        title.contains('titre')) {
      topShelf = s;
      break;
    }
  }
  final topSongs = <Track>[];
  // If the titled shelf yielded nothing parseable, try every shelf and
  // keep the first one that produces tracks.
  List<Map> shelvesToTry = [];
  if (topShelf is Map) shelvesToTry.add(topShelf);
  for (final s in findAll(res, 'musicShelfRenderer')) {
    if (s is Map && s != topShelf) shelvesToTry.add(s);
  }
  for (final shelf in shelvesToTry) {
    final contents = nav(shelf, const ['contents']);
    if (contents is! List) continue;
    final parsed = <Track>[];
    for (final it in contents) {
      final li = nav(it, const ['musicResponsiveListItemRenderer']);
      if (li == null) continue;
      final t = parseListItem(li);
      if (t != null) parsed.add(t);
    }
    if (parsed.isNotEmpty) {
      topSongs.addAll(parsed);
      topShelf = shelf;
      break;
    }
  }
  // Resolve the songs playlist id from whichever shelf we used.
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

  for (final shelf in findAll(res, 'musicCarouselShelfRenderer')) {
    final title = runsText(
      nav(shelf, const [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'title',
        'runs',
      ]),
    );
    final items = _carouselItems(shelf);
    if (items.isEmpty) continue;
    _carouselDestination(
      title,
      items,
      albums: albums,
      singlesAndEps: singlesAndEps,
      relatedPlaylists: relatedPlaylists,
      similarArtists: similarArtists,
    ).addAll(items);
  }

  return ArtistDetail(
    name: runsText(nav(header, const ['title', 'runs'])),
    description: runsText(nav(header, const ['description', 'runs'])),
    thumbnails: parseThumbnails(header),
    topSongs: topSongs,
    albums: _distinctById(albums),
    singlesAndEps: _distinctById(singlesAndEps),
    relatedPlaylists: _distinctById(relatedPlaylists),
    similarArtists: _distinctById(similarArtists),
    songsPlaylistId: songsPlaylistId,
    songsPlaylistParams: songsPlaylistParams,
    subscribers: subscribers,
  );
}

/// The playlist page's header, plus the editable-header renderer it came
/// from (which decides whether the playlist can be edited).
({dynamic header, dynamic editable}) _playlistHeader(dynamic res) {
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
  return (header: header, editable: editable);
}

/// The artist ref a detail header carries: a linked channel first, then
/// a plain-text credit.
ArtistRef? _headerArtist(dynamic header) {
  final runs = [
    nav(header, const ['subtitle', 'runs']),
    nav(header, const ['straplineTextOne', 'runs']),
    nav(header, const ['straplineTextTwo', 'runs']),
    nav(header, const ['secondSubtitle', 'runs']),
  ];
  return channelRefFromRuns(runs) ?? plainRefFromRuns(runs);
}

/// Builds a playlist detail from a `browse` response, or null when the
/// track shelf is missing.
PlaylistDetail? buildPlaylist(dynamic res) {
  final page = _playlistHeader(res);
  final header = page.header;
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
      if (t != null) {
        // Playlist rows keep the running time in the fixed columns.
        final duration = parseRowDuration(li);
        tracks.add(duration > 0 ? t.copyWith(durationSec: duration) : t);
      }
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
  final author = header is Map ? _headerArtist(header) : null;
  return PlaylistDetail(
    title: title,
    subtitle: subtitle,
    thumbnails: thumbnails,
    tracks: tracks,
    author: author,
    editable: page.editable is Map,
  );
}

/// First non-empty artwork from the playlist header/background/microformat,
/// trying the PL/VL id variants is the caller's job.
List<Thumbnail> playlistArtworkThumbs(dynamic res) {
  final header = _playlistHeader(res).header;
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

/// Visits every `musicResponsiveListItemRenderer` in [res], depth-first
/// in document order, stopping after [maxItems] rows.
void _walkListItems(dynamic res, int maxItems, void Function(Map item) visit) {
  var total = 0;
  void walk(dynamic node) {
    if (node == null || total >= maxItems) return;
    if (node is List) {
      for (final e in node) {
        walk(e);
        if (total >= maxItems) return;
      }
      return;
    }
    if (node is! Map) return;
    final item = node['musicResponsiveListItemRenderer'];
    if (item is Map) {
      total++;
      visit(item);
      return;
    }
    for (final v in node.values) {
      walk(v);
      if (total >= maxItems) return;
    }
  }

  walk(res);
}

/// Full tracks from a `FEmusic_history` browse response, most recent
/// first, deduplicated by video id. Unparseable entries are skipped.
/// Stops after [maxItems] entries. Used for the quick-picks pool so
/// heavy rotation from other sessions can surface on this device.
List<Track> parseHistoryTracks(dynamic res, {int maxItems = 500}) {
  final tracks = <Track>[];
  final seen = <String>{};
  _walkListItems(res, maxItems, (item) {
    final t = parseListItem(item);
    if (t != null && t.videoId.isNotEmpty && seen.add(t.videoId)) {
      tracks.add(t);
    }
  });
  return tracks;
}

/// Play counts from a `FEmusic_history` browse response: the history
/// page lists every play (repeats appear multiple times across the
/// day-grouped shelves), so `musicResponsiveListItemRenderer` video
/// ids are counted as-is. Stops after [maxItems] entries. Empty when
/// signed out (the "Sign in" wall carries no items) or on any
/// unexpected shape — callers keep existing counts then.
Map<String, int> parseHistoryCounts(dynamic res, {int maxItems = 500}) {
  final counts = <String, int>{};
  _walkListItems(res, maxItems, (item) {
    final id = str(nav(item, const ['playlistItemData', 'videoId']));
    if (id != null && id.isNotEmpty) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
  });
  return counts;
}
