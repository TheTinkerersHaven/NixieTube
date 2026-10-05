// GDataApi tests with scripted responses: paging, fixup wiring,
// region filtering, auth degradation, and mutations.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nixietube/core/innertube/gdata_api.dart';

http.Response _ok(Object json) =>
    http.Response(jsonEncode(json), 200);

void main() {
  group('playlists', () {
    test('pages through results and drops LL ids', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        final page = req.url.queryParameters['pageToken'];
        if (page == null) {
          return _ok({
            'items': [
              {
                'id': 'PL1',
                'snippet': {
                  'title': 'Mix',
                  'channelTitle': 'Me',
                  'channelId': 'UCme',
                  'thumbnails': {
                    'medium': {'url': 'https://x/p1.jpg'}
                  },
                },
                'contentDetails': {'itemCount': 10},
              },
              {
                'id': 'LLliked',
                'snippet': {'title': 'Liked'},
                'contentDetails': {'itemCount': 5},
              },
            ],
            'nextPageToken': 'p2',
          });
        }
        return _ok({
          'items': [
            {
              'id': 'PL2',
              'snippet': {'title': 'Empty', 'channelTitle': 'Me'},
              'contentDetails': {'itemCount': 0},
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      // keepMusicPlaylists probes item videos; stub the probe to fail so
      // unclassifiable playlists stay visible.
      final pls = await api.playlists();
      expect(calls, greaterThanOrEqualTo(2));
      expect(pls.map((p) => p.id), containsAll(['PL1', 'PL2']));
      expect(pls.map((p) => p.id), isNot(contains('LLliked')));
      expect(pls.firstWhere((p) => p.id == 'PL1').art,
          'https://x/p1.jpg');
      api.close();
    });

    test('signed out degrades to empty', () async {
      final api = GDataApi(tokenProvider: () async => null);
      expect(await api.playlists(), isEmpty);
      expect(await api.likedVideos(), isEmpty);
      expect(await api.subscriptions(), isEmpty);
      expect(await api.channelAvatar(), isNull);
      expect(await api.rate('v', true), isFalse);
      api.close();
    });
  });

  group('playlistTracks', () {
    test('skips deleted stubs and fixes up artists', () async {
      final client = MockClient((req) async {
        return _ok({
          'items': [
            {
              'snippet': {
                'resourceId': {'videoId': 'UCBR8-60-B28hp2BmDPdntcQ'},
                'title': 'Deleted',
              },
            },
            {
              'snippet': {
                'resourceId': {'videoId': 'V9'},
                'title': 'Singer - Hit Song',
                'videoOwnerChannelTitle': 'Uploader',
                'thumbnails': {
                  'default': {'url': 'https://x/t.jpg'}
                },
              },
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      final tracks = await api.playlistTracks('PL1');
      expect(tracks.length, 1);
      expect(tracks.first.videoId, 'V9');
      expect(tracks.first.title, 'Hit Song');
      expect(tracks.first.artistNames(), 'Singer');
      api.close();
    });

    test('stamps durations from a batch videos lookup', () async {
      final client = MockClient((req) async {
        // The batch duration lookup: playlistItems carries
        // none, videos/contentDetails carries ISO durations.
        if (req.url.path == '/youtube/v3/videos') {
          return _ok({
            'items': [
              {
                'id': 'V1',
                'contentDetails': {'duration': 'PT3M30S'},
              },
              {
                'id': 'V2',
                'contentDetails': {'duration': 'PT1M5S'},
              },
            ],
          });
        }
        return _ok({
          'items': [
            {
              'snippet': {
                'resourceId': {'videoId': 'V1'},
                'title': 'Artist - First',
              },
            },
            {
              'snippet': {
                'resourceId': {'videoId': 'V2'},
                'title': 'Artist - Second',
              },
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      final tracks = await api.playlistTracks('PL1');
      expect(tracks.length, 2);
      expect(tracks.first.durationSec, 210);
      expect(tracks[1].durationSec, 65);
      api.close();
    });

    test('survives a failed duration lookup', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/youtube/v3/videos') {
          return http.Response('quota exceeded', 403);
        }
        return _ok({
          'items': [
            {
              'snippet': {
                'resourceId': {'videoId': 'V1'},
                'title': 'Artist - First',
              },
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      final tracks = await api.playlistTracks('PL1');
      expect(tracks.length, 1);
      // Durations stay 0 rather than failing the playlist.
      expect(tracks.first.durationSec, 0);
      api.close();
    });
  });

  group('likedVideos', () {
    test('keeps music, drops vlogs', () async {
      final client = MockClient((req) async {
        return _ok({
          'items': [
            {
              'id': 'M1',
              'snippet': {
                'title': 'Song One',
                'channelTitle': 'Band - Topic',
                'categoryId': '10',
                'thumbnails': {
                  'default': {'url': 'https://x/m1.jpg'}
                },
              },
              'contentDetails': {'duration': 'PT3M00S'},
              'topicDetails': <String, dynamic>{},
            },
            {
              'id': 'V1',
              'snippet': {
                'title': 'Daily Vlog #42',
                'channelTitle': 'Vlogger',
              },
              'contentDetails': <String, dynamic>{},
              'topicDetails': {
                'relevantTopicIds': ['/m/02jjt'],
              },
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      final liked = await api.likedVideos();
      expect(liked.length, 1);
      expect(liked.first.videoId, 'M1');
      expect(liked.first.durationSec, 180);
      api.close();
    });
  });

  group('recentActivity', () {
    test('backfills owners from videos.list', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/activities')) {
          return _ok({
            'items': [
              {
                'snippet': {
                  'type': 'like',
                  'title': 'Old Title',
                  'channelTitle': 'Me',
                },
                'contentDetails': {
                  'like': {
                    'resourceId': {'videoId': 'A1'}
                  },
                },
              },
              {
                'snippet': {'type': 'subscription'},
                'contentDetails': <String, dynamic>{},
              },
            ],
          });
        }
        return _ok({
          'items': [
            {
              'id': 'A1',
              'snippet': {
                'channelTitle': 'Real Artist',
                'channelId': 'UCART',
              },
              'contentDetails': {'duration': 'PT2M30S'},
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      final act = await api.recentActivity();
      expect(act.length, 1);
      expect(act.first.videoId, 'A1');
      expect(act.first.artistNames(), 'Real Artist');
      expect(act.first.artistId, 'UCART');
      expect(act.first.durationSec, 150);
      api.close();
    });
  });

  group('mutations', () {
    test('mutations report transport success', () async {
      final client = MockClient((req) async {
        return http.Response('', 200);
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      expect(await api.rate('V1', true), isTrue);
      expect(await api.addToPlaylist('PL1', 'V1'), isTrue);
      expect(await api.subscribe('UC1'), isTrue);
      expect(await api.removePlaylistItem('ITEM1'), isTrue);
      expect(await api.unsubscribe('SUB1'), isTrue);
      api.close();
    });

    test('playlistItemId pages until found', () async {
      final client = MockClient((req) async {
        final page = req.url.queryParameters['pageToken'];
        if (page == null) {
          return _ok({
            'items': [
              {
                'id': 'ITEM-no',
                'snippet': {
                  'resourceId': {'videoId': 'OTHER'}
                },
              },
            ],
            'nextPageToken': 'p2',
          });
        }
        return _ok({
          'items': [
            {
              'id': 'ITEM-yes',
              'snippet': {
                'resourceId': {'videoId': 'WANT'}
              },
            },
          ],
        });
      });
      final api = GDataApi(
          tokenProvider: () async => 'tok', httpClient: client);
      expect(await api.playlistItemId('PL1', 'WANT'), 'ITEM-yes');
      expect(await api.playlistItemId('PL1', 'MISSING'), isNull);
      api.close();
    });
  });
}
