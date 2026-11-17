// Shared track-merge policy.
//
// Track metadata arrives from several places — watch-next panels,
// catalog enrichment, the local enrichment cache, and album headers —
// and each used to merge it with its own copy of the same precedence
// rules. This file is the single implementation: a caller picks a policy
// and hands over the incoming track.
//
// Identity fields (`videoId`, playlist/radio ids, `artistId`, `views`,
// `rating`, like/dislike counts) are never touched here; callers that
// need to update them do so explicitly.

import '../models/models.dart';
import 'metadata.dart'
    show canonical, hasGenericReleaseArtist, preferredTrackTitle;

/// How much of the incoming artists replace the current credit.
enum ArtistMerge {
  /// Panel/catalog: replace when the current credit is empty or the
  /// generic "Release" placeholder, when the incoming list has more
  /// artists, adds a new name, or upgrades an unlinked same-name credit
  /// with a browse id.
  panel,

  /// Cache: replace only a clearly thin credit (empty, generic, or a
  /// single unlinked name), plus the same-name link upgrade.
  thin,

  /// Header backfill: fill only when the current credit is empty.
  fillMissing,
}

/// How an incoming album reference combines with the current one.
enum AlbumMerge {
  /// Panel/catalog: prefer the incoming reference when it is linked,
  /// adds a kind, or replaces a placeholder/unlinked-artist album.
  preferred,

  /// Only fill when the current album is missing; fill a missing year
  /// on the kept reference from the incoming one.
  fillMissing,
}

/// How an incoming title combines with the current one.
enum TitleMerge {
  /// Keep the current title.
  keepCurrent,

  /// Prefer whichever title carries a featured-artist credit.
  preferredFeatured,

  /// Take the incoming title when it is non-empty.
  incomingWins,
}

/// How incoming thumbnails combine with the current ones.
enum ThumbnailMerge {
  /// Keep the current thumbnails.
  keep,

  /// Union by URL, current first.
  union,

  /// Fill only when the current list is empty.
  fillMissing,
}

/// Options for [mergeTrack].
class TrackMerge {
  const TrackMerge({
    this.artists = ArtistMerge.panel,
    this.album = AlbumMerge.preferred,
    this.title = TitleMerge.preferredFeatured,
    this.thumbnails = ThumbnailMerge.union,
    this.duration = true,
    this.explicit = true,
  });

  final ArtistMerge artists;
  final AlbumMerge album;
  final TitleMerge title;
  final ThumbnailMerge thumbnails;

  /// Fill a missing duration from the incoming track (a known catalog
  /// duration always wins).
  final bool duration;

  /// OR the explicit flags: a missing badge is "not marked", never
  /// "clean".
  final bool explicit;
}

/// Merges [incoming] into [current] with one shared precedence policy.
Track mergeTrack(
  Track current,
  Track incoming, [
  TrackMerge options = const TrackMerge(),
]) {
  final artists = _mergeArtists(current, incoming.artists, options.artists);
  // `copyWith` treats a null album as "keep", so folding the fallback
  // here keeps the merge's result identical to the old call sites.
  final album =
      _mergeAlbum(current, incoming, options.album) ?? current.album;
  final thumbnails = _mergeThumbnails(
    current.thumbnails,
    incoming.thumbnails,
    options.thumbnails,
  );
  final title = switch (options.title) {
    TitleMerge.keepCurrent => current.title,
    TitleMerge.preferredFeatured =>
      preferredTrackTitle(current.title, incoming.title),
    TitleMerge.incomingWins =>
      incoming.title.isNotEmpty ? incoming.title : current.title,
  };
  final duration =
      options.duration && current.durationSec <= 0 && incoming.durationSec > 0
      ? incoming.durationSec
      : current.durationSec;
  final explicit = options.explicit
      ? (current.explicit || incoming.explicit)
      : current.explicit;

  if (identical(artists, current.artists) &&
      identical(album, current.album) &&
      identical(thumbnails, current.thumbnails) &&
      title == current.title &&
      duration == current.durationSec &&
      explicit == current.explicit) {
    return current;
  }
  return current.copyWith(
    title: title,
    artists: artists,
    album: album,
    durationSec: duration,
    thumbnails: thumbnails,
    explicit: explicit,
  );
}

List<ArtistRef> _mergeArtists(
  Track current,
  List<ArtistRef> incoming,
  ArtistMerge policy,
) {
  if (incoming.isEmpty) return current.artists;
  final replace = switch (policy) {
    ArtistMerge.panel => _panelReplacesArtists(current, incoming),
    ArtistMerge.thin => _thinReplacesArtists(current, incoming),
    ArtistMerge.fillMissing => current.artists.isEmpty,
  };
  return replace ? List.of(incoming) : current.artists;
}

