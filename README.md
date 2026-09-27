# NixieTube — native YouTube Music client (Kotlin + Compose Multiplatform)

A Material 3 desktop client for YouTube Music. No browser, no web views:
it talks to YouTube Music's InnerTube API directly (search, browse, streams)
and plays audio through a reusable mpv subprocess.
No ads are ever served, so there is
nothing to block.

## Modules

All business logic lives in UI-free `core` modules on purpose: only
`:desktop` contains Compose code, so the UI layer can be swapped later
(e.g. Qt/QML) without rewriting the app.

- `:core:innertube` — InnerTube client (Ktor): home shelves, search with
  typed sections (songs/albums/artists/playlists), album/artist/playlist
  details, up-next/radio continuation, header-based auth, LRCLIB lyrics
  live in the desktop module. Stream URLs are resolved with
  NewPipeExtractor (handles YouTube's throttling-parameter deciphering).
- `:core:player` — `PlayerEngine` interface + mpv subprocess backend,
  `PlayerController` (queue, shuffle/repeat, radio auto-continuation,
  500 ms position ticker) over `StateFlow`. No UI imports.
- `:desktop` — Compose Multiplatform M3 UI (home, search, detail,
  library/account, player bar, now-playing with queue + synced lyrics),
  MPRIS service (`org.mpris.MediaPlayer2.nixietube`), Discord Rich
  Presence over local IPC, artwork cache (Ktor + ImageIO, no image lib).

## Requirements

- JDK 21+ to build and run (tested on 26)
- mpv installed (required audio backend)
- A display (X11/Wayland) for `:desktop:run`
- Gradle wrapper (`./gradlew`) — no system Gradle needed
- For account features: a Google Cloud OAuth client of type
  **TVs and Limited Input devices** with YouTube Data API v3 enabled

## Run

```sh
./gradlew :desktop:run
./gradlew :desktop:runTrimmed   # same app on a 50 MB jlink-trimmed runtime
```

```sh
./gradlew :core:innertube:smoke    # home, search, stream resolve, album detail
```

## How auth works

Two mechanisms, split by what actually accepts them:

- **Playback, search, browse**: anonymous InnerTube. No login needed.
- **Library, playlists, liked songs, ratings**: YouTube Data API v3 with
  an OAuth token (TV-device flow: the app shows a code, you approve at
  `google.com/device`, tokens persist with auto-refresh). InnerTube
  rejects third-party OAuth/cookie sessions from here, so account data
  deliberately bypasses it.
- **Cookie login** (paste the `Cookie` header in Library) is kept as a
  fallback: paste via DevTools' *view source*, as the pretty headers view
  truncates long values.

## Configuration

`~/.config/nixietube/`:

- `auth.properties` — `cookie` + `sapisidHash` (copied from an
  authenticated `youtubei/v1/*` browser request) unlocks library/likes.
  Manageable from the Library screen.
- `config.properties` — `discord.appId` (optional), `discord.enabled`,
  `discord.statusText` (`app`, `song`, or `artists`), and `mpris.enabled`.
  Discord needs a Discord application ID
  (https://discord.com/developers/applications) and a running client.
  `discord.appId` is optional — when empty, the built-in application ID
  (1552404006498869318) is used automatically.

## Notes / known limits

- Audio-only v1, anonymous-first; account features go through the Data
  API (OAuth device flow) since InnerTube rejects third-party sessions.
- Windows/macOS packaging deferred; code is multiplatform-clean.
- InnerTube is unofficial and can break when YouTube changes it —
  same maintenance treadmill as `youtubei.js` in NixieTube.
