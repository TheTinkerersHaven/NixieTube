// Domain models of the InnerTube API.
//
// Pure data, no Flutter imports — reusable under any frontend.

/// Image thumbnail with its dimensions; zero width/height means unknown.
class Thumbnail {
  const Thumbnail(this.url, {this.width = 0, this.height = 0});

  final String url;
  final int width;
  final int height;

  static final RegExp _squareSizeRe = RegExp(r'=w(\d+)-h(\d+)(?:\D|$)');
  static final RegExp _whSizeRe = RegExp(r'=w(\d+)-h(\d+)');

  /// True when the thumbnail is square, using explicit dimensions or the
  /// Google `=w{W}-h{H}` URL sizing suffix as fallback.
  bool get isSquare {
    if (width > 0 && height > 0) return width == height;
    final m = _squareSizeRe.firstMatch(url);
    if (m == null) return false;
    final w = int.tryParse(m.group(1)!);
    final h = int.tryParse(m.group(2)!);
    return w != null && h != null && w > 0 && w == h;
  }

  /// Returns a copy requesting a larger rendition from Google image
  /// servers. Never downscales or distorts.
  Thumbnail upscaledTo(int targetWidth) {
    if (targetWidth <= 0 || (width > 0 && width >= targetWidth)) return this;
    if (width > 0 && height > 0 && _whSizeRe.hasMatch(url)) {
      final newH = (targetWidth * height ~/ width).clamp(1, 1 << 31);
      return Thumbnail(
        url.replaceFirst(_whSizeRe, '=w$targetWidth-h$newH'),
        width: width,
        height: height,
      );
    }
    if (!_whSizeRe.hasMatch(url)) {
      return Thumbnail('$url=w$targetWidth', width: width, height: height);
    }
    return this;
  }

  @override
  bool operator ==(Object other) =>
      other is Thumbnail &&
      other.url == url &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(url, width, height);

  Map<String, dynamic> toJson() => {
    'url': url,
    'width': width,
    'height': height,
  };

  factory Thumbnail.fromJson(Map<String, dynamic> json) => Thumbnail(
    json['url'] as String? ?? '',
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
  );
}

/// Like state of a track as reported by YouTube.
enum RatingStatus {
  like,
  dislike,
  indifferent,
  unknown;

  /// Maps a raw InnerTube status string to a [RatingStatus].
  static RatingStatus fromValue(String? value) {
    switch (value?.trim().toUpperCase()) {
      case 'LIKE':
        return RatingStatus.like;
      case 'DISLIKE':
        return RatingStatus.dislike;
      case 'INDIFFERENT':
      case 'NONE':
      case 'REMOVED':
        return RatingStatus.indifferent;
      default:
        return RatingStatus.unknown;
    }
  }
}

/// Kind of music release used to classify browse results and album headers.
enum ReleaseKind {
  album('Album'),
  ep('EP'),
  single('Single'),
  compilation('Compilation'),
  mixed('Mixed');

  const ReleaseKind(this.label);
  final String label;
}

/// A playable music track from YouTube Music.
class Track {
  const Track({
    required this.videoId,
    required this.title,
    this.artists = const [],
    this.album,
    this.durationSec = 0,
    this.thumbnails = const [],
    this.playlistId,
    this.radioPlaylistId,
    this.artistId,
    this.views = '',
    this.rating = RatingStatus.unknown,
    this.likeCount = -1,
    this.dislikeCount = -1,
    this.explicit = false,
  });

  final String videoId;
  final String title;
  final List<ArtistRef> artists;
  final AlbumRef? album;
  final int durationSec;
  final List<Thumbnail> thumbnails;
  final String? playlistId;
  final String? radioPlaylistId;
  final String? artistId;
  final String views;
  final RatingStatus rating;

  /// Public like count, or -1 when unknown.
  final int likeCount;

  /// Public dislike count, or -1 when unknown.
  final int dislikeCount;

  /// Flagged explicit by the backend (`MUSIC_EXPLICIT_BADGE`). UI-only
  /// badge data from list/queue responses — never from `videoDetails`,
  /// so a track fetched by id alone reads false.
  final bool explicit;

  /// Comma-joined artist names for display rows.
  String artistNames() => artists.map((a) => a.name).join(', ');

