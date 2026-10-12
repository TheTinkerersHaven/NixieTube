// Account-flavored features via the official YouTube Data API v3, which
// accepts standard OAuth tokens (unlike InnerTube from this environment).
// Playback of the resulting items still resolves through anonymous
// InnerTube. Ported from Kotlin `GDataApi`.
//
// Every endpoint degrades to an empty/default value on transport or auth
// failure, mirroring the Kotlin try/catch-everything style.

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../sys/http_client.dart';
import '../models/models.dart';
import 'json.dart';
import 'metadata.dart';

/// A YouTube playlist from the signed-in account's library.
class GPlaylist {
  const GPlaylist({
    required this.id,
    required this.title,
    required this.itemCount,
    this.art,
    this.arts = const [],
    this.owner = '',
    this.ownerId = '',
  });

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

class _Pending {
  _Pending(this.videoId, this.title, this.art);
  final String videoId;
  final String title;
  final String? art;
}

class _VideoMeta {
  _VideoMeta(this.owner, this.channelId, this.duration, this.tags);
  final String owner;
  final String channelId;
  final int duration;
  final List<String> tags;
}

/// Account Data API v3 client over an OAuth token provider.
class GDataApi {
  GDataApi({required Future<String?> Function() tokenProvider, Dio? dio})
    : _dio = dio ?? newHttpClient() {
    _tokenProvider = tokenProvider;
  }

  late final Future<String?> Function() _tokenProvider;
  final Dio _dio;

  /// Every Data API call fails fast instead of hanging on a stalled token
  /// refresh or transport (a hung request would otherwise spin the
  /// add-to-playlist dialog forever).
  static const _gdataTimeout = Duration(seconds: 20);

  /// Releases the HTTP client.
  void close() => _dio.close();

  /// True for 2xx statuses. Dio's status is nullable; a missing
  /// status counts as a failure.
  static bool _okStatus(int? status) =>
      status != null && status >= 200 && status < 300;

  /// Returns the current OAuth token or throws when signed out.
  Future<String> _token() async {
    final token = await _tokenProvider().timeout(_gdataTimeout);
    if (token == null) throw StateError('not signed in');
    return token;
  }

  Future<dynamic> _get(String path, Map<String, String> params) async {
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/$path', params);
    final res = await _dio
        .getUri<String>(
          uri,
          options: Options(
            headers: {'Authorization': 'Bearer ${await _token()}'},
          ),
        )
        .timeout(_gdataTimeout);
    return decodeJsonResponse(res.data ?? '');
  }

  /// Playlist/video thumbnails come in varying sizes; take the best available.
  String? _thumbOf(Map? parent) {
    final thumbs = parent?['thumbnails'];
    if (thumbs is! Map) return null;
    for (final size in ['high', 'medium', 'standard', 'default', 'maxres']) {
      final sizeObj = thumbs[size];
      if (sizeObj is Map) {
        final url = sizeObj['url'];
        if (url is String) return url;
      }
    }
    return null;
  }

  List<String> _tagsOf(Map snippet) {
    final tags = snippet['tags'];
    if (tags is! List) return [];
    return tags.whereType<String>().where((t) => t.trim().isNotEmpty).toList();
  }

  List<dynamic> _itemsOf(dynamic res) {
    if (res is Map) {
      final items = res['items'];
      if (items is List) return items;
    }
    return [];
  }

  String? _nextPage(dynamic res) {
    if (res is Map) {
      final token = res['nextPageToken'];
      if (token is String && token.isNotEmpty) return token;
    }
    return null;
  }

