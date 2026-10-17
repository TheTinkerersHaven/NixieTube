# NixieTube changelog

## Unreleased (0.1.2)

### Artwork
- Square tiles now decode at the render's pixel size (`cacheWidth` scaled to the tile's short side × device pixel ratio), so a 16:9 music-video still cover-fits the square box without being upscaled into softness. Tile pixel size is read from the PNG header only (`ArtworkStore.tileSize`) — no full decode.
- The artwork store falls back from a throttled panel (error body) to the watch-next row's own last square thumbnail, then to fetched album art; transport blips never condemn a track for the session, and a retry with a newly known album id re-attempts resolution.
- `maxResGuess` now prefers the YouTube `maxresdefault` still (1280×720) for video rows.

### Playback & player
- Durations now appear in the Up-next list for unplayed tracks: the signed-in queue pass stamps lengths from its per-row watch-next read (zero extra requests), and the stream resolver folds the player response's `videoDetails.lengthSeconds` into the row on every resolve/prefetch.
- Player controller refuses to open a stream when the startup audio probe finds mpv missing (`backendUnavailable`), instead of spinning until the play timeout.
- Session restore reads the playback JSON on a worker isolate so a large saved queue never stalls startup.

### Desktop integrations
- Discord Rich Presence and MPRIS now use uniform periodic retry loops (fixed 10 s interval, injectable for tests) instead of backoff ladders that can give up. A taken MPRIS name is retried, not aborted; a dropped connection is re-claimed; ping failures revive the connection.
- MPRIS never leaks a `ArtworkStore` on repeated failed connects.
- Sleep inhibition holds a `systemd-inhibit` lock while playing and releases it on pause/stop/quit; a crash releases it via the child watching the parent pid.

### InnerTube / network
- `InnerTube.post()` now degrades gracefully on a sustained transport outage instead of surfacing a raw exception (error bodies are still returned for auth verdicts).
- Added `watchInfo`/`watchInfos`: one watch-next read returns both the like state and every queue-row length it carries, so durations ride along with the like-state pass at no extra request.
- `explore()`, `charts()`, `historySnapshot()` added; `_fetchWithRetry` uses a 3-attempt backoff ladder for cover lookups.
- Shared Dio client gained a retry interceptor for transient statuses/transport blips (`Retry-After` honored) and per-host connection caps.

### Settings / UI
- Home screen reorganized into fixed sections (Listen Again, Forgotten favorites, New releases, Albums made for you, Trending in `<country>`, Trending globally) with the multi-column `TrackColumns` rail and bullet-separated artist names with spacing between them.
- `explicit` flag parsed from `MUSIC_EXPLICIT_BADGE`, surfaced in the player bar, track rows and rail cards.
- Theme remembers the system primary color across launches; settings add an "Underline links" toggle and order Google OAuth before cookie login.