  /// Largest thumbnail by width, regardless of shape. Banners, MPRIS
  /// and Discord use this; square tiles prefer [displayArtwork].
  /// Ties (including missing dimensions) go to the LAST thumb:
  /// YouTube orders sizes ascending, so the final entry is the
  /// biggest.
  String? get bestArtwork {
    if (thumbnails.isEmpty) return null;
    var best = thumbnails.first;
    for (final t in thumbnails.skip(1)) {
      if (t.width >= best.width) best = t;
    }
    return best.url;
  }

  /// Song display art: prefer a true 1:1 cover over a larger 16:9 video
  /// frame. Falls back to the largest available. Ties (including
  /// missing dimensions) go to the LAST square thumb for the same
  /// ascending-order reason as [bestArtwork].
  String? get displayArtwork {
    String? best;
    var bestW = -1;
    for (final t in thumbnails) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t.url;
      }
    }
    return best ?? bestArtwork;
  }

  Track copyWith({
    String? videoId,
    String? title,
    List<ArtistRef>? artists,
    AlbumRef? album,
    int? durationSec,
    List<Thumbnail>? thumbnails,
    String? Function()? playlistId,
    String? Function()? radioPlaylistId,
    String? Function()? artistId,
    String? views,
    RatingStatus? rating,
    int? likeCount,
    int? dislikeCount,
    bool? explicit,
  }) {
    return Track(
      videoId: videoId ?? this.videoId,
      title: title ?? this.title,
      artists: artists ?? this.artists,
      album: album ?? this.album,
      durationSec: durationSec ?? this.durationSec,
      thumbnails: thumbnails ?? this.thumbnails,
      playlistId: playlistId != null ? playlistId() : this.playlistId,
      radioPlaylistId: radioPlaylistId != null
          ? radioPlaylistId()
          : this.radioPlaylistId,
      artistId: artistId != null ? artistId() : this.artistId,
      views: views ?? this.views,
      rating: rating ?? this.rating,
      likeCount: likeCount ?? this.likeCount,
      dislikeCount: dislikeCount ?? this.dislikeCount,
      explicit: explicit ?? this.explicit,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Track &&
      other.videoId == videoId &&
      other.title == title &&
      _listEq(other.artists, artists) &&
      other.album == album &&
      other.durationSec == durationSec &&
      _listEq(other.thumbnails, thumbnails) &&
      other.playlistId == playlistId &&
      other.radioPlaylistId == radioPlaylistId &&
      other.artistId == artistId &&
      other.views == views &&
      other.rating == rating &&
      other.likeCount == likeCount &&
      other.dislikeCount == dislikeCount &&
      other.explicit == explicit;

  @override
  int get hashCode => Object.hash(
    videoId,
    title,
    Object.hashAll(artists),
    album,
    durationSec,
    Object.hashAll(thumbnails),
    playlistId,
    radioPlaylistId,
    artistId,
    views,
    rating,
    likeCount,
    dislikeCount,
    explicit,
  );

  Map<String, dynamic> toJson() => {
    'videoId': videoId,
    'title': title,
    'artists': artists.map((a) => a.toJson()).toList(),
    if (album != null) 'album': album!.toJson(),
    'durationSec': durationSec,
    'thumbnails': thumbnails.map((t) => t.toJson()).toList(),
    if (playlistId != null) 'playlistId': playlistId,
    if (radioPlaylistId != null) 'radioPlaylistId': radioPlaylistId,
    if (artistId != null) 'artistId': artistId,
    if (views.isNotEmpty) 'views': views,
    'rating': rating.name,
    'likeCount': likeCount,
    'dislikeCount': dislikeCount,
    if (explicit) 'explicit': true,
  };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    videoId: json['videoId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    artists: ((json['artists'] as List?) ?? [])
        .whereType<Map>()
        .map(
          (e) => ArtistRef.fromJson(e.map((k, v) => MapEntry(k.toString(), v))),
        )
        .toList(),
    album: json['album'] is Map
        ? AlbumRef.fromJson(
            (json['album'] as Map).map((k, v) => MapEntry(k.toString(), v)),
          )
        : null,
    durationSec: (json['durationSec'] as num?)?.toInt() ?? 0,
    thumbnails: ((json['thumbnails'] as List?) ?? [])
        .whereType<Map>()
        .map(
          (e) => Thumbnail.fromJson(e.map((k, v) => MapEntry(k.toString(), v))),
        )
        .toList(),
    playlistId: json['playlistId'] as String?,
    radioPlaylistId: json['radioPlaylistId'] as String?,
    artistId: json['artistId'] as String?,
    views: json['views'] as String? ?? '',
    rating: _ratingFromName(json['rating'] as String?),
    likeCount: (json['likeCount'] as num?)?.toInt() ?? -1,
    dislikeCount: (json['dislikeCount'] as num?)?.toInt() ?? -1,
    explicit: json['explicit'] == true,
  );
}

RatingStatus _ratingFromName(String? name) {
  if (name == null) return RatingStatus.unknown;
  for (final rating in RatingStatus.values) {
    if (rating.name == name) return rating;
  }
  return RatingStatus.unknown;
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Reference to an artist channel.
class ArtistRef {
  const ArtistRef(this.name, {this.browseId});

  final String name;

  /// Channel browse id (UC…), or null when unlinked.
  final String? browseId;

  @override
  bool operator ==(Object other) =>
      other is ArtistRef && other.name == name && other.browseId == browseId;

  @override
  int get hashCode => Object.hash(name, browseId);

  Map<String, dynamic> toJson() => {
    'name': name,
    if (browseId != null) 'browseId': browseId,
  };

  factory ArtistRef.fromJson(Map<String, dynamic> json) => ArtistRef(
    json['name'] as String? ?? '',
    browseId: json['browseId'] as String?,
  );
}

/// Reference to an album/release page.
class AlbumRef {
  const AlbumRef(this.name, {this.browseId, this.kind, this.year = ''});

  final String name;
  final String? browseId;
  final ReleaseKind? kind;
  final String year;

  @override
  bool operator ==(Object other) =>
      other is AlbumRef &&
      other.name == name &&
      other.browseId == browseId &&
      other.kind == kind &&
      other.year == year;

  @override
  int get hashCode => Object.hash(name, browseId, kind, year);

  Map<String, dynamic> toJson() => {
    'name': name,
    if (browseId != null) 'browseId': browseId,
    if (kind != null) 'kind': kind!.name,
    if (year.isNotEmpty) 'year': year,
  };

  factory AlbumRef.fromJson(Map<String, dynamic> json) => AlbumRef(
    json['name'] as String? ?? '',
    browseId: json['browseId'] as String?,
    kind: _releaseKindFromName(json['kind'] as String?),
    year: json['year'] as String? ?? '',
  );
}

ReleaseKind? _releaseKindFromName(String? name) {
  if (name == null) return null;
  for (final kind in ReleaseKind.values) {
    if (kind.name == name) return kind;
  }
  return null;
}

/// A home-screen shelf entry: either a playable song or a browsable item.
sealed class ShelfItem {
  const ShelfItem();

  const factory ShelfItem.song(Track track) = SongItem;

  factory ShelfItem.browse({
    required String title,
    required String subtitle,
    required String browseId,
    required List<Thumbnail> thumbnails,
    ReleaseKind? kind,
    String? browseParams,
  }) = BrowseItem;
}

/// A tap-to-play home mix: either an InnerTube mix playlist page
/// (`VLRD…` mood/custom mixes) or a personalized mix seed card
/// (`RDEM…`/`RDCLAK…` watch cards like My Mix, Discover Mix) carrying
/// the seed track its radio playlist resolves from.
class HomeMix {
  const HomeMix({
    required this.title,
    required this.subtitle,
    required this.thumbnails,
    this.browseId,
    this.seed,
  });

  final String title;
  final String subtitle;
  final List<Thumbnail> thumbnails;

  /// Largest thumbnail by width, regardless of shape.
  String? get bestArtwork {
    if (thumbnails.isEmpty) return null;
    var best = thumbnails.first;
    for (final t in thumbnails.skip(1)) {
      if (t.width >= best.width) best = t;
    }
    return best.url;
  }

  /// Prefer a true 1:1 cover over a larger 16:9 frame.
  String? get displayArtwork {
    String? best;
    var bestW = -1;
    for (final t in thumbnails) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t.url;
      }
    }
    return best ?? bestArtwork;
  }

  /// Mix playlist page id (`VLRD…`), when the mix opens as a page.
  final String? browseId;

  /// Seed track for personalized mix cards; plays via its radio list.
  final Track? seed;
}

