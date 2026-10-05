// Fixture tests for the InnerTube parsers: hand-built JSON shaped like
// real responses exercises list rows, panel videos, and shelves.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/parse.dart';
import 'package:nixietube/core/models/models.dart';

Map<String, dynamic> _run(String text,
    {String? videoId, String? browseId}) {
  final run = <String, dynamic>{'text': text};
  if (videoId != null) {
    run['navigationEndpoint'] = {
      'watchEndpoint': {'videoId': videoId}
    };
  }
  if (browseId != null) {
    run['navigationEndpoint'] = {
      'browseEndpoint': {'browseId': browseId}
    };
  }
  return run;
}

Map<String, dynamic> _col(List<Map<String, dynamic>> runs) {
  return {
    'musicResponsiveListItemFlexColumnRenderer': {
      'text': {'runs': runs}
    }
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
          {'url': 'https://x/a.jpg', 'width': 60, 'height': 60}
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
    });

    test('plain artist/album inference without endpoints', () {
      final li = {
        'flexColumns': [
          _col([_run('Track', videoId: 'V1')]),
          _col([
            _run('Lone Singer'),
            _run(' • '),
            _run('Great Record'),
          ]),
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

  group('parsePanelVideo', () {
    test('byline with linked artist and release', () {
      final item = {
        'title': {
          'runs': [_run('Panel Song')]
        },
        'navigationEndpoint': {
          'watchEndpoint': {'videoId': 'PV1'}
        },
        'longBylineText': {
          'runs': [
            _run('Panel Artist', browseId: 'UC999'),
            _run(' • '),
            _run('Panel Album', browseId: 'MPRE999'),
          ]
        },
        'lengthText': {
          'runs': [_run('4:01')]
        },
      };
      final t = parsePanelVideo(item)!;
      expect(t.videoId, 'PV1');
      expect(t.artists.map((a) => a.name), ['Panel Artist']);
      expect(t.album!.browseId, 'MPRE999');
      expect(t.durationSec, 241);
      expect(t.radioPlaylistId, 'RDAMVMPV1');
    });

    test('plain byline infers artist then album', () {
      final item = {
        'title': {
          'runs': [_run('Other Song')]
        },
        'navigationEndpoint': {
          'watchEndpoint': {'videoId': 'PV2'}
        },
        'shortBylineText': {
          'runs': [
            _run('Mystery Act'),
            _run(' • '),
            _run('Hidden Gem'),
          ]
        },
      };
      final t = parsePanelVideo(item)!;
      expect(t.artists.map((a) => a.name), ['Mystery Act']);
      expect(t.album!.name, 'Hidden Gem');
    });
  });

  group('parseShelf', () {
    test('carousel with song and browse rows', () {
      final shelf = {
        'musicCarouselShelfRenderer': {
          'header': {
            'musicCarouselShelfBasicHeaderRenderer': {
              'title': {
                'runs': [_run('Listen again')]
              }
            }
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Quick Song')]
                },
                'subtitle': {
                  'runs': [_run('Quick Artist')]
                },
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': 'Q1'}
                },
              }
            },
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Cool Album')]
                },
                'subtitle': {
                  'runs': [_run('Album • 2023')]
                },
                'navigationEndpoint': {
                  'browseEndpoint': {'browseId': 'MPRE1'}
                },
              }
            },
          ],
        }
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
                'runs': [_run('New music')]
              }
            }
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Linked Song')]
                },
                'subtitle': {
                  'runs': [
                    _run('Real Artist', browseId: 'UCART'),
                    _run(' • '),
                    _run('Real Album', browseId: 'MPREALB'),
                  ]
                },
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': 'V1'}
                },
              }
            },
          ],
        }
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
                'runs': [_run('Charts')]
              }
            }
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [_run('Plain Song')]
                },
                'subtitle': {
                  'runs': [_run('Plain Artist • Plain Album')]
                },
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': 'V2'}
                },
              }
            },
          ],
        }
      };
      final s = parseShelf(shelf)!;
      final song = s.items.single as SongItem;
      expect(song.track.artists.map((a) => a.name), ['Plain Artist']);
    });
  });

  group('buildPlaylist', () {
    test('parses musicResponsiveHeaderRenderer with linked author and thumbnails', () {
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
                              'runs': [_run('My Awesome Playlist')]
                            },
                            'subtitle': {
                              'runs': [_run('Playlist description')]
                            },
                            'straplineTextOne': {
                              'runs': [_run('Cool Artist', browseId: 'UCARTIST123')]
                            },
                            'thumbnail': {
                              'musicThumbnailRenderer': {
                                'thumbnail': {
                                  'thumbnails': [
                                    {'url': 'https://img/pl_544.jpg', 'width': 544, 'height': 544}
                                  ]
                                }
                              }
                            }
                          }
                        },
                        {
                          'musicPlaylistShelfRenderer': {
                            'contents': [
                              {
                                'musicResponsiveListItemRenderer': {
                                  'flexColumns': [
                                    _col([_run('Track 1', videoId: 'T1')])
                                  ]
                                }
                              }
                            ]
                          }
                        }
                      ]
                    }
                  }
                }
              }
            ]
          }
        }
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
    });

    test('falls back to track thumbnail when header thumbnail is missing', () {
      final res = {
        'musicResponsiveHeaderRenderer': {
          'title': {
            'runs': [_run('Track Thumb Playlist')]
          },
        },
        'musicPlaylistShelfRenderer': {
          'contents': [
            {
              'musicResponsiveListItemRenderer': {
                'flexColumns': [
                  _col([_run('Song', videoId: 'S1')])
                ],
                'thumbnail': {
                  'musicThumbnailRenderer': {
                    'thumbnail': {
                      'thumbnails': [
                        {'url': 'https://img/track1.jpg', 'width': 120, 'height': 120}
                      ]
                    }
                  }
                }
              }
            }
          ]
        }
      };

      final pl = buildPlaylist(res)!;
      expect(pl.title, 'Track Thumb Playlist');
      expect(pl.thumbnails.length, 1);
      expect(pl.thumbnails.first.url, 'https://img/track1.jpg');
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
                  {'url': 'https://img/cover.jpg', 'width': 300, 'height': 300}
                ]
              }
            }
          }
        }
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
                        {'url': 'https://img/shelf_track.jpg', 'width': 200, 'height': 200}
                      ]
                    }
                  }
                }
              }
            }
          ]
        }
      };
      final thumbs = playlistArtworkThumbs(res);
      expect(thumbs.length, 1);
      expect(thumbs.first.url, 'https://img/shelf_track.jpg');
    });
  });
}