  /// Signed-in channel avatar URL, preferring the medium thumbnail.
  Future<String?> channelAvatar() async {
    try {
      final res = await _get('channels', {'part': 'snippet', 'mine': 'true'});
      final items = _itemsOf(res);
      if (items.isEmpty || items.first is! Map) return null;
      final sn = (items.first as Map)['snippet'];
      if (sn is! Map) return null;
      final thumbs = sn['thumbnails'];
      if (thumbs is Map) {
        for (final size in ['medium', 'default']) {
          final sizeObj = thumbs[size];
          if (sizeObj is Map) {
            final url = sizeObj['url'];
            if (url is String && url.isNotEmpty) return url;
          }
        }
      }
      return _thumbOf(sn);
    } catch (_) {
      return null;
    }
  }

  /// Signed-in channel display name.
  Future<String?> channelName() async {
    try {
      final res = await _get('channels', {'part': 'snippet', 'mine': 'true'});
      final items = _itemsOf(res);
      if (items.isEmpty || items.first is! Map) return null;
      final sn = (items.first as Map)['snippet'];
      if (sn is! Map) return null;
      final title = sn['title'];
      if (title is String && title.isNotEmpty) return title;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Signed-in channel id (never link to yourself).
  Future<String?> ownChannelId() async {
    try {
      final res = await _get('channels', {'part': 'id', 'mine': 'true'});
      final items = _itemsOf(res);
      if (items.isEmpty || items.first is! Map) return null;
      final id = (items.first as Map)['id'];
      if (id is String && id.trim().isNotEmpty) return id;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Account music playlists (likes + non-music lists excluded).
  Future<List<GPlaylist>> playlists() async {
    final out = <GPlaylist>[];
    String? pageToken;
    try {
      do {
        final params = {
          'part': 'snippet,contentDetails',
          'mine': 'true',
          'maxResults': '50',
        };
        if (pageToken != null) params['pageToken'] = pageToken;
        final res = await _get('playlists', params);
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final sn = item['snippet'];
          final cd = item['contentDetails'];
          out.add(
            GPlaylist(
              id: _str(item['id']) ?? '',
              title: sn is Map ? (_str(sn['title']) ?? '') : '',
              itemCount: cd is Map
                  ? (cd['itemCount'] is int ? cd['itemCount'] as int : 0)
                  : 0,
              art: sn is Map ? _thumbOf(sn) : null,
              owner: sn is Map ? (_str(sn['channelTitle']) ?? '') : '',
              ownerId: sn is Map ? (_str(sn['channelId']) ?? '') : '',
            ),
          );
        }
        pageToken = _nextPage(res);
      } while (pageToken != null);
    } catch (_) {}
    return _keepMusicPlaylists(
      out.where((pl) => !pl.id.startsWith('LL')).toList(),
    );
  }

  /// Creates a playlist and returns its id, or null on failure. New
  /// playlists default to private (unlisted-public surfaces are unusual for
  /// a local player).
  Future<String?> createPlaylist({
    required String title,
    String description = '',
    String privacy = 'private',
  }) async {
    try {
      final res = await _dio
          .postUri<String>(
            Uri.https('www.googleapis.com', '/youtube/v3/playlists', {
              'part': 'snippet,status',
            }),
            data: jsonEncode({
              'snippet': {'title': title, 'description': description},
              'status': {'privacyStatus': privacy},
            }),
            options: Options(
              headers: {
                'Authorization': 'Bearer ${await _token()}',
                'Content-Type': 'application/json',
              },
            ),
          )
          .timeout(_gdataTimeout);
      final data = await decodeJsonResponse(res.data ?? '');
      final id = data is Map ? data['id'] : null;
      return id is String ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// First classifiable video id in a playlist (probe for keep-music).
  Future<String?> _firstPlaylistVideo(GPlaylist pl) async {
    if (pl.itemCount == 0) return null;
    final res = await _get('playlistItems', {
      'part': 'snippet,contentDetails',
      'playlistId': pl.id,
      'maxResults': '3',
    });
    for (final item in _itemsOf(res)) {
      if (item is! Map) continue;
      final cd = item['contentDetails'];
      if (cd is Map) {
        final vid = _str(cd['videoId']);
        if (vid != null && vid.isNotEmpty && vid != deletedVideoId) {
          return vid;
        }
      }
    }
    return null;
  }

  /// Drops non-music playlists (plain video collections) via topic
  /// probing; unclassifiable (empty/private) stay visible.
  Future<List<GPlaylist>> _keepMusicPlaylists(List<GPlaylist> all) async {
    if (all.isEmpty) return all;
    try {
      final firstIds = <String, String>{};
      for (final pl in all) {
        final vid = await _firstPlaylistVideo(pl);
        if (vid != null) firstIds[pl.id] = vid;
      }
      if (firstIds.isEmpty) return all;
      final musical = <String>{};
      final vids = firstIds.values.toList();
      for (var i = 0; i < vids.length; i += 50) {
        final end = (i + 50 < vids.length) ? i + 50 : vids.length;
        final res = await _get('videos', {
          'part': 'topicDetails',
          'id': vids.sublist(i, end).join(','),
        });
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final id = _str(item['id']);
          if (id == null) continue;
          if (_hasMusicTopics(item)) musical.add(id);
        }
      }
      final musicalPlaylists = firstIds.entries
          .where((e) => musical.contains(e.value))
          .map((e) => e.key)
          .toSet();
      final unknown = all
          .where((pl) => !firstIds.containsKey(pl.id))
          .map((pl) => pl.id)
          .toSet();
      return all
          .where(
            (pl) => musicalPlaylists.contains(pl.id) || unknown.contains(pl.id),
          )
          .toList();
    } catch (_) {
      return all;
    }
  }

  bool _hasMusicTopics(Map item) {
    final details = item['topicDetails'];
    if (details is! Map) return false;
    final ids =
        (details['relevantTopicIds'] as List?)?.whereType<String>() ?? [];
    if (ids.contains(musicTopicId)) return true;
    final cats =
        (details['topicCategories'] as List?)?.whereType<String>() ?? [];
    return cats.any((c) => c.toLowerCase().contains('music'));
  }

  /// Playlist tracks with fixed-up artist/title metadata, in order.
  ///
  /// The `playlistItems` payload carries no duration, so a batch
  /// `videos` lookup stamps [Track.durationSec] afterwards — the
  /// duration column and the duration sort depend on it.
  Future<List<Track>> playlistTracks(
    String playlistId, {
    int max = 5000,
  }) async {
    final out = <Track>[];
    String? pageToken;
    try {
      while (out.length < max) {
        final params = {
          'part': 'snippet,contentDetails',
          'playlistId': playlistId,
          'maxResults': '50',
        };
        if (pageToken != null) params['pageToken'] = pageToken;
        final res = await _get('playlistItems', params);
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final sn = item['snippet'];
          if (sn is! Map) continue;
          final resourceId = sn['resourceId'];
          final videoId = resourceId is Map
              ? _str(resourceId['videoId'])
              : null;
          if (videoId == null) continue;
          if (videoId == deletedVideoId) continue;
          final rawTitle = _str(sn['title']) ?? 'Unknown';
          final rawOwner = _str(sn['videoOwnerChannelTitle']) ?? '';
          final tags = _tagsOf(sn);
          final fixed = fixup(rawTitle, rawOwner, tags);
          final album = albumFromTags(rawTitle, fixed.artist, rawOwner, tags);
          out.add(
            Track(
              videoId: videoId,
              title: fixed.title,
              artists: fixed.artist.trim().isNotEmpty
                  ? [ArtistRef(fixed.artist)]
                  : const [],
              album: album == null
                  ? null
                  : AlbumRef(
                      album,
                      kind: albumKindFromTags(rawTitle, album, rawOwner, tags),
                    ),
              thumbnails: _thumbOf(sn) == null
                  ? const []
                  : [Thumbnail(_thumbOf(sn)!)],
            ),
          );
        }
        pageToken = _nextPage(res);
        if (pageToken == null) break;
      }
    } catch (_) {}
    final capped = out.length <= max ? out : out.sublist(0, max);
    await _stampDurations(capped);
    return capped;
  }

  /// Fills in [Track.durationSec] for [tracks] in place, one
  /// `videos` request per 50 ids (the Data API batch limit).
  /// Failures leave the affected durations at 0.
  Future<void> _stampDurations(List<Track> tracks) async {
    for (var i = 0; i < tracks.length; i += 50) {
      final end = (i + 50 < tracks.length) ? i + 50 : tracks.length;
      final ids = tracks.sublist(i, end).map((t) => t.videoId).join(',');
      try {
        final res = await _get('videos', {'part': 'contentDetails', 'id': ids});
        final byId = <String, int>{};
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final id = _str(item['id']);
          final cd = item['contentDetails'];
          if (id == null || cd is! Map) continue;
          final dur = isoDuration(_str(cd['duration']));
          if (dur > 0) byId[id] = dur;
        }
        if (byId.isEmpty) continue;
        for (var j = 0; j < end - i; j++) {
          final dur = byId[tracks[i + j].videoId];
          if (dur != null) {
            tracks[i + j] = tracks[i + j].copyWith(durationSec: dur);
          }
        }
      } catch (_) {}
    }
  }

  /// Recent liked/uploaded/favorited videos with real owners backfilled
  /// (snippet owners here are the actor — you — so videos.list fills in).
  ///
  /// Single page like Kotlin; the [max] cap applies to collection the same
  /// (non-functional past the page size) way.
  Future<List<Track>> recentActivity({int max = 30}) async {
    final ids = <_Pending>[];
    try {
      final res = await _get('activities', {
        'part': 'snippet,contentDetails',
        'mine': 'true',
        'maxResults': '50',
      });
      for (final item in _itemsOf(res)) {
        if (item is! Map) continue;
        final sn = item['snippet'];
        if (sn is! Map) continue;
        if (_str(sn['type']) == 'subscription') continue;
        final cd = item['contentDetails'];
        if (cd is! Map) continue;
        Map? detail;
        for (final k in [
          'like',
          'favorite',
          'upload',
          'playlistItem',
          'recommendation',
        ]) {
          if (cd[k] is Map) {
            detail = cd[k] as Map;
            break;
          }
        }
        if (detail == null) continue;
        final resourceId = detail['resourceId'];
        final videoId = resourceId is Map ? _str(resourceId['videoId']) : null;
        if (videoId == null || videoId.isEmpty) continue;
        final title = _str(sn['title']) ?? 'Unknown';
        ids.add(_Pending(videoId, title, _thumbOf(sn)));
        if (ids.length >= max) continue;
      }
    } catch (_) {
      return [];
    }
    if (ids.isEmpty) return [];
    // Batch-resolve real owners, channel ids, durations, tags.
    final owners = <String, _VideoMeta>{};
    try {
      for (var i = 0; i < ids.length; i += 50) {
        final end = (i + 50 < ids.length) ? i + 50 : ids.length;
        final chunk = ids.sublist(i, end).map((e) => e.videoId).join(',');
        final res = await _get('videos', {
          'part': 'snippet,contentDetails',
          'id': chunk,
        });
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final id = _str(item['id']);
          if (id == null) continue;
          final sn2 = item['snippet'];
          if (sn2 is! Map) continue;
          final owner = _str(sn2['channelTitle']);
          if (owner == null || owner.trim().isEmpty) continue;
          final channelId = _str(sn2['channelId']) ?? '';
          final cd = item['contentDetails'];
          final dur = cd is Map ? isoDuration(_str(cd['duration'])) : 0;
          owners[id] = _VideoMeta(owner, channelId, dur, _tagsOf(sn2));
        }
      }
    } catch (_) {}
    return ids.map((pending) {
      final meta = owners[pending.videoId];
      final owner = meta?.owner ?? '';
      final tags = meta?.tags ?? const <String>[];
      final fixed = fixup(pending.title, owner, tags);
      final album = albumFromTags(pending.title, fixed.artist, owner, tags);
      final channelId = meta?.channelId ?? '';
      return Track(
        videoId: pending.videoId,
        title: fixed.title,
        artists: fixed.artist.trim().isNotEmpty
            ? [ArtistRef(fixed.artist)]
            : const [],
        album: album == null
            ? null
            : AlbumRef(
                album,
                kind: albumKindFromTags(pending.title, album, owner, tags),
              ),
        thumbnails: pending.art == null ? const [] : [Thumbnail(pending.art!)],
        artistId: (channelId.trim().isNotEmpty && !isGenericReleaseOwner(owner))
            ? channelId
            : null,
        durationSec: meta?.duration ?? 0,
      );
    }).toList();
  }

  /// Subscribed channels as music artist entries (browseId = channel id).
  Future<List<ShelfItem>> subscriptions({int max = 50}) async {
    final out = <BrowseItem>[];
    String? pageToken;
    try {
      while (out.length < max) {
        final params = {
          'part': 'snippet',
          'mine': 'true',
          'maxResults': '50',
          'order': 'alphabetical',
        };
        if (pageToken != null) params['pageToken'] = pageToken;
        final res = await _get('subscriptions', params);
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final sn = item['snippet'];
          if (sn is! Map) continue;
          final resourceId = sn['resourceId'];
          final channelId = resourceId is Map
              ? _str(resourceId['channelId'])
              : null;
          if (channelId == null || channelId.isEmpty) continue;
          out.add(
            BrowseItem(
              title: _str(sn['title']) ?? 'Unknown',
              subtitle: 'Artist',
              browseId: channelId,
              thumbnails: _thumbOf(sn) == null
                  ? const []
                  : [Thumbnail(_thumbOf(sn)!)],
            ),
          );
        }
        pageToken = _nextPage(res);
        if (pageToken == null) break;
      }
    } catch (_) {}
    final taken = out.length <= max ? out : out.sublist(0, max);
    return _keepMusicChannels(taken);
  }