/// Playable song entry.
class SongItem extends ShelfItem {
  const SongItem(this.track);
  final Track track;

  @override
  bool operator ==(Object other) => other is SongItem && other.track == track;

  @override
  int get hashCode => track.hashCode;
}

/// Browsable entry (album, playlist, artist).
class BrowseItem extends ShelfItem {
  const BrowseItem({
    required this.title,
    required this.subtitle,
    required this.browseId,
    required this.thumbnails,
    this.kind,
    this.browseParams,
  });

  final String title;
  final String subtitle;
  final String browseId;
  final List<Thumbnail> thumbnails;

  /// Whether this item opens a playlist page (including mixes and the
  /// auto-generated radio lists) rather than an artist or album page.
  bool get isPlaylist {
    final id = browseId.trim();
    // `VL…` is InnerTube's "video list" (playlist) browse prefix;
    // album playlists and radios also appear in their raw forms.
    return id.startsWith('VL') ||
        id.startsWith('PL') ||
        id.startsWith('RD') ||
        id.startsWith('OLAK5uy_');
  }

  /// Largest thumbnail by width, regardless of shape.
  String? get bestArtwork {
    if (thumbnails.isEmpty) return null;
    var best = thumbnails.first;
    for (final t in thumbnails.skip(1)) {
      if (t.width >= best.width) best = t;
    }
    return best.url;
  }

