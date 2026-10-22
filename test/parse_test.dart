// Fixture tests for the InnerTube parsers: hand-built JSON shaped like
// real responses exercises list rows, panel videos, and shelves.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/parse.dart';
import 'package:nixietube/core/models/models.dart';

Map<String, dynamic> _run(String text, {String? videoId, String? browseId}) {
  final run = <String, dynamic>{'text': text};
  if (videoId != null) {
    run['navigationEndpoint'] = {
      'watchEndpoint': {'videoId': videoId},
    };
  }
  if (browseId != null) {
    run['navigationEndpoint'] = {
      'browseEndpoint': {'browseId': browseId},
    };
  }
  return run;
}

Map<String, dynamic> _col(List<Map<String, dynamic>> runs) {
  return {
    'musicResponsiveListItemFlexColumnRenderer': {
      'text': {'runs': runs},
    },
  };
}

void main() {
  group('parseListItem', () {
    test('linked artists, album, duration, views', () {
      final li = {
        'flexColumns': [
          _col([_run('Song Title', videoId: 'VID123')]),
          _col([
            _run('Artist Name', browseId: 'UCABC'),
            _run(' • '),
            _run('Album Name', browseId: 'MPRE123'),
            _run(' • '),
            _run('3:25'),
            _run(' • '),
            _run('1.2M views'),
          ]),
        ],
        'thumbnails': [
          {'url': 'https://x/a.jpg', 'width': 60, 'height': 60},
        ],
      };
      final t = parseListItem(li)!;
      expect(t.videoId, 'VID123');
      expect(t.title, 'Song Title');
      expect(t.artists.map((a) => a.name), ['Artist Name']);
      expect(t.artists.first.browseId, 'UCABC');
      expect(t.album!.name, 'Album Name');
      expect(t.album!.browseId, 'MPRE123');
      expect(t.durationSec, 205);
      expect(t.views, '1.2M views');
      expect(t.radioPlaylistId, 'RDAMVMVID123');
      expect(t.artistId, 'UCABC');
      expect(t.displayArtwork, 'https://x/a.jpg');
      expect(t.explicit, isFalse);
    });

    test('plain artist/album inference without endpoints', () {
      final li = {
        'flexColumns': [
          _col([_run('Track', videoId: 'V1')]),
          _col([_run('Lone Singer'), _run(' • '), _run('Great Record')]),
        ],
      };
      final t = parseListItem(li)!;
      expect(t.artists.map((a) => a.name), ['Lone Singer']);
      expect(t.album!.name, 'Great Record');
    });

    test('rows without a video id are dropped', () {
      final li = {
        'flexColumns': [
          _col([_run('No link here')]),
        ],
      };
      expect(parseListItem(li), isNull);
    });
  });

  group('parseRowDuration', () {
    test('reads the duration from the fixed column', () {
      final li = {
        'fixedColumns': [
          {
            'musicResponsiveListItemFixedColumnRenderer': {
              'text': {
                'runs': [_run('3:28')],
              },
            },
          },
        ],
      };
      expect(parseRowDuration(li), 208);
    });

    test('reads an hour-long duration', () {
      final li = {
        'fixedColumns': [
          {
            'musicResponsiveListItemFixedColumnRenderer': {
              'text': {
                'runs': [_run('1:02:11')],
              },
            },
          },
        ],
      };
      expect(parseRowDuration(li), 3731);
    });

    test('rows without a fixed column have no duration', () {
      expect(parseRowDuration({'flexColumns': []}), 0);
      expect(
        parseRowDuration({
          'fixedColumns': [
            {
              'musicResponsiveListItemFixedColumnRenderer': {
                'text': {
                  'runs': [_run('1.2M views')],
                },
              },
            },
          ],
        }),
        0,
      );
    });
  });

  group('parsePanelVideo', () {
    test('byline with linked artist and release', () {
      final item = {
        'title': {
          'runs': [_run('Panel Song')],
        },
        'navigationEndpoint': {
          'watchEndpoint': {'videoId': 'PV1'},
        },
        'longBylineText': {
          'runs': [
            _run('Panel Artist', browseId: 'UC999'),
            _run(' • '),
            _run('Panel Album', browseId: 'MPRE999'),
          ],
        },
        'lengthText': {
          'runs': [_run('4:01')],
        },
      };
      final t = parsePanelVideo(item)!;
      expect(t.videoId, 'PV1');
      expect(t.artists.map((a) => a.name), ['Panel Artist']);
      expect(t.album!.browseId, 'MPRE999');
      expect(t.durationSec, 241);
      expect(t.radioPlaylistId, 'RDAMVMPV1');
      expect(t.explicit, isFalse);
    });

    test('plain byline infers artist then album', () {
      final item = {
        'title': {
          'runs': [_run('Other Song')],
        },
        'navigationEndpoint': {
          'watchEndpoint': {'videoId': 'PV2'},
        },
        'shortBylineText': {
          'runs': [_run('Mystery Act'), _run(' • '), _run('Hidden Gem')],
        },
      };
      final t = parsePanelVideo(item)!;
      expect(t.artists.map((a) => a.name), ['Mystery Act']);
      expect(t.album!.name, 'Hidden Gem');
    });
  });

  group('parseExplicit', () {
    Map<String, dynamic> badge(String iconType) => {
      'musicInlineBadgeRenderer': {
        'icon': {'iconType': iconType},
        'accessibilityData': {
          'accessibilityData': {'label': 'Explicit'},
        },
      },
    };

    test('explicit badge reads true', () {
      expect(
        parseExplicit({
          'badges': [badge('MUSIC_EXPLICIT_BADGE')],
        }),
        isTrue,
      );
    });

    test('other badges read false', () {
      expect(
        parseExplicit({
          'badges': [badge('MUSIC_VERIFIED_BADGE')],
        }),
        isFalse,
      );
    });

    test('missing or malformed badges read false, never throw', () {
      expect(parseExplicit({}), isFalse);
      expect(parseExplicit({'badges': 'nope'}), isFalse);
      expect(
        parseExplicit({
          'badges': [{}],
        }),
        isFalse,
      );
      expect(
        parseExplicit({
          'badges': [
            {
              'musicInlineBadgeRenderer': {'icon': {}},
            },
          ],
        }),
        isFalse,
      );
      expect(parseExplicit(null), isFalse);
    });

    test('list rows carry the badge through', () {
      final li = {
        'flexColumns': [
          _col([_run('Bold Song', videoId: 'E1')]),
          _col([_run('Loud Act')]),
        ],
        'badges': [badge('MUSIC_EXPLICIT_BADGE')],
      };
      expect(parseListItem(li)!.explicit, isTrue);
    });

    test('panel rows carry the badge through', () {
      final item = {
        'title': {
          'runs': [_run('Queue Song')],
        },
        'navigationEndpoint': {
          'watchEndpoint': {'videoId': 'E2'},
        },
        'longBylineText': {
          'runs': [_run('Loud Act')],
        },
        'badges': [badge('MUSIC_EXPLICIT_BADGE')],
      };
      expect(parsePanelVideo(item)!.explicit, isTrue);
    });

    test('two-row cards carry the badge through', () {
      final el = {
        'musicTwoRowItemRenderer': {
          'title': {
            'runs': [_run('Card Song')],
          },
          'subtitle': {
            'runs': [_run('Loud Act')],
          },
          'navigationEndpoint': {
            'watchEndpoint': {'videoId': 'E3'},
          },
          'thumbnail': {
            'musicThumbnailRenderer': {
              'thumbnail': {
                'thumbnails': [
                  {'url': 'https://x/e.jpg', 'width': 60, 'height': 60},
                ],
              },
            },
          },
          'badges': [badge('MUSIC_EXPLICIT_BADGE')],
        },
      };
      final parsed = parseShelfItem(el);
      expect(parsed, isA<SongItem>());
      expect((parsed as SongItem).track.explicit, isTrue);
    });
  });

  group('parseShelf', () {
    test('carousel with song and browse rows', () {
      final shelf = {
        'musicCarouselShelfRenderer': {
          'header': {
            'musicCarouselShelfBasicHeaderRenderer': {
              'title': {
                'runs': [_run('Listen again')],
              },
            },
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Quick Song')],
                },
                'subtitle': {
                  'runs': [_run('Quick Artist')],
                },
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': 'Q1'},
                },
              },
            },
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Cool Album')],
                },
                'subtitle': {
                  'runs': [_run('Album • 2023')],
                },
                'navigationEndpoint': {
                  'browseEndpoint': {'browseId': 'MPRE1'},
                },
              },
            },
          ],
        },
      };
      final s = parseShelf(shelf)!;
      expect(s.title, 'Listen again');
      expect(s.items.length, 2);
      final song = s.items[0] as SongItem;
      expect(song.track.videoId, 'Q1');
      expect(song.track.title, 'Quick Song');
      final browse = s.items[1] as BrowseItem;
      expect(browse.browseId, 'MPRE1');
      expect(browse.title, 'Cool Album');
    });

    test('two-row song splits linked artist and album credits', () {
      final shelf = {
        'musicCarouselShelfRenderer': {
          'header': {
            'musicCarouselShelfBasicHeaderRenderer': {
              'title': {
                'runs': [_run('New music')],
              },
            },
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Linked Song')],
                },
                'subtitle': {
                  'runs': [
                    _run('Real Artist', browseId: 'UCART'),
                    _run(' • '),
                    _run('Real Album', browseId: 'MPREALB'),
                  ],
                },
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': 'V1'},
                },
              },
            },
          ],
        },
      };
      final s = parseShelf(shelf)!;
      final song = s.items.single as SongItem;
      // The artist must be just the artist, not "Real Artist • Real Album".
      expect(song.track.artists.map((a) => a.name), ['Real Artist']);
      expect(song.track.artists.single.browseId, 'UCART');
      expect(song.track.album!.name, 'Real Album');
      expect(song.track.album!.browseId, 'MPREALB');
    });

    test('two-row song falls back to the leading segment when unlinked', () {
      final shelf = {
        'musicCarouselShelfRenderer': {
          'header': {
            'musicCarouselShelfBasicHeaderRenderer': {
              'title': {
                'runs': [_run('Charts')],
              },
            },
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Plain Song')],
                },
                'subtitle': {
                  'runs': [_run('Plain Artist • Plain Album')],
                },
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': 'V2'},
                },
              },
            },
          ],
        },
      };
      final s = parseShelf(shelf)!;
      final song = s.items.single as SongItem;
      expect(song.track.artists.map((a) => a.name), ['Plain Artist']);
    });
  });

  group('buildPlaylist', () {
    test(
      'parses musicResponsiveHeaderRenderer with linked author and thumbnails',
      () {
        final res = {
          'contents': {
            'twoColumnBrowseResultsRenderer': {
              'tabs': [
                {
                  'tabRenderer': {
                    'content': {
                      'sectionListRenderer': {
                        'contents': [
                          {
                            'musicResponsiveHeaderRenderer': {
                              'title': {
                                'runs': [_run('My Awesome Playlist')],
                              },
                              'subtitle': {
                                'runs': [_run('Playlist description')],
                              },
                              'straplineTextOne': {
                                'runs': [
                                  _run('Cool Artist', browseId: 'UCARTIST123'),
                                ],
                              },
                              'thumbnail': {
                                'musicThumbnailRenderer': {
                                  'thumbnail': {
                                    'thumbnails': [
                                      {
                                        'url': 'https://img/pl_544.jpg',
                                        'width': 544,
                                        'height': 544,
                                      },
                                    ],
                                  },
                                },
                              },
                            },
                          },
                          {
                            'musicPlaylistShelfRenderer': {
                              'contents': [
                                {
                                  'musicResponsiveListItemRenderer': {
                                    'flexColumns': [
                                      _col([_run('Track 1', videoId: 'T1')]),
                                    ],
                                  },
                                },
                              ],
                            },
                          },
                        ],
                      },
                    },
                  },
                },
              ],
            },
          },
        };

        final pl = buildPlaylist(res)!;
        expect(pl.title, 'My Awesome Playlist');
        expect(pl.subtitle, 'Playlist description');
        expect(pl.thumbnails.length, 1);
        expect(pl.thumbnails.first.url, 'https://img/pl_544.jpg');
        expect(pl.author?.name, 'Cool Artist');
        expect(pl.author?.browseId, 'UCARTIST123');
        expect(pl.tracks.length, 1);
        expect(pl.tracks.first.videoId, 'T1');
      },
    );

    test('falls back to track thumbnail when header thumbnail is missing', () {
      final res = {
        'musicResponsiveHeaderRenderer': {
          'title': {
            'runs': [_run('Track Thumb Playlist')],
          },
        },
        'musicPlaylistShelfRenderer': {
          'contents': [
            {
              'musicResponsiveListItemRenderer': {
                'flexColumns': [
                  _col([_run('Song', videoId: 'S1')]),
                ],
                'thumbnail': {
                  'musicThumbnailRenderer': {
                    'thumbnail': {
                      'thumbnails': [
                        {
                          'url': 'https://img/track1.jpg',
                          'width': 120,
                          'height': 120,
                        },
                      ],
                    },
                  },
                },
              },
            },
          ],
        },
      };

      final pl = buildPlaylist(res)!;
      expect(pl.title, 'Track Thumb Playlist');
      expect(pl.thumbnails.length, 1);
      expect(pl.thumbnails.first.url, 'https://img/track1.jpg');
    });

    test('keeps the running time the row shows in its fixed column', () {
      final res = {
        'musicPlaylistShelfRenderer': {
          'contents': [
            {
              'musicResponsiveListItemRenderer': {
                'flexColumns': [
                  _col([_run('Song', videoId: 'S1')]),
                ],
                'fixedColumns': [
                  {
                    'musicResponsiveListItemFixedColumnRenderer': {
                      'text': {
                        'runs': [_run('3:45')],
                      },
                    },
                  },
                ],
              },
            },
          ],
        },
      };

      final pl = buildPlaylist(res)!;
      expect(pl.tracks.single.durationSec, 225);
    });
  });

  group('playlistArtworkThumbs', () {
    test('extracts thumbnails from musicResponsiveHeaderRenderer', () {
      final res = {
        'musicResponsiveHeaderRenderer': {
          'thumbnail': {
            'musicThumbnailRenderer': {
              'thumbnail': {
                'thumbnails': [
                  {'url': 'https://img/cover.jpg', 'width': 300, 'height': 300},
                ],
              },
            },
          },
        },
      };
      final thumbs = playlistArtworkThumbs(res);
      expect(thumbs.length, 1);
      expect(thumbs.first.url, 'https://img/cover.jpg');
    });

    test('falls back to track shelf thumbnail if header has none', () {
      final res = {
        'musicPlaylistShelfRenderer': {
          'contents': [
            {
              'musicResponsiveListItemRenderer': {
                'thumbnail': {
                  'musicThumbnailRenderer': {
                    'thumbnail': {
                      'thumbnails': [
                        {
                          'url': 'https://img/shelf_track.jpg',
                          'width': 200,
                          'height': 200,
                        },
                      ],
                    },
                  },
                },
              },
            },
          ],
        },
      };
      final thumbs = playlistArtworkThumbs(res);
      expect(thumbs.length, 1);
      expect(thumbs.first.url, 'https://img/shelf_track.jpg');
    });
  });

  group('parseLikeRating', () {
    Map<String, dynamic> toggleEntry(String? def, String? toggled) {
      return {
        'toggleMenuServiceItemRenderer': {
          'defaultServiceEndpoint': def == null
              ? null
              : {
                  'likeEndpoint': {'status': def},
                },
          'toggledServiceEndpoint': toggled == null
              ? null
              : {
                  'likeEndpoint': {'status': toggled},
                },
        },
      };
    }

    Map<String, dynamic> menuOf(List<Map<String, dynamic>> items) {
      return {
        'menu': {
          'menuRenderer': {'items': items},
        },
      };
    }

    test('unliked toggle reports indifferent, not like', () {
      // Live shape for an unliked song: the default endpoint names the
      // transition (LIKE) while the toggled endpoint names the state.
      final item = menuOf([toggleEntry('LIKE', 'INDIFFERENT')]);
      expect(parseLikeRating(item), RatingStatus.indifferent);
    });

    test('liked toggle reports like, not indifferent', () {
      final item = menuOf([toggleEntry('INDIFFERENT', 'LIKE')]);
      expect(parseLikeRating(item), RatingStatus.like);
    });

    test('skips toggles without a like endpoint', () {
      // Mirrors a liked panel row: library + like + pin toggles, where
      // only the middle one carries likeEndpoint statuses.
      final item = menuOf([
        toggleEntry(null, null),
        toggleEntry('INDIFFERENT', 'LIKE'),
        toggleEntry(null, null),
      ]);
      expect(parseLikeRating(item), RatingStatus.like);
    });

    test('dislike wins over an indifferent like-toggle', () {
      final item = menuOf([
        toggleEntry('LIKE', 'INDIFFERENT'),
        toggleEntry('INDIFFERENT', 'DISLIKE'),
      ]);
      expect(parseLikeRating(item), RatingStatus.dislike);
    });

    test('overlay likeStatus takes precedence over menu', () {
      final item = {
        'menu': {
          'menuRenderer': {
            'topLevelButtons': [
              {
                'likeButtonRenderer': {'likeStatus': 'LIKE'},
              },
            ],
            'items': [toggleEntry('LIKE', 'INDIFFERENT')],
          },
        },
      };
      expect(parseLikeRating(item), RatingStatus.like);
    });

    test('no like signals reports unknown', () {
      expect(
        parseLikeRating(menuOf([toggleEntry(null, null)])),
        RatingStatus.unknown,
      );
      expect(
        parseLikeRating({
          'menu': {'menuRenderer': {}},
        }),
        RatingStatus.unknown,
      );
    });
  });

  group('rankSearchSongs', () {
    SongItem song(String id, String title, [String artist = '']) {
      return SongItem(
        Track(
          videoId: id,
          title: title,
          artists: artist.isEmpty ? const [] : [ArtistRef(artist)],
          durationSec: 200,
        ),
      );
    }

    test('title plus artist query surfaces the right recording', () {
      final songs = [
        song('cover1', 'Kid Again', 'Random Covers'),
        song('other', 'Kiddo Once More', 'Someone Else'),
        song('right', 'Kid Again', 'Ivycomb'),
        song('cover2', 'Kid Again (Acoustic)', 'Tribute Band'),
      ];
      final ranked = rankSearchSongs(songs, 'kid again ivycomb');
      expect(ranked.first.track.videoId, 'right');
    });

    test('exact full-query title matches still come first', () {
      final songs = [
        song('partial', 'Kid Again Forever', 'Ivycomb'),
        song('exact', 'Kid Again', 'Tribute Band'),
      ];
      final ranked = rankSearchSongs(songs, 'Kid Again');
      expect(ranked.first.track.videoId, 'exact');
    });

    test('dominant artist recording wins same-titled covers', () {
      final songs = [
        song('cover', 'Kid Again', 'Tribute Band'),
        song('mine', 'Kid Again', 'Ivycomb'),
      ];
      final ranked = rankSearchSongs(
        songs,
        'Kid Again',
        dominantNames: {'ivycomb'},
      );
      expect(ranked.first.track.videoId, 'mine');
    });

    test('ties keep YouTube order', () {
      final songs = [
        song('a', 'Unrelated Song One', 'Band A'),
        song('b', 'Unrelated Song Two', 'Band B'),
      ];
      final ranked = rankSearchSongs(songs, 'xyzzy');
      expect(ranked.map((s) => s.track.videoId).toList(), ['a', 'b']);
    });
  });

  group('parseHomeMoods', () {
    Map<String, dynamic> chip(String title) => {
      'chipCloudChipRenderer': {
        'text': {
          'runs': [
            {'text': title},
          ],
        },
      },
    };

    test('reads chip titles in feed order, deduped', () {
      final res = {
        'contents': {
          'singleColumnBrowseResultsRenderer': {
            'tabs': [
              {
                'tabRenderer': {
                  'content': {
                    'sectionListRenderer': {
                      'contents': [
                        {
                          'chipCloudRenderer': {
                            'chips': [
                              chip('Relax'),
                              chip('Workout'),
                              chip('relax'),
                              chip('  '),
                            ],
                          },
                        },
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      };
      expect(parseHomeMoods(res), ['Relax', 'Workout']);
    });

    test('empty without chips', () {
      expect(parseHomeMoods({}), isEmpty);
      expect(parseHomeMoods({'contents': []}), isEmpty);
    });
  });

  group('rankShelvesByProfile', () {
    SongItem song(
      String id, {
      String artist = '',
      String? artistId,
      String? playlistId,
    }) {
      return SongItem(
        Track(
          videoId: id,
          title: 'Title $id',
          artists: artist.isEmpty
              ? const []
              : [ArtistRef(artist, browseId: artistId)],
          durationSec: 200,
          playlistId: playlistId,
        ),
      );
    }

    BrowseItem browse(String id, String title) => BrowseItem(
      title: title,
      subtitle: '',
      browseId: id,
      thumbnails: const [],
    );

    test('history overlap outranks editorial, ties keep feed order', () {
      final shelves = [
        Shelf('Top songs', [song('chart1'), song('chart2')]),
        Shelf('Listen again', [song('mine1'), song('chart1')]),
        Shelf('Charts', [song('chart3')]),
      ];
      final ranked = rankShelvesByProfile(
        shelves,
        trackIds: {'mine1'},
        artistKeys: const {},
      );
      expect(ranked.map((s) => s.title), [
        'Listen again',
        'Top songs',
        'Charts',
      ]);
    });

    test('mix seeds and followed artists outrank generic rows', () {
      final shelves = [
        Shelf('New music', [song('fresh1'), song('fresh2')]),
        Shelf('My Mix', [song('seed1', playlistId: 'RDEMxyz')]),
        Shelf('Artist spotlight', [browse('UCabc', 'Loved Band')]),
      ];
      final ranked = rankShelvesByProfile(
        shelves,
        trackIds: const {},
        artistKeys: {'UCabc'},
      );
      expect(ranked.map((s) => s.title), [
        'Artist spotlight',
        'My Mix',
        'New music',
      ]);
    });

    test('artist name overlap counts without channel ids', () {
      final shelves = [
        Shelf('Charts', [song('c1')]),
        Shelf('For fans', [song('f1', artist: 'Ivycomb')]),
      ];
      final ranked = rankShelvesByProfile(
        shelves,
        trackIds: const {},
        artistKeys: shelfArtistKeys(
          artists: const [],
          tracks: [
            Track(
              videoId: 'mine',
              title: 'Mine',
              artists: [ArtistRef('IVYCOMB')],
            ),
          ],
        ),
      );
      expect(ranked.first.title, 'For fans');
    });

    test('empty profile preserves feed order', () {
      final shelves = [
        Shelf('B', [song('b1')]),
        Shelf('A', [song('a1')]),
      ];
      final ranked = rankShelvesByProfile(
        shelves,
        trackIds: const {},
        artistKeys: const {},
      );
      expect(ranked.map((s) => s.title), ['B', 'A']);
    });
  });

  group('parseThumbnails square crops', () {
    Map<String, dynamic> thumbs(List<Map<String, dynamic>> ts) => {
      'thumbnails': ts,
    };
    Map<String, dynamic> thumb(String url, int w, int h) => {
      'url': url,
      'width': w,
      'height': h,
    };

    test('appends the API square crop beside the main thumbs', () {
      final node = {
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': thumbs([thumb('https://img/wide.jpg', 640, 360)]),
          },
          'croppedSquareThumbnailRenderer': {
            'thumbnail': thumbs([thumb('https://img/sq.jpg', 120, 120)]),
          },
        },
      };
      final parsed = parseThumbnails(node);
      expect(parsed.map((t) => t.url), [
        'https://img/wide.jpg',
        'https://img/sq.jpg',
      ]);
    });

    test('displayArtwork prefers the API square over a wide frame', () {
      final node = {
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': thumbs([thumb('https://img/wide.jpg', 640, 360)]),
          },
          'croppedSquareThumbnailRenderer': {
            'thumbnail': thumbs([thumb('https://img/sq.jpg', 120, 120)]),
          },
        },
      };
      final track = Track(
        videoId: 'v',
        title: 't',
        thumbnails: parseThumbnails(node),
      );
      expect(track.displayArtwork, 'https://img/sq.jpg');
      // Banners/MPRIS keep the wide original (largest by width).
      expect(track.bestArtwork, 'https://img/wide.jpg');
    });

    test('no crop renderer means main thumbs only', () {
      final node = {
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': thumbs([thumb('https://img/a.jpg', 60, 60)]),
          },
        },
      };
      final parsed = parseThumbnails(node);
      expect(parsed.map((t) => t.url), ['https://img/a.jpg']);
    });
  });

  group('mergeLocalRecents', () {
    Track track(String id) => Track(videoId: id, title: 'Title $id');

    test('local-only tracks go first, server order kept', () {
      final merged = mergeLocalRecents(
        [track('s1'), track('s2')],
        [track('v1'), track('s2')],
      );
      expect(merged.map((t) => t.videoId), ['v1', 's1', 's2']);
    });

    test('empty local list keeps the server list', () {
      final merged = mergeLocalRecents([track('s1')], []);
      expect(merged.map((t) => t.videoId), ['s1']);
    });

    test('cap bounds the merged list', () {
      final merged = mergeLocalRecents(
        [for (var i = 0; i < 10; i++) track('s$i')],
        [track('v1')],
        cap: 5,
      );
      expect(merged.map((t) => t.videoId).toList().length, 5);
      expect(merged.first.videoId, 'v1');
    });
  });

  group('Track recents round-trip', () {
    // What _noteLocalHistory persists must decode again, or session
    // plays silently vanish on restart (grid falls back to stale
    // server history).
    test('rich tracks survive json encode/decode', () {
      final original = Track(
        videoId: 'v1',
        title: 'Ten Toes',
        artists: [
          ArtistRef('Artist One', browseId: 'UCabc'),
          ArtistRef('Unlinked Artist'),
        ],
        album: const AlbumRef('Album One', browseId: 'MPRE1'),
        durationSec: 200,
        thumbnails: const [
          Thumbnail('https://img/a.jpg=w540-h540', width: 540, height: 540),
        ],
        playlistId: 'RDEMxyz',
        radioPlaylistId: 'RDAMVMv1',
        views: '1.2M views',
        rating: RatingStatus.like,
        likeCount: 42,
        dislikeCount: 1,
        explicit: true,
      );
      final encoded = jsonEncode(original.toJson());
      final decoded = Track.fromJson(
        (jsonDecode(encoded) as Map).map((k, v) => MapEntry(k.toString(), v)),
      );
      expect(decoded.videoId, 'v1');
      expect(decoded.title, 'Ten Toes');
      expect(decoded.artists.map((a) => a.name), [
        'Artist One',
        'Unlinked Artist',
      ]);
      expect(decoded.artists.first.browseId, 'UCabc');
      expect(decoded.album?.browseId, 'MPRE1');
      expect(decoded.thumbnails.first.url, 'https://img/a.jpg=w540-h540');
      expect(decoded.playlistId, 'RDEMxyz');
      expect(decoded.rating, RatingStatus.like);
      expect(decoded.likeCount, 42);
      expect(decoded.explicit, isTrue);
      expect(decoded, original);
    });

    test('explicit defaults to false and participates in equality', () {
      const clean = Track(videoId: 'v', title: 't');
      expect(clean.explicit, isFalse);
      expect(Track.fromJson({}).explicit, isFalse);
      expect(clean.toJson().containsKey('explicit'), isFalse);
      const flagged = Track(videoId: 'v', title: 't', explicit: true);
      expect(flagged, isNot(clean));
      expect(flagged.copyWith(), flagged);
      expect(flagged.copyWith(explicit: false), clean);
    });

    test('junk decodes degrade without throwing', () {
      Track? decode(dynamic e) {
        if (e is! Map) return null;
        try {
          return Track.fromJson(e.map((k, v) => MapEntry(k.toString(), v)));
        } catch (_) {
          return null;
        }
      }

      expect(decode('junk'), isNull);
      expect(decode({})?.videoId, '');
    });
  });

  group('parseHistoryCounts', () {
    Map<String, dynamic> historyItem(String? videoId) => {
      'musicResponsiveListItemRenderer': {
        if (videoId != null) 'playlistItemData': {'videoId': videoId},
        'flexColumns': [
          _col([_run('Some Song')]),
        ],
      },
    };

    Map<String, dynamic> historyPage(List<Map<String, dynamic>> items) => {
      'contents': {
        'singleColumnBrowseResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {
                    'contents': [
                      {
                        'itemSectionRenderer': {
                          'contents': [
                            {
                              'musicShelfRenderer': {
                                'title': {
                                  'runs': [_run('Today')],
                                },
                                'contents': items,
                              },
                            },
                          ],
                        },
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      },
    };

    test('repeats count per play', () {
      final res = historyPage([
        historyItem('a'),
        historyItem('b'),
        historyItem('a'),
        historyItem('a'),
        historyItem('c'),
      ]);
      expect(parseHistoryCounts(res), {'a': 3, 'b': 1, 'c': 1});
    });

    test('items without ids bound the walk but never count', () {
      final res = historyPage([historyItem(null), historyItem('a')]);
      expect(parseHistoryCounts(res), {'a': 1});
      expect(parseHistoryCounts(res, maxItems: 1), isEmpty);
    });

    test('sign-in wall and junk yield empty counts', () {
      expect(parseHistoryCounts({'error': 'x'}), isEmpty);
      expect(parseHistoryCounts(null), isEmpty);
      expect(parseHistoryCounts('junk'), isEmpty);
      expect(parseHistoryCounts({'contents': []}), isEmpty);
    });

    test('tracks parse most-recent-first, deduped', () {
      Map<String, dynamic> item(String id, String title) => {
        'musicResponsiveListItemRenderer': {
          'playlistItemData': {'videoId': id},
          'flexColumns': [
            _col([_run(title, videoId: id)]),
            _col([_run('Some Artist')]),
          ],
        },
      };
      final res = {
        'contents': [
          item('a', 'Song A'),
          item('b', 'Song B'),
          item('a', 'Song A'),
          {
            'musicResponsiveListItemRenderer': {'flexColumns': []},
          },
        ],
      };
      final tracks = parseHistoryTracks(res);
      expect(tracks.map((t) => t.videoId), ['a', 'b']);
      expect(tracks.first.title, 'Song A');
      expect(tracks.first.artistNames(), contains('Some Artist'));
      expect(parseHistoryTracks({'error': 'x'}), isEmpty);
    });
  });
}
