# NixieTube changelog

All notable changes to NixieTube are documented in this file, newest release
first. Each release gets its own section; when a release is cut its section is
finalized with a version and date.

## 0.1.2

- Durations now appear in the Up-next list for unplayed tracks: the signed-in
  queue pass stamps lengths from its per-row watch-next read (zero extra
  requests), and the stream resolver folds the player response's
  `videoDetails.lengthSeconds` into the row on every resolve/prefetch.
- Thumbnail softness fixed: square tiles decode at the render's pixel size
  (short side × device pixel ratio) so BoxFit.cover fills the box without
  upscaling; tile pixel size is read from the PNG header only.
- Thumbnail resilience: a throttled panel (error body) falls back to the
  watch-next row's own last square thumbnail, then to fetched album art;
  transport blips never condemn a track for the session.
- Discord Rich Presence and MPRIS use uniform periodic retry loops (fixed 10 s
  interval, injectable for tests) instead of backoff ladders that can give up;
  a taken MPRIS name is retried, not aborted; a dropped connection is
  re-claimed; MPRIS no longer leaks an ArtworkStore on repeated failed
  connects.
- `InnerTube.post()` degrades gracefully on a sustained transport outage
  instead of surfacing a raw exception; added `watchInfo`/`watchInfos`
  (like state + every queue-row length in one read), `explore()`,
  `charts()`, `historySnapshot()`; cover lookups use a 3-attempt backoff
  ladder.
- Home screen reorganized into fixed sections (Listen Again, Forgotten
  favorites, New releases, Albums made for you, Trending in `<country>`,
  Trending globally) with the multi-column `TrackColumns` rail and spaced
  bullet separators between artist names.
- `explicit` flag parsed from `MUSIC_EXPLICIT_BADGE`, surfaced in the player
  bar, track rows and rail cards.
- Theme remembers the system primary color across launches; settings add an
  "Underline links" toggle and order Google OAuth before cookie login.

## 0.1.1

- Artwork pipeline rework: covers render whole (no client-side crop, no
  letterbox trimming); square tiles resolve YouTube's own square art or
  fetched album art and cover-fit the frame; `maxResGuess` prefers the
  1280×720 `maxresdefault` still; PNG-header tile-size reads; error-page
  rejection; resilient Dio client with retry interceptor and per-host
  connection caps.
- InnerTube adds `explore`, `charts`, `watchInfo`/`watchInfos`,
  `historySnapshot`; square-cover resolution checks the watch-next row's own
  last thumbnail first, falls back to album art, and never condemns a track
  on a transport blip or throttling error body.
- `Track` gains an `explicit` flag parsed from `MUSIC_EXPLICIT_BADGE`,
  surfaced in the player bar, track rows and rail cards.
- Player controller folds stream lengths into queue rows, adds bulk
  `updateTrackDurations`/`updateTrackMetadata`, refuses playback when the
  startup audio probe fails, restores session on a worker isolate.
- New `audio_backend.dart` probes mpv at startup; new `sleep_inhibit.dart`
  holds a systemd sleep lock while playing.
- Discord and MPRIS gain periodic retry loops with injectable RPC/client
  seams.
- Last.fm falls back to bundled shared credentials when settings fields are
  empty; custom keys move behind the integration card's cog.
- Home screen reorganizes into fixed sections with a multi-column
  `TrackColumns` rail and a ranked quick-picks pool that dedupes by artwork.
- AppState caches track metadata, local play counts, and artist avatars
  across launches; imports watch history for quick-picks ranking; stamps
  queue ratings and lengths together.
- Theme remembers the system primary color across launches; settings add an
  "Underline links" toggle and order Google OAuth sign-in before the cookie
  step.

## 0.1.0

- First desktop release of the Flutter port: YouTube Music playback with
  queue, radio, likes, history, and desktop integrations (Discord Rich
  Presence, MPRIS, system tray, sleep inhibition).