  /// Prefer a true 1:1 cover over a larger 16:9 frame.
  String? get displayArtwork {
    String? best;
    var bestW = -1;
    for (final t in thumbnails) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t.url;
      }
    }
    return best ?? bestArtwork;
  }

  final ReleaseKind? kind;
  final String? browseParams;

  @override
  bool operator ==(Object other) =>
      other is BrowseItem &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.browseId == browseId &&
      _listEq(other.thumbnails, thumbnails) &&
      other.kind == kind &&
      other.browseParams == browseParams;

  @override
  int get hashCode => Object.hash(
    title,
    subtitle,
    browseId,
    Object.hashAll(thumbnails),
    kind,
    browseParams,
  );
}

/// A home-screen shelf (carousel or list) with its items.
///
/// A shelf may carry a [continuation] token: when present, YouTube has
/// more items for it and a "load more" action appears under the row.
class Shelf {
  const Shelf(this.title, this.items, {this.continuation});
  final String title;
  final List<ShelfItem> items;

  /// Continuation token for loading the next page of this shelf, or null
  /// when the shelf is complete (or the feed didn't supply one).
  final String? continuation;

  /// Whether a load-more action should be offered for this shelf.
  bool get hasMore => continuation?.isNotEmpty == true;
}

/// Full album/release page.
class AlbumDetail {
  const AlbumDetail({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.thumbnails,
    required this.tracks,
    this.kind,
    this.year = '',
    this.artist,
  });

  final String title;
  final String subtitle;
  final String description;
  final List<Thumbnail> thumbnails;

  /// Largest thumbnail by width, regardless of shape.
  String? get bestArtwork {
    if (thumbnails.isEmpty) return null;
    var best = thumbnails.first;
    for (final t in thumbnails.skip(1)) {
      if (t.width >= best.width) best = t;
    }
    return best.url;
  }

  /// Prefer a true 1:1 cover over a larger 16:9 frame.
  String? get displayArtwork {
    String? best;
    var bestW = -1;
    for (final t in thumbnails) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t.url;
      }
    }
    return best ?? bestArtwork;
  }

  /// Resolves the panel art: the album's own cover, otherwise the first
  /// track's, falling back to the originating browse item's thumbnail.
  String? artworkOr(BrowseItem? item) {
    if (thumbnails.isNotEmpty) return bestArtwork;
    final fromTrack = tracks
        .map((t) => t.displayArtwork)
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .firstOrNull;
    if (fromTrack != null) return fromTrack;
    if (item != null && item.thumbnails.isNotEmpty) return item.bestArtwork;
    return null;
  }

  final List<Track> tracks;
  final ReleaseKind? kind;
  final String year;
  final ArtistRef? artist;
}

