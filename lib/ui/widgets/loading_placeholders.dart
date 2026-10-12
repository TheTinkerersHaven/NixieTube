// Placeholder content for skeleton scopes: the loaded UI renders
// these under an enabled Skeletonizer, so shimmering bones stand
// in with the exact layout and content reveals in place (same
// pattern as the home feed). The text itself never shows — only
// its length matters, sizing the bones — so the strings are
// deliberately varied in length.

import '../../core/models/models.dart';

/// Placeholder song rows (8) for skeleton track lists: real
/// [TrackRow]s with inert callbacks, so the skeleton matches the
/// loaded geometry (index, art, two text lines, duration).
/// No artwork URLs: tiles render full bones under the skeleton
/// scope without touching the artwork store.
const placeholderTracks = <Track>[
  Track(
    videoId: 'skeleton-0',
    title: 'Midnight reverie over static',
    artists: [ArtistRef('Northern lights collective')],
    durationSec: 214,
  ),
  Track(
    videoId: 'skeleton-1',
    title: 'Glass',
    artists: [ArtistRef('A. Short')],
    durationSec: 183,
  ),
  Track(
    videoId: 'skeleton-2',
    title: 'Paper lanterns in the rain',
    artists: [ArtistRef('Mira Sol'), ArtistRef('Guest Verse')],
    durationSec: 247,
  ),
  Track(
    videoId: 'skeleton-3',
    title: 'Ultraviolet daydream',
    artists: [ArtistRef('The Long Commute')],
    durationSec: 196,
  ),
  Track(
    videoId: 'skeleton-4',
    title: 'Low orbit',
    artists: [ArtistRef('Cassini Division')],
    durationSec: 228,
  ),
  Track(
    videoId: 'skeleton-5',
    title: 'Half-remembered summer anthem',
    artists: [ArtistRef('Palms & Wires')],
    durationSec: 205,
  ),
  Track(
    videoId: 'skeleton-6',
    title: 'Neon dust',
    artists: [ArtistRef('V. Kowalski')],
    durationSec: 172,
  ),
  Track(
    videoId: 'skeleton-7',
    title: 'The cartographer sleeps alone',
    artists: [ArtistRef('Meridian Bloom Ensemble')],
    durationSec: 261,
  ),
];

/// Placeholder lyric lines (8, untimed so no row highlights or
/// auto-scrolls) for the skeleton lyrics list. Lengths vary so
/// the bones read as centered verse lines.
const placeholderLyrics = <LyricLine>[
  LyricLine(timeMs: -1, text: 'softly the evening folds its wings'),
  LyricLine(timeMs: -1, text: 'over the quiet wire'),
  LyricLine(timeMs: -1, text: 'and every window holds a small lit room'),
  LyricLine(timeMs: -1, text: 'humming low'),
  LyricLine(timeMs: -1, text: 'we counted stations on the night line home'),
  LyricLine(timeMs: -1, text: 'half asleep, half song'),
  LyricLine(timeMs: -1, text: 'the city breathing slow beneath the rain'),
  LyricLine(timeMs: -1, text: 'goodnight, goodnight'),
];

/// Placeholder browsables (6) for skeleton rails: no artwork URLs,
/// so the cards render full bones under the skeleton scope.
const placeholderBrowseItems = <BrowseItem>[  BrowseItem(
    title: 'Midnight reverie',
    subtitle: 'Album • 2024',
    browseId: 'skeleton-browse-0',
    thumbnails: [],
  ),
  BrowseItem(
    title: 'Glass',
    subtitle: 'Single • 2023',
    browseId: 'skeleton-browse-1',
    thumbnails: [],
  ),
  BrowseItem(
    title: 'Paper lanterns in the rain',
    subtitle: 'Album • 2022',
    browseId: 'skeleton-browse-2',
    thumbnails: [],
  ),
  BrowseItem(
    title: 'Ultraviolet daydream',
    subtitle: 'EP • 2024',
    browseId: 'skeleton-browse-3',
    thumbnails: [],
  ),
  BrowseItem(
    title: 'Low orbit',
    subtitle: 'Album • 2021',
    browseId: 'skeleton-browse-4',
    thumbnails: [],
  ),
  BrowseItem(
    title: 'Neon dust',
    subtitle: 'Compilation • 2020',
    browseId: 'skeleton-browse-5',
    thumbnails: [],
  ),
];

/// Placeholder artist for the skeleton artist view: the loaded
/// [_ArtistDetailView] layout renders under an enabled Skeletonizer,
/// so banner, buttons, top songs, rails and bio reveal in place.
/// No artwork URLs: tiles render full bones without touching the
/// artwork store.
const placeholderArtist = ArtistDetail(
  name: 'Northern lights collective',
  description:
      'Half-remembered summer anthems from the long commute home, '
      'paper lanterns in the rain and neon dust on every window.',
  thumbnails: [Thumbnail('', width: 1280, height: 498)],
  topSongs: placeholderTracks,
  albums: placeholderBrowseItems,
  singlesAndEps: placeholderBrowseItems,
  relatedPlaylists: placeholderBrowseItems,
  similarArtists: placeholderBrowseItems,
  subscribers: '1.24M subscribers',
);

/// Placeholder mixes (6) for the skeleton Mixed-for-you rail.
const placeholderMixes = <HomeMix>[
  HomeMix(title: 'Midnight reverie', subtitle: 'Mix', thumbnails: []),
  HomeMix(title: 'Glass', subtitle: 'Mix', thumbnails: []),
  HomeMix(
    title: 'Paper lanterns in the rain',
    subtitle: 'Mix',
    thumbnails: [],
  ),
  HomeMix(title: 'Ultraviolet daydream', subtitle: 'Mix', thumbnails: []),
  HomeMix(title: 'Low orbit', subtitle: 'Mix', thumbnails: []),
  HomeMix(title: 'Neon dust', subtitle: 'Mix', thumbnails: []),
];
