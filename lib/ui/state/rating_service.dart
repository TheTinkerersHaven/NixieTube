// Rating state for the NixieTube app.
//
// Owns the local rating cache, the liked-id set and the stamping of
// known like-state onto tracks, shelves and search sections.

import '../../core/models/models.dart';

/// Reports whether [videoId] belongs to the signed-in liked tracks.
typedef LikesTrack = bool Function(String videoId);

/// Local rating state: the rating cache, the liked ids and the
/// stamping helpers that paint known like-state onto rows.
class RatingService {
  /// Creates a rating service. [likesTrack] reports whether a video is
  /// part of the signed-in liked tracks.
  RatingService({required this.likesTrack});

  /// Reports whether a video belongs to the signed-in liked tracks.
  final LikesTrack likesTrack;
  final Map<String, RatingStatus> _ratingCache = {};
  Set<String> _likedIds = {};

  /// The like-status of [videoId] from the liked ids and liked tracks,
  /// or null when the video is not known as liked.
  RatingStatus? likedStatus(String videoId) {
    if (_likedIds.contains(videoId) || likesTrack(videoId)) {
      return RatingStatus.like;
    }
    return null;
  }

  /// The known rating for [videoId]: the cache wins over the liked
  /// state, or null when nothing is known.
  RatingStatus? knownRating(String videoId) =>
      _ratingCache[videoId] ?? likedStatus(videoId);

  /// The cached rating for [videoId], or null when not cached.
  RatingStatus? cachedRating(String videoId) => _ratingCache[videoId];

  /// Records the rating for [videoId] in the cache.
  void setCachedRating(String videoId, RatingStatus rating) {
    _ratingCache[videoId] = rating;
  }

  /// Records a batch of ratings in the cache.
  void setCachedRatings(Map<String, RatingStatus> ratings) {
    _ratingCache.addAll(ratings);
  }

  /// Empties the rating cache.
  void clearCachedRatings() {
    _ratingCache.clear();
  }

  /// The known liked ids.
  Set<String> get likedIds => _likedIds;

  /// Replaces the known liked ids.
  void setLikedIds(Set<String> ids) {
    _likedIds = ids;
  }

  /// Adds [videoId] to the known liked ids.
  void addLikedId(String videoId) {
    _likedIds.add(videoId);
  }

  /// Removes [videoId] from the known liked ids.
  void removeLikedId(String videoId) {
    _likedIds.remove(videoId);
  }

  /// Whether [videoId] is known as liked.
  bool isLiked(String videoId) => likedStatus(videoId) == RatingStatus.like;

  /// Whether a network-fetched rating may be applied.
  ///
  /// Logged-out InnerTube reads confidently report INDIFFERENT for liked
  /// songs; those must never clobber locally known LIKE state. Explicit
  /// LIKE/DISLIKE always applies (it requires a real session).
  bool trustNetworkRating(String videoId, RatingStatus fetched) {
    if (fetched == RatingStatus.like || fetched == RatingStatus.dislike) {
      return true;
    }
    if (fetched != RatingStatus.indifferent) return false;
    return knownRating(videoId) != RatingStatus.like;
  }

  /// Applies locally known like-state onto [track].
  ///
  /// Explicit cache entries always win, so unlikes/relikes repaint
  /// correctly even when the track object predates them.
  Track stampKnownRating(Track track) {
    final known = knownRating(track.videoId);
    if (known == null || known == track.rating) return track;
    return track.copyWith(rating: known);
  }

  /// Maps [stampKnownRating] over a track list.
  List<Track> stampKnownRatings(List<Track> tracks) =>
      tracks.map(stampKnownRating).toList();

  /// Maps [stampKnownRating] over the song items of every shelf.
  List<Shelf> stampShelves(List<Shelf> shelves) => [
    for (final shelf in shelves)
      Shelf(shelf.title, [
        for (final item in shelf.items)
          item is SongItem ? SongItem(stampKnownRating(item.track)) : item,
      ], continuation: shelf.continuation),
  ];

  /// Maps [stampKnownRating] over the song items of search sections.
  Map<String, List<ShelfItem>> stampSearchSections(
    Map<String, List<ShelfItem>> sections,
  ) {
    return sections.map(
      (key, items) => MapEntry(
        key,
        items
            .map(
              (item) => item is SongItem
                  ? SongItem(stampKnownRating(item.track))
                  : item,
            )
            .toList(),
      ),
    );
  }
}
