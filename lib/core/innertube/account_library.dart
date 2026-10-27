// Account library over InnerTube: the account's playlists, liked
// songs, recent activity, followed artists, and the write operations
// (playlist create/rename/delete, add/remove track, subscribe).
//
// Everything here rides the signed-in InnerTube session (cookie +
// SAPISIDHASH), so no second credential is needed anywhere in the app.

import '../models/models.dart';
import 'inner_tube.dart';

/// Read/write access to the signed-in account's library.
///
/// The methods are overridable so tests can stub the library without
/// touching the network.
class AccountLibrary {
  AccountLibrary({this.tube});

  /// The InnerTube client carrying the signed-in session. Null in
  /// test doubles that override every method they use.
  final InnerTube? tube;

  InnerTube get _tube {
    final t = tube;
    if (t == null) {
      throw StateError('AccountLibrary has no InnerTube client');
    }
    return t;
  }

  /// The account's own playlists.
  Future<List<AccountPlaylist>> playlists() => _tube.libraryPlaylists();

  /// Recently played tracks (the watch history).
  Future<List<Track>> recentActivity({int max = 30}) async {
    final snapshot = await _tube.historySnapshot(maxItems: max);
    return snapshot.tracks;
  }

  /// Channels the account follows.
  Future<List<BrowseItem>> subscriptions({int max = 50}) =>
      _tube.libraryArtists(max: max);

  /// The account's liked songs — YouTube's "Liked Music" playlist,
  /// newest like first.
  Future<List<Track>> likedVideos({int max = 2000}) =>
      _tube.likedVideos(max: max);

  /// The song count YouTube reports for the liked-music playlist.
  ///
  /// The playlist's header counts every entry ("524 songs") while its
  /// shelf only renders the ones it can show, so the count and the
  /// number of listed rows differ — as they do in YouTube Music
  /// itself. Null until the playlist was read.
  int? get likedCount => tube?.likedCount;

  /// The ids of the account's liked songs.
  Future<Set<String>> likedVideoIds({int max = 2000}) async {
    final tracks = await likedVideos(max: max);
    return {for (final t in tracks) t.videoId};
  }

  /// Tracks of one playlist, in playlist order.
  Future<List<Track>> playlistTracks(String playlistId, {int max = 5000}) =>
      _tube.playlistTracks(playlistId, max: max);

  /// The playlist-item id of [videoId] inside [playlistId], or null
  /// when the playlist does not hold the track.
  Future<String?> playlistItemId(String playlistId, String videoId) =>
      _tube.playlistItemId(playlistId, videoId);

  /// Removes a track from a playlist. [setVideoId] comes from
  /// [playlistItemId]; without it the row cannot be addressed.
  Future<bool> removeFromPlaylist(
    String playlistId,
    String videoId,
    String setVideoId,
  ) => _tube.removeFromPlaylist(playlistId, videoId, setVideoId);

  /// Adds a track to a playlist.
  Future<bool> addToPlaylist(String playlistId, String videoId) =>
      _tube.addToPlaylist(playlistId, videoId);

  /// Creates a playlist and returns its id.
  Future<String?> createPlaylist(String title) => _tube.createPlaylist(title);

  /// Renames a playlist.
  Future<bool> renamePlaylist(String playlistId, String title) =>
      _tube.renamePlaylist(playlistId, title);

  /// Deletes a playlist.
  Future<bool> deletePlaylist(String playlistId) =>
      _tube.deletePlaylist(playlistId);

  /// Square avatars of the given channels, keyed by channel id.
  Future<Map<String, String>> channelAvatars(List<String> ids) =>
      _tube.channelAvatars(ids);

  /// The signed-in account's own avatar.
  Future<String?> accountAvatar() => _tube.accountAvatar();

  /// The signed-in account's channel id.
  Future<String?> ownChannelId() => _tube.ownChannelId();

  /// Whether the account subscribes to [channelId].
  Future<bool> isSubscribed(String channelId) => _tube.isSubscribed(channelId);

  /// Subscribes to a channel.
  Future<bool> subscribe(String channelId) => _tube.subscribeTo(channelId);

  /// Unsubscribes from a channel.
  Future<bool> unsubscribe(String channelId) =>
      _tube.unsubscribeFrom(channelId);

  /// Public like count of a video.
  Future<int?> videoLikeCount(String videoId) => _tube.videoLikeCount(videoId);
}