  /// Drops non-music channels via one batched topicDetails lookup each.
  /// Unclassifiable channels stay visible.
  Future<List<ShelfItem>> _keepMusicChannels(List<BrowseItem> all) async {
    if (all.isEmpty) return all;
    try {
      final musical = <String>{};
      final unknown = <String>{};
      final ids = all.map((e) => e.browseId).toList();
      for (var i = 0; i < ids.length; i += 50) {
        final end = (i + 50 < ids.length) ? i + 50 : ids.length;
        final chunk = ids.sublist(i, end);
        final res = await _get('channels', {
          'part': 'topicDetails',
          'id': chunk.join(','),
        });
        final seen = <String>{};
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final id = _str(item['id']);
          if (id == null) continue;
          seen.add(id);
          if (_hasMusicTopics(item)) musical.add(id);
        }
        unknown.addAll(chunk.where((id) => !seen.contains(id)));
      }
      return all
          .where(
            (e) => musical.contains(e.browseId) || unknown.contains(e.browseId),
          )
          .toList();
    } catch (_) {
      return all;
    }
  }

  /// Liked videos classified as music with region filtering.
  Future<List<Track>> likedVideos({int max = 2000}) async {
    final region = systemRegion();
    final out = <Track>[];
    String? pageToken;
    try {
      while (out.length < max) {
        final params = {
          'part': 'snippet,contentDetails,topicDetails',
          'myRating': 'like',
          'maxResults': '50',
        };
        if (pageToken != null) params['pageToken'] = pageToken;
        final res = await _get('videos', params);
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final sn = item['snippet'];
          if (sn is! Map) continue;
          final videoId = _str(item['id']);
          if (videoId == null || videoId.isEmpty) continue;
          if (!keepTrack(item, region)) continue;
          final rawTitle = _str(sn['title']) ?? 'Unknown';
          final rawOwner = _str(sn['channelTitle']) ?? '';
          final tags = _tagsOf(sn);
          final fixed = fixup(rawTitle, rawOwner, tags);
          final album = albumFromTags(rawTitle, fixed.artist, rawOwner, tags);
          final cd = item['contentDetails'];
          out.add(
            Track(
              videoId: videoId,
              title: fixed.title,
              artists: fixed.artist.trim().isNotEmpty
                  ? [ArtistRef(fixed.artist)]
                  : const [],
              album: album == null
                  ? null
                  : AlbumRef(
                      album,
                      kind: albumKindFromTags(rawTitle, album, rawOwner, tags),
                    ),
              thumbnails: _thumbOf(sn) == null
                  ? const []
                  : [Thumbnail(_thumbOf(sn)!)],
              durationSec: cd is Map ? isoDuration(_str(cd['duration'])) : 0,
              rating: RatingStatus.like,
            ),
          );
        }
        pageToken = _nextPage(res);
        if (pageToken == null) break;
      }
    } catch (_) {}
    return out.length <= max ? out : out.sublist(0, max);
  }

  /// Every video id the account rated LIKE (no region filtering): marks
  /// like-state on surfaces that never run the ratings flow.
  Future<Set<String>> likedVideoIds({int max = 2000}) async {
    final out = <String>{};
    String? pageToken;
    try {
      while (out.length < max) {
        final params = {'part': 'id', 'myRating': 'like', 'maxResults': '50'};
        if (pageToken != null) params['pageToken'] = pageToken;
        final res = await _get('videos', params);
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final id = _str(item['id']);
          if (id != null && id.trim().isNotEmpty) out.add(id);
        }
        pageToken = _nextPage(res);
        if (pageToken == null) break;
      }
    } catch (_) {}
    return out;
  }

  /// Batch-resolves channel avatars (one call per 50 ids) for artist icons
  /// where InnerTube only exposes the wide header banner.
  Future<Map<String, String>> channelAvatars(List<String> ids) async {
    final out = <String, String>{};
    try {
      final seen = <String>{};
      final distinct = <String>[];
      for (final id in ids) {
        if (id.trim().isNotEmpty && seen.add(id)) distinct.add(id);
      }
      for (var i = 0; i < distinct.length; i += 50) {
        final end = (i + 50 < distinct.length) ? i + 50 : distinct.length;
        final res = await _get('channels', {
          'part': 'snippet',
          'id': distinct.sublist(i, end).join(','),
        });
        for (final item in _itemsOf(res)) {
          if (item is! Map) continue;
          final id = _str(item['id']);
          if (id == null) continue;
          final sn = item['snippet'];
          final art = sn is Map ? _thumbOf(sn) : null;
          if (art != null && art.trim().isNotEmpty) out[id] = art;
        }
      }
    } catch (_) {}
    return out;
  }

  /// Public like count for a single video via the statistics part.
  /// Null when unavailable (private/deleted video, quota error, ...).
  Future<int?> videoLikeCount(String videoId) async {
    if (videoId.trim().isEmpty) return null;
    try {
      final res = await _get('videos', {'part': 'statistics', 'id': videoId});
      for (final item in _itemsOf(res)) {
        if (item is! Map) continue;
        final stats = item['statistics'];
        if (stats is! Map) continue;
        final count = stats['likeCount'];
        if (count is int) return count;
        if (count is String) return int.tryParse(count);
      }
    } catch (_) {}
    return null;
  }

  /// Rates a video liked (`true`) or neutral (`false`).
  Future<bool> rate(String videoId, bool like) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/videos/rate', {
        'id': videoId,
        'rating': like ? 'like' : 'none',
      });
      final res = await _dio
          .postUri<String>(
            uri,
            options: Options(headers: {'Authorization': 'Bearer $token'}),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Appends a video to a playlist.
  Future<bool> addToPlaylist(String playlistId, String videoId) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/playlistItems', {
        'part': 'snippet',
      });
      final res = await _dio
          .postUri<String>(
            uri,
            data: jsonEncode({
              'snippet': {
                'playlistId': playlistId,
                'resourceId': {'kind': 'youtube#video', 'videoId': videoId},
              },
            }),
            options: Options(
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Finds the playlist-item id backing a video (removal needs the item
  /// id, not the video id), paging until found.
  Future<String?> playlistItemId(String playlistId, String videoId) async {
    String? pageToken;
    try {
      String? found;
      while (found == null) {
        final params = {
          'part': 'snippet',
          'playlistId': playlistId,
          'maxResults': '50',
        };
        if (pageToken != null) params['pageToken'] = pageToken;
        final res = await _get('playlistItems', params);
        if (res is Map) {
          for (final item in _itemsOf(res)) {
            if (item is! Map) continue;
            final sn = item['snippet'];
            final resourceId = sn is Map ? sn['resourceId'] : null;
            final vid = resourceId is Map ? _str(resourceId['videoId']) : null;
            if (vid == videoId) {
              found = _str(item['id']);
              break;
            }
          }
          if (found == null) {
            pageToken = _nextPage(res);
            if (pageToken == null) break;
          }
        } else {
          break;
        }
      }
      return found;
    } catch (_) {
      return null;
    }
  }

  /// Removes one playlist entry by playlist-item id.
  Future<bool> removePlaylistItem(String itemId) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/playlistItems', {
        'id': itemId,
      });
      final res = await _dio
          .deleteUri<String>(
            uri,
            options: Options(headers: {'Authorization': 'Bearer $token'}),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Renames a playlist. Only the snippet part is sent, so the playlist's
  /// privacy status is preserved.
  Future<bool> renamePlaylist(String playlistId, String newTitle) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/playlists', {
        'part': 'snippet',
      });
      final res = await _dio
          .putUri<String>(
            uri,
            data: jsonEncode({
              'id': playlistId,
              'snippet': {'title': newTitle},
            }),
            options: Options(
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Deletes a playlist.
  Future<bool> deletePlaylist(String playlistId) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/playlists', {
        'id': playlistId,
      });
      final res = await _dio
          .deleteUri<String>(
            uri,
            options: Options(headers: {'Authorization': 'Bearer $token'}),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Subscription id for a channel, or `null` when not subscribed.
  Future<String?> subscriptionId(String channelId) async {
    try {
      final res = await _get('subscriptions', {
        'part': 'id',
        'mine': 'true',
        'forChannelId': channelId,
      });
      final items = _itemsOf(res);
      if (items.isEmpty || items.first is! Map) return null;
      return _str((items.first as Map)['id']);
    } catch (_) {
      return null;
    }
  }

  /// Subscribes to a channel.
  Future<bool> subscribe(String channelId) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/subscriptions', {
        'part': 'snippet',
      });
      final res = await _dio
          .postUri<String>(
            uri,
            data: jsonEncode({
              'snippet': {
                'resourceId': {
                  'kind': 'youtube#channel',
                  'channelId': channelId,
                },
              },
            }),
            options: Options(
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }

  /// Removes a subscription.
  Future<bool> unsubscribe(String subscriptionId) async {
    try {
      final token = await _token();
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/subscriptions', {
        'id': subscriptionId,
      });
      final res = await _dio
          .deleteUri<String>(
            uri,
            options: Options(headers: {'Authorization': 'Bearer $token'}),
          )
          .timeout(_gdataTimeout);
      return _okStatus(res.statusCode);
    } catch (_) {
      return false;
    }
  }
}

String? _str(dynamic node) => node is String ? node : null;