/// Full artist page.
class ArtistDetail {
  const ArtistDetail({
    required this.name,
    required this.description,
    required this.thumbnails,
    required this.topSongs,
    required this.albums,
    this.singlesAndEps = const [],
    this.relatedPlaylists = const [],
    this.similarArtists = const [],
    this.songsPlaylistId,
    this.songsPlaylistParams,
    this.subscribers = '',
  });

  final String name;
  final String description;
  final List<Thumbnail> thumbnails;

  /// Largest thumbnail by width, regardless of shape.
  String? get bestArtwork {
    if (thumbnails.isEmpty) return null;
    var best = thumbnails.first;
    for (final t in thumbnails.skip(1)) {
      if (t.width >= best.width) best = t;
    }
    return best.url;
  }

  /// Prefer a true 1:1 cover over a larger 16:9 frame.
  String? get displayArtwork {
    String? best;
    var bestW = -1;
    for (final t in thumbnails) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t.url;
      }
    }
    return best ?? bestArtwork;
  }

  final List<Track> topSongs;
  final List<BrowseItem> albums;
  final List<BrowseItem> singlesAndEps;
  final List<BrowseItem> relatedPlaylists;
  final List<BrowseItem> similarArtists;
  final String? songsPlaylistId;
  final String? songsPlaylistParams;
  final String subscribers;

  /// Copy with a different top-songs list (used to preload more of the
  /// songs playlist than the preview the API embeds in the page).
  ArtistDetail copyWith({List<Track>? topSongs}) => ArtistDetail(
    name: name,
    description: description,
    thumbnails: thumbnails,
    topSongs: topSongs ?? this.topSongs,
    albums: albums,
    singlesAndEps: singlesAndEps,
    relatedPlaylists: relatedPlaylists,
    similarArtists: similarArtists,
    songsPlaylistId: songsPlaylistId,
    songsPlaylistParams: songsPlaylistParams,
    subscribers: subscribers,
  );
}

/// Full playlist page.
class PlaylistDetail {
  const PlaylistDetail({
    required this.title,
    required this.subtitle,
    required this.thumbnails,
    required this.tracks,
    this.author,
    this.id = '',
    this.editable = false,
  });

  final String title;
  final String subtitle;
  final List<Thumbnail> thumbnails;

  /// The raw playlist id (`PL…`), when the caller knows it.
  final String id;

  /// Whether the signed-in account can edit this playlist (rename,
  /// delete, remove tracks). False for public and read-only lists.
  final bool editable;

  /// Largest thumbnail by width, regardless of shape.
  String? get bestArtwork {
    if (thumbnails.isEmpty) return null;
    var best = thumbnails.first;
    for (final t in thumbnails.skip(1)) {
      if (t.width >= best.width) best = t;
    }
    return best.url;
  }

  /// Prefer a true 1:1 cover over a larger 16:9 frame.
  String? get displayArtwork {
    String? best;
    var bestW = -1;
    for (final t in thumbnails) {
      if (t.isSquare && t.width >= bestW) {
        bestW = t.width;
        best = t.url;
      }
    }
    return best ?? bestArtwork;
  }

  /// Resolves the panel art: the playlist's own cover, otherwise the
  /// originating browse item's thumbnail.
  String? artworkOr(BrowseItem? item) {
    if (thumbnails.isNotEmpty) return bestArtwork;
    if (item != null && item.thumbnails.isNotEmpty) return item.bestArtwork;
    return null;
  }

  final List<Track> tracks;
  final ArtistRef? author;
}

/// A playlist from the signed-in account's library.
class AccountPlaylist {
  const AccountPlaylist({
    required this.id,
    required this.title,
    required this.itemCount,
    this.art,
    this.arts = const [],
    this.owner = '',
    this.ownerId = '',
  });

  /// The playlist id (a `PL…` id usable for edits).
  final String id;
  final String title;
  final int itemCount;

  /// Best playlist-cover URL, or null when none.
  final String? art;

  /// Additional cover URLs, if any.
  final List<String> arts;
  final String owner;
  final String ownerId;
}

/// One synced lyric line.
class LyricLine {
  const LyricLine({required this.timeMs, required this.text});
  final int timeMs;
  final String text;
}

/// Search section filter.
enum SearchFilter {
  songs('Songs'),
  releases('Albums/EP/Singles'),
  artists('Artists');

  const SearchFilter(this.label);
  final String label;
}
