# NixieTube changelog

All notable changes to NixieTube are documented in this file, newest release
first. Each release gets its own section; when a release is cut its section is
finalized with a version and date.

## 0.2.0

### Artwork

- Covers now render whole: no client-side center-crop and no letterbox-bar
  trimming. Square tiles use YouTube's own square art (or the fetched album
  cover) and cover-fit the frame; a video still is only cropped when no square
  art exists for it.
- `maxResGuess` prefers the 1280×720 `maxresdefault` still, error pages are
  rejected, and square-cover resolution checks the watch-next row's own last
  thumbnail first, falls back to album art, and never condemns a track for the
  session on a transport blip or a throttling error body.
- Fixed soft thumbnails: tiles decode at the render's own pixel size (short side
  × device pixel ratio) so the cover fit no longer upscales a 16:9 frame into
  a blurry square. The size is read from the PNG header, never a full decode.

### Player

- Durations now show in the Up-next list for unplayed tracks. The signed-in
  queue pass stamps lengths from the per-row watch-next read it already makes
  (zero extra requests), and the stream resolver folds
  `videoDetails.lengthSeconds` into the row on every resolve and prefetch.
- The player refuses to open a stream when the startup probe finds mpv missing
  instead of spinning until the play timeout; session restore runs on a worker
  isolate so a large saved queue never stalls startup.
- Bulk `updateTrackDurations`/`updateTrackMetadata` restamp queue rows in one
  emission.
- **A stream that dies mid-playback now recovers.** The backend's own error
  event was never wired up, so the whole retry/backoff path was unreachable:
  a refused stream just stopped with nothing to say why. Engine errors now
  reach the controller, which re-resolves under a fresh visitor and resumes
  where it left off, restarts the backend stack once as last resort, and
  otherwise reports the backend's real reason instead of a blanket failure.
  Hung opens time out at 20 s instead of spinning forever.
- **State delivery is re-entrancy safe.** `_update` broadcasts synchronously
  to listeners, and a listener (`AppState._onPlayerState` →
  `_stampQueueMetadata` → `updateTrackRatings`) could call back into
  `_update` mid-delivery, crashing with `Cannot fire new event`. Nested
  updates are now deferred to a microtask instead of re-entering the
  broadcast controller.

### Discord Rich Presence

- **Discord is now pure Dart.** A small IPC client (`lib/sys/discord_ipc.dart`)
  replaces the Rust-bridge-backed package: no `flutter_rust_bridge`, no
  cargokit native library, and nothing to download at build time.
- Because we own the socket there is no one-shot client singleton any more:
  changing the application id takes effect immediately, a failed connect can't
  leave a half-built client behind, and the presence recovers from a restart
  instead of requiring one.
- **A lost IPC link now recovers on its own.** Discord refuses a new handshake
  for roughly half a minute after a session ends, so the old fixed 10s retry
  only ever landed inside that window and the presence stayed dead for the rest
  of the run — the status line then looked frozen no matter what you picked.
  Retries now back off, waiting out the window before probing again.
- **Teardown follows the protocol.** The session is closed with the CLOSE
  opcode rather than a `{"cmd":"CLOSE"}` frame, which Discord rejects with
  `4000 Payload requires a nonce`. Frame reassembly and the handshake completer
  now belong to a single session, so a reply still in flight from a closing
  socket can no longer be mistaken for the next connection's answer.
- **Selectable status line**: App Name, Song Title, Song Artist or Song Album,
  persisted across launches.
- **The status line is sent as the activity's `name`.** Discord fills that field
  in with the *application* name when it is missing — confirmed on the live
  client, which answers an activity sent without one with `"name":"NixieTube"` —
  so the picker had no visible effect until the choice went on the wire. The
  song and its artist stay on the two lines below it.
- Connection failures report the real cause (`error: Invalid Client ID`,
  `no Discord IPC socket reachable`, `no READY from Discord`) instead of a bare
  "idle".
- Disabling and re-enabling the presence re-initializes and reconnects; the
  retry timer re-pushes the current activity after a drop.

### MPRIS

- Uniform periodic retry loop (fixed 10 s, injectable for tests) instead of a
  backoff ladder that could give up. A name held by another instance is retried
  rather than abandoned, a dropped connection is re-claimed via a liveness
  ping, and repeated failed connects no longer leak artwork stores.

### InnerTube & network

- Added `explore()`, `charts()` (country plus the worldwide Top 100),
  `historySnapshot()`, and `watchInfo`/`watchInfos` — one watch-next read that
  returns the like state and every queue-row length it carries.
- Shared HTTP client gained a retry interceptor for transient statuses and
  transport failures (honouring `Retry-After`) plus per-host connection caps;
  `post()` degrades gracefully on a sustained outage instead of throwing a raw
  exception into the UI.

### Home & UI

- Home is organized into fixed sections — personal picks and Jump back in,
  Discover, Listen Again, Forgotten favorites, New releases, Albums made for
  you, `Trending in <country>` and `Trending globally` — with a multi-column
  `TrackColumns` rail and a ranked quick-picks pool seeded from watch history
  and deduped by artwork.
- `explicit` flags parsed from `MUSIC_EXPLICIT_BADGE`, shown in the player bar,
  track rows and rail cards.
- Track metadata, play counts and artist avatars are cached across launches.
- Theme remembers the system accent color; settings gain an "Underline links"
  toggle and order Google OAuth before the cookie sign-in.
- `systemd-inhibit` sleep lock held while playing, released on pause/stop/quit
  and by the child process if the app ever dies.

### Build & release

- The release job checks out the repository, so it can read the changelog.
- Release notes are taken from the matching section of `CHANGES.md` instead of
  being generated from commit messages; a missing section fails the release
  rather than shipping an empty one.

## 0.1.1

- Desktop release of the Flutter client: playback with queue, shuffle,
  prefetch and radio, library and likes, search, lyrics, artwork tiles, MPRIS
  media keys, Discord Rich Presence, system tray, Last.fm scrobbling, and
  sign-in via Google OAuth or browser cookies.

## 0.1.0

- First release of the Flutter port of NixieTube.