/// The panel/catalog rule: a thin or generic credit is replaced, and a
/// fuller incoming list wins; a same-name unlinked credit is upgraded to
/// the incoming link.
bool _panelReplacesArtists(Track current, List<ArtistRef> incoming) {
  final replaceGeneric =
      current.artists.isEmpty ||
      current.artistNames().trim().toLowerCase() == 'release';
  final existingKeys = current.artists
      .map((artist) => canonical(artist.name))
      .toSet();
  final addsArtist = incoming.any(
    (artist) => !existingKeys.contains(canonical(artist.name)),
  );
  final addsIdentity = incoming.any((incomingArtist) {
    final key = canonical(incomingArtist.name);
    return current.artists.any(
      (existing) =>
          canonical(existing.name) == key &&
          (existing.browseId == null || existing.browseId!.isEmpty) &&
          incomingArtist.browseId != null &&
          incomingArtist.browseId!.isNotEmpty,
    );
  });
  return replaceGeneric ||
      incoming.length > current.artists.length ||
      addsArtist ||
      addsIdentity;
}

/// The cache rule: only a clearly thin credit (empty, generic, or a
/// single unlinked name) is replaced, plus the same-name link upgrade.
/// A multi-artist or linked credit is assumed complete.
bool _thinReplacesArtists(Track current, List<ArtistRef> incoming) {
  if (current.artists.isEmpty || hasGenericReleaseArtist(current)) return true;
  if (current.artists.length == 1 &&
      (current.artists.single.browseId ?? '').isEmpty) {
    return true;
  }
  if (incoming.length == 1 && current.artists.length == 1) {
    final cur = current.artists.single;
    final inc = incoming.single;
    return (cur.browseId ?? '').isEmpty &&
        (inc.browseId ?? '').isNotEmpty &&
        canonical(cur.name) == canonical(inc.name);
  }
  return false;
}

AlbumRef? _mergeAlbum(Track current, Track incoming, AlbumMerge policy) {
  switch (policy) {
    case AlbumMerge.fillMissing:
      return _fillMissingAlbum(current.album, incoming.album);
    case AlbumMerge.preferred:
      return _preferredAlbum(current, incoming);
  }
}

/// Fill only a missing album, or a missing year on the kept one.
AlbumRef? _fillMissingAlbum(AlbumRef? current, AlbumRef? incoming) {
  if (current == null) return incoming;
  if (current.year.isEmpty && incoming != null && incoming.year.isNotEmpty) {
    return AlbumRef(
      current.name,
      browseId: current.browseId,
      kind: current.kind,
      year: incoming.year,
    );
  }
  return current;
}

/// The album reference that describes the track best. The incoming
/// reference wins over a placeholder ("Release") or an unlinked album
/// that only repeats an artist name; otherwise the current reference
/// stays. A missing year is filled from the incoming reference even when
/// the current album is kept.
AlbumRef? _preferredAlbum(Track current, Track incoming) {
  final cur = current.album;
  final inc = incoming.album;
  final artists = [...current.artists, ...incoming.artists];
  final currentIsUnlinkedArtist =
      cur != null &&
      (cur.browseId == null || cur.browseId!.isEmpty) &&
      cur.kind == null &&
      artists.any(
        (artist) => canonical(artist.name) == canonical(cur.name),
      );

  AlbumRef? merged;
  if (currentIsUnlinkedArtist && inc == null) {
    merged = null;
  } else if (inc == null) {
    merged = cur;
  } else if (cur == null) {
    merged = inc;
  } else if (cur.name.trim().toLowerCase() == 'release') {
    merged = inc;
  } else if (currentIsUnlinkedArtist) {
    merged = inc;
  } else if ((cur.browseId == null || cur.browseId!.isEmpty) &&
      inc.browseId != null &&
      inc.browseId!.isNotEmpty) {
    merged = inc;
  } else if (cur.kind == null && inc.kind != null) {
    // Take the incoming kind/name/id but keep the current year; the
    // fill below adds the incoming year when the current one is empty.
    merged = AlbumRef(
      inc.name.isEmpty ? cur.name : inc.name,
      browseId: inc.browseId ?? cur.browseId,
      kind: inc.kind,
      year: cur.year,
    );
  } else {
    merged = cur;
  }

  // Year arrives later than the rest (an extra album-page fetch): fill
  // it in even when the album reference itself was already resolved and
  // kept above.
  if (merged != null &&
      merged.year.trim().isEmpty &&
      inc != null &&
      inc.year.trim().isNotEmpty) {
    merged = AlbumRef(
      merged.name,
      browseId: merged.browseId,
      kind: merged.kind,
      year: inc.year,
    );
  }
  return merged;
}

List<Thumbnail> _mergeThumbnails(
  List<Thumbnail> current,
  List<Thumbnail> incoming,
  ThumbnailMerge policy,
) {
  switch (policy) {
    case ThumbnailMerge.keep:
      return current;
    case ThumbnailMerge.fillMissing:
      return current.isEmpty && incoming.isNotEmpty ? incoming : current;
    case ThumbnailMerge.union:
      if (incoming.isEmpty) return current;
      final seen = <String>{};
      final out = <Thumbnail>[];
      for (final thumb in [...current, ...incoming]) {
        if (seen.add(thumb.url)) out.add(thumb);
      }
      return out;
  }
}