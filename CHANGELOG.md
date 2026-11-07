# Changelog

All notable changes to NixieTube are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.2] — 2026-11-07

### Added

- **Resolved stream URLs are cached for five minutes.** Replaying a track within the window skips the network resolve entirely; the stream resolver re-resolves only when the cached URL expires or the cache is cleared.
- **Age-restricted tracks play through yt-dlp.** When InnerTube cannot return a playable stream, the app falls back to the `yt-dlp` binary, handing it your session cookie (when signed in) through a throwaway file, so age-restricted tracks resolve instead of failing.
- **Search finds the recording you named.** Queries that name an exact song now fill in the matching single/EP tracks, pull the named recording from the artist's catalog when YouTube's results omit it, and rank the merged songs by text match.
- **App updates.** Check GitHub releases from Settings → App updates and install a new AppImage in place; the running binary is replaced atomically and takes effect on the next launch. A "Check for updates" item also lives in the tray menu.
- **Update banner at startup.** On launch the app checks GitHub for a newer release and shows a banner at the top of the window when one is available; tap "Settings" to install it. The banner is hidden while the check is in flight and when nothing is available.
- **Dismissable banners.** Both the update-available banner and the expired-session banner now have a close button; dismissed banners stay hidden for the rest of the session.

### Fixed

- **The liked songs list no longer has extra padding.** Its inner scrollable had the same insets as the home page itself, double-spacing the list; it now fills its box edge to edge.
- **Settings no longer crashes on versions without a build number.** Running with a bare version like `0.3.1` (no `+N`) tried to read a missing `split('+')[1]` and threw; it now falls back to "unknown".

### Changed

- **Upcoming tracks are resolved further ahead.** Playback used to pre-resolve only the next track, right when the current one started; it now resolves up to three tracks ahead in the background, and the immediate next track close to handoff (half its length ahead, capped at 30 seconds) so its signed URL is still fresh. Shuffle and repeat-one skip prefetching since the next track isn't predictable.
- **The one-click import from your system browser is gone.** It read cookies through a headless Chromium + DevTools session that proved unreliable, so sign-in now happens through the in-app login window or by pasting a cookie header from DevTools.
- **Playback errors are now reported through a single detailed SnackBar.** The mini player bar no longer shows its own inline error line, which was hidden while the Now Playing view was open; the SnackBar now carries the full error reason (for example the HTTP status from the CDN) instead of a generic "check your network" message.
- **Settings are easier to scan.** Every section now carries a short description of what it contains.
- **Track menus open under the three-dots button.** The ⋮ menu on a track row now anchors to the button itself instead of the row's left edge, and the button stays visible while the menu is open.
- **The Up next drag handle stays visible with its menu.** Opening a track's ⋮ menu in the queue keeps the reorder handle revealed alongside it.

## [0.4.1] — 2026-11-04

### Changed

- **The login window no longer uses the vendored webview fork.** It now runs on the published `desktop_webview_window` package.

## [0.4.0] — 2026-11-03

### Added

- **Search results prefer the popular recording.** When several songs share a title (e.g. "Godzilla"), the one with the most views ranks first instead of an arbitrary order.
- **The Now Playing view remembers its tab.** Reopening it lands on the last tab used (Up next, Lyrics or Info) instead of always Up next.
- **Discord shows video cover art.** Tracks whose only artwork is a 16:9 video still now send that still to Discord instead of no cover at all.
- **A "Song info" action on every track.** The ⋮/right-click menu now opens a modal with the track's title, artists, album, year, duration, play count and likes — the same details as the Now Playing Info tab.
- **Song info fills in from Last.fm.** The Info tab and the song-info modal show genre tags for the song and the artist on separate lines (a long dash marks a missing line), play counts for both YouTube Music and Last.fm, Last.fm listeners, the Last.fm album when YouTube has none, and a short song summary. Lookups are cached per track so tab switches no longer refetch, and YTM counts are fetched once per session for the queue rows that carry no view count; matches are scored against artist, title and duration so renamed or featured uploads resolve to the right release.
- **Search leads with an Exact Match.** The closest result to the query is surfaced in its own section at the top of the All view, followed by the natural category order.
- **Artist pages gained a "Play all" button.** The top songs now play from the first track via a main Play all button; Shuffle moved to the second button.
- **Track rows keep their actions tidy.** The dislike button stays on every row, and the overflow menu appears on hover instead of sitting on every row; the play count sits in a fixed, right-aligned column.
- **Artist pages use a full-bleed hero.** The banner spans the content area with a gradient into the background, with the name, subscriber count and actions inside it; top songs fill as many columns as fit (preloaded from the artist's songs playlist instead of the five-song preview), the About panel stretches beside them to the songs' height and opens its full bio in a modal, and rails scale to fill the row edge to edge.

### Fixed

- **Discord Rich Presence no longer spams updates.** Presence was re-sent on every 500 ms playback tick (roughly twice a second); it now re-sends only on track, play/pause or seek changes, with a periodic drift correction.
- **A paused track disappears from Discord after 15 minutes.** Presence used to keep showing a paused track forever; it is withdrawn once the pause lasts 15 minutes.
- **Sleep inhibition could leak a lock.** A pause/play race could spawn two `systemd-inhibit` children and leave the first one holding sleep blocked after the app quit; the lock is now serialized and released on exit.
- **The window title is properly spelled.** The GTK window was titled "nixietube"; it is now "NixieTube".
- **Playlist tiles no longer show black borders.** Quick-pick tiles now resolve YouTube's own square cover instead of cover-fitting a 16:9 frame.
- **Artwork no longer shimmers forever.** The artwork workers only offered themselves back to the pool once per load, so later tiles waited forever; they re-offer after every job now.
- **Artwork stays sharp on large tiles.** Tiles were decoding at a fixed 200 px and upscaling into blur; they now decode at the tile's actual size.
- **The library backdrop no longer repaints on every progress tick.** The palette wash now arrives through its own notifier instead of an app-wide notification.
- **The "Load more" spinner now appears.** The in-flight flag change was not notifying the UI.
- **Typing in the search field no longer repaints the whole page.** The results list now only rebuilds what actually changed.
- **Last.fm no longer stalls forever.** A stalled connection blocked every later scrobble; requests now time out and retry, and a failed scrobble is retried on the next tick.
- **Discord IPC no longer hangs on a dead socket.** Send failures now reach the caller, and concurrent connect attempts share one attempt instead of orphaning a handshake.
- **MPRIS no longer hammers the disk.** Artwork file checks are memoized and the debug log is bounded and debug-only.
- **The credential fallback file is now 0600.** When no keyring is available, the secret fallback is written with owner-only permissions.
- **Search history writes no longer block the UI.** They are now asynchronous.
- **The search field's × now clears the results too.** It used to only empty the text, leaving the stale list on screen until the next search.
- **Browser cookie import only asks for YouTube cookies.** The one-click import used to pull every cookie from the browser's profile; it now scopes the request to youtube.com and music.youtube.com.
- **The detail screen "Shuffle" button now shuffles.** It used a play icon and the non-shuffled path.
- **Failed playlist-membership checks are surfaced.** They no longer silently show "not a member", which could otherwise add a duplicate.
- **Raw exception text is no longer shown in error boxes.** Failures map to short, plain sentences.
- **Menus and the pin gesture are labelled for accessibility.** The "More actions" menus and the pin/unpin long-press on Quick picks gained tooltips and screen-reader hints.
- **Switching tabs no longer leaves the search bar empty while results remain.** The search field now re-syncs with the stored query when returning to the Search screen, so the clear button is available again.
- **Tapping a top song on an artist page starts playback immediately.** The full playlist loads in the background instead of blocking the first note.
- **The song-info modal and Info tab are readable.** They now use the app theme instead of the default one.
- **Unsynced lyrics are readable.** They render in full white instead of dimmed gray.
- **Artist top songs now load on localized pages.** The "Top songs" shelf was matched by its English title only, so artists on non-English YouTube pages showed no top songs; the shelf is now chosen by its contents when the title doesn't match.

### Changed

- **Scrolling no longer evicts every cover.** The in-memory image cache was capped at 64 MB desktop, far too little once covers decoded at full resolution, so every home scroll dropped the older covers and scrolling back re-decoded the whole batch from disk; at 256 MB with tile-sized decodes, several hundred covers stay resident.
- **Tiles decode only what they show.** Every tile decoded its cover at full resolution (a 1080px cover is ~4.6 MB of bitmap for a box a few hundred pixels wide), paying the cost again at every first paint; decodes are now sized to the space the tile actually paints (its own size, or the grid cell an expanding tile fills) in device pixels — proportionally, never upscaling past the file's own pixels — so scrolling paints a fraction of the bitmap data and holds far more covers in the same memory.
- **One artwork file per image, named for its format.** The cache kept a raw download (`.img4`) plus a rendered PNG per image; it now stores a single compressed (JPEG, quality 85) copy named after the format it actually holds (`.jpg`, `.png`), so integrations like MPRIS hand other desktop clients a normal image file. "Clear artwork cache" also drops the square-cover map.
- **The artwork cache prunes itself.** At startup, files older than 30 days are deleted (and re-download on demand if needed) and the cache is trimmed back under 512 MB, oldest first, so it can no longer grow without bound.
- **Search results build lazily.** Off-screen rows and their artwork now only load when scrolled into view instead of all at once.
- **Decoded artwork yields memory under pressure.** On OS memory pressure the in-memory image cache is emptied; the disk cache remains the real store.
- **The fullscreen lyrics player bar spans the full width.** It used to sit inside the screen padding like the lyrics above it.
- **Lyrics are fetched from both providers at once.** LRCLIB and YouTube Music are queried in parallel and both are cached, so switching the provider toggle is instant.
- **Lyrics load before the tab opens.** Every track start prefetches both providers into the session cache, whether or not the Lyrics tab is open, so the list is already there on the first open or after skipping back to a track played earlier.
- **Lyrics fail honestly.** When a provider comes back with nothing, the other provider's lyrics are shown instead of an empty screen; a network failure now reads "Couldn't load lyrics" with a Retry button rather than the same "No lyrics found" shown for tracks that simply have none.
- **Song titles use the rounded Google Sans Flex.** Track, shelf and now-playing titles now use the local variable font with its ROND axis at maximum; body and labels keep the standard cut for readability.
- **Info tab text is selectable.** Text in the Now Playing Info tab and the song-info modal can be selected and copied.
- **Artist matches show in the main search results.** An artist whose name matches the query now appears in the All view instead of only behind the Artists chip.
- **Artist pages use a collapsing banner.** The name sits over the banner with a gradient scrim and shrinks into the pinned app bar as you scroll; the back button comes from the bar with proper safe-area handling.
- **Artist actions have a clear hierarchy.** A prominent Play all button, with Shuffle and Mix as tonal icon buttons and Subscribe beside the subscriber count.
- **Artist pages cap their width on large screens.** Content is constrained instead of stretching edge to edge.
- **Artist bios expand in place.** The silent 600-character cut-off is replaced by a four-line preview with a Show more toggle.
- **Section headers are consistent.** "Top songs" and "About" share one header style with the See all action.
- **One playlist page for every way in.** The same playlist opened from a home shelf, a quick pick, a search result or an artist page used to show a different header, and sometimes a missing creator or count, than when opened from the library; every entry now opens the same page with the same title, creator, cover, subtitle and track actions, only playlists the account can edit offer rename, delete and track removal, and Back returns to the screen it was opened from.
- **Menus use Material 3 Expressive popups.** The three-dot menus in the Now Playing and Library headers and on track rows now open as Material 3 Expressive popup menus instead of the custom spring pill stacks.
- **Scrolling is smoother.** Lists, rails and the settings page now use the silky scroll behavior, so wheel and touch scrolling glide instead of stepping.
- **The Up next reorder handle appears on hover.** It used to sit on every row; it now springs in together with the row's ⋮ menu and hides when the pointer leaves.

## [0.3.0] — 2026-10-22

### Added

- **A first-run setup.** A fresh install opens with a short guided flow: what the app is, the sign-in (browser window, one-click import from the system browser, or a pasted cookie), and the choices that shape it (accent color, reduced motion, high contrast, Last.fm — with its sign-in right there). It is skipped for good once it is done, and an account that is already signed in never sees it.
- **The setup can be run again.** A "First-run setup" section at the bottom of Settings puts the guided flow back, so the welcome, the sign-in and the appearance choices can be walked through whenever you like.
- **A Last.fm token can be renewed in place.** The setup and the settings card now offer "Get a new token" while signing in, so an expired token no longer means leaving the settings and coming back to start the handshake over.
- **The credentials live in the platform secret store.** The YouTube cookie, the session token and the Last.fm credentials used to sit in a plain-text `auth.properties` next to the app settings; they now go to the platform's secret store (the keyring on Linux). The old file is migrated into the store on the first start and deleted — and if no keyring is available (no session daemon), the file stays as the fallback instead of losing the session.
- **The liked list says when it is short.** YouTube's playlist header counts every song of the playlist while its shelf only serves the ones it can render, so the library, the opened liked-songs playlist and the home list now say how many of the playlist's songs could be loaded ("500 of 524 songs loaded") whenever the two differ.

### Fixed

- **Switching tabs in the Now Playing view keeps the lyrics where you left them.** The tab page (and the lyrics list with it) is disposed when another tab is selected, so the list came back at the top; the scroll position now lives above the tab strip and is restored.
- **Reduce motion no longer breaks the scrolling.** A zero-length scroll animation is rejected by the framework, so the lyrics' follow-scroll and the rail arrows threw instead of moving; they jump now.

### Changed

- **One account card in the settings.** The account name and the sign-in live in the same card now, instead of two cards in two sections.
- **The settings file stays readable.** The app's caches (track credits, play counts, remembered recents, artist avatars) used to be stored as escaped JSON in `config.properties`; they now live in their own JSON files next to it, and the old properties are moved over on the first start.
- **One sign-in, no Data API.** The Google OAuth client (and the client id/secret it needed) and the YouTube Data API are gone; the browser-cookie session alone covers playback, listening history and the whole library. Playlists, liked songs, recent activity and followed artists, and every write on them (create, rename or delete a playlist, add or remove a track, subscribe), now run over InnerTube.
- **The liked songs' card and page show YouTube's own cover.** The app fetches the liked-music playlist's artwork and uses it both for the library's "Liked songs" card and for the opened playlist, which used to paint a mosaic of the first songs instead of the playlist's own cover.
- **The liked songs show up once.** The library's third tab and the feed's "Liked Music" card only repeated the liked list the home already shows in its own column, so both are gone.
- **Long lists load in full.** The liked-songs list, the playlist tracks and a playlist opened from home are served one shelf page at a time, so the app follows each list's own continuation: the whole liked-songs list loads instead of the first 25, and a long playlist shows every song instead of the first 100, each row keeping the running time the shelf shows next to the title.
- **The liked-songs list is YouTube's "Liked Music" playlist, in like order.** The list is the playlist the YouTube Music sidebar links to as *Liked songs* — and nothing else, so every row is a song that playlist holds — read in the playlist's own "Newest first" order, so it runs newest-like first like the old Data API list did (the first paint included, not just the full reload). The library reports the playlist's own count from its header ("524 songs"), the way YouTube Music does, and every row keeps the running time the shelf shows next to the title. The walk follows the shelf's continuation to its end, and a page that comes back with fewer rows than the others is fetched once more, so a short response cannot silently drop songs.

## [0.2.2] — 2026-10-18

### Changed

- Discord Rich Presence artwork now center-crops video thumbnails: `discordArtwork` rewrites any googleusercontent `=w-h` URL to `=w540-h540-l90-rj`, forcing YouTube's image server to center-crop non-square (4:3 / 16:9) video thumbnails instead of sending no cover art at all. Previously only already-square artwork was sent, so videos with no square thumbnail showed no Discord cover.
- Home shelves no longer repeat mixes: mixes lifted into "Albums made for you" are filtered out of leftover shelves, so a mood/playlist shelf no longer shows the same cards twice.
- Home section spacing is now even: all home sections are separated by a consistent vertical gap (`homeSectionSpacing`) instead of mixed 12/16/20px gaps.
- Hide the "Liked songs" shelf from home leftovers: the app already shows its own liked songs list in the personal block, so the feed's "Liked songs" Auto Playlist shelf is filtered out instead of appearing twice.

## [0.2.1] — 2026-10-18

### Added

- Lazy load-more for home rows: shelves that carry a continuation token get a "Load more" action under the row; tapping it fetches the next page and appends it to the shelf in place.

### Changed

- Home shelves no longer repeat mixes: mixes lifted into "Albums made for you" are filtered out of leftover shelves, so a mood/playlist shelf no longer shows the same cards twice.
- The app version/build (`NixieTube 0.2.1+N`) is embedded at compile time via `--dart-define=APP_VERSION` and shown at the bottom of Settings, instead of hardcoded text. CI derives it from `pubspec.yaml`.

### Fixed

- The Last.fm session survives a restart: `LastFmService` never refreshed its in-memory status after construction, so on every app launch it reported "disabled" even though the session key was persisted — the settings card showed the login UI and asked to log in again. The constructor now calls `refreshStatus()`, so a stored session key is picked up immediately.

## [0.2.0] — 2026-10-18

### Added

- Durations now show in the Up-next list for unplayed tracks: the signed-in queue pass stamps lengths from the per-row watch-next read it already makes (zero extra requests).
- `explore()`, `charts()` (country plus the worldwide Top 100), `historySnapshot()`, and `watchInfo`/`watchInfos` — one watch-next read that returns the like state and every queue-row length it carries.
- Home is organized into fixed sections — personal picks and Jump back in, Discover, Listen Again, Forgotten favorites, New releases, Albums made for you, `Trending in <country>` and `Trending globally` — with a multi-column `TrackColumns` rail and a ranked quick-picks pool seeded from watch history and deduped by artwork.
- `explicit` flags parsed from `MUSIC_EXPLICIT_BADGE`, shown in the player bar, track rows and rail cards.

### Changed

- Covers now render whole: no client-side center-crop and no letterbox-bar trimming. Square tiles use YouTube's own square art (or the fetched album cover) and cover-fit the frame; a video still is only cropped when no square art exists for it.
- `maxResGuess` prefers the 1280×720 `maxresdefault` still, error pages are rejected, and square-cover resolution checks the watch-next row's own last thumbnail first, falls back to album art, and never condemns a track for the session on a transport blip or a throttling error body.
- Soft thumbnails fixed: tiles decode at the render's own pixel size (short side × device pixel ratio) so the cover fit no longer upscales a 16:9 frame into a blurry square. The size is read from the PNG header, never a full decode.
- The player refuses to open a stream when the startup probe finds mpv missing instead of spinning until the play timeout; session restore runs on a worker isolate so a large saved queue never stalls startup.
- Bulk `updateTrackDurations`/`updateTrackMetadata` restamp queue rows in one emission.
- Discord is now pure Dart: a small IPC client (`lib/sys/discord_ipc.dart`) replaces the Rust-bridge-backed package: no `flutter_rust_bridge`, no cargokit native library, and nothing to download at build time.
- Because we own the socket there is no one-shot client singleton any more: changing the application id takes effect immediately, a failed connect can't leave a half-built client behind, and the presence recovers from a restart instead of requiring one.
- Selectable status line: App Name, Song Title, Song Artist or Song Album, persisted across launches.
- MPRIS uniform periodic retry loop (fixed 10 s, injectable for tests) instead of a backoff ladder that could give up. A name held by another instance is retried rather than abandoned, a dropped connection is re-claimed via a liveness ping, and repeated failed connects no longer leak artwork stores.
- Shared HTTP client gained a retry interceptor for transient statuses and transport failures (honouring `Retry-After`) plus per-host connection caps; `post()` degrades gracefully on a sustained outage instead of throwing a raw exception into the UI.
- Track metadata, play counts and artist avatars are cached across launches.
- Theme remembers the system accent color; settings gain an "Underline links" toggle and order Google OAuth before the cookie sign-in.
- `systemd-inhibit` sleep lock held while playing, released on pause/stop/quit and by the child process if the app ever dies.
- The release job checks out the repository, so it can read the changelog.
- Release notes are taken from the matching section of `CHANGELOG.md` instead of being generated from commit messages; a missing section fails the release rather than shipping an empty one.

### Fixed

- A stream that dies mid-playback now recovers: the backend's own error event was never wired up, so the whole retry/backoff path was unreachable — a refused stream just stopped with nothing to say why. Engine errors now reach the controller, which re-resolves under a fresh visitor and resumes where it left off, restarts the backend stack once as last resort, and otherwise reports the backend's real reason instead of a blanket failure. Hung opens time out at 20 s instead of spinning forever.
- State delivery is re-entrancy safe: `_update` broadcasts synchronously to listeners, and a listener (`AppState._onPlayerState` → `_stampQueueMetadata` → `updateTrackRatings`) could call back into `_update` mid-delivery, crashing with `Cannot fire new event`. Nested updates are now deferred to a microtask instead of re-entering the broadcast controller.
- A lost IPC link recovers on its own: Discord refuses a new handshake for roughly half a minute after a session ends, so the old fixed 10s retry only ever landed inside that window and the presence stayed dead for the rest of the run — the status line then looked frozen no matter what you picked. Retries now back off, waiting out the window before probing again.
- Teardown follows the protocol: the session is closed with the CLOSE opcode rather than a `{"cmd":"CLOSE"}` frame, which Discord rejects with `4000 Payload requires a nonce`. Frame reassembly and the handshake completer now belong to a single session, so a reply still in flight from a closing socket can no longer be mistaken for the next connection's answer.
- The status line is sent as the activity's `name`: Discord fills that field in with the *application* name when it is missing — confirmed on the live client, which answers an activity sent without one with `"name":"NixieTube"` — so the picker had no visible effect until the choice went on the wire. The song and its artist stay on the two lines below it.
- Connection failures report the real cause (`error: Invalid Client ID`, `no Discord IPC socket reachable`, `no READY from Discord`) instead of a bare "idle".
- Disabling and re-enabling the presence works again: the presence re-initializes and reconnects; the retry timer re-pushes the current activity after a drop.

## [0.1.1] — 2026-10-12

### Added

- Desktop release of the Flutter client: playback with queue, shuffle, prefetch and radio, library and likes, search, lyrics, artwork tiles, MPRIS media keys, Discord Rich Presence, system tray, Last.fm scrobbling, and sign-in via Google OAuth or browser cookies.

## [0.1.0]

### Added

- First release of the Flutter port of NixieTube.

[0.2.2]: https://github.com/gregorio/nixietube/compare/v0.2.1...v0.2.2 [0.2.1]: https://github.com/gregorio/nixietube/compare/v0.2.0...v0.2.1 [0.2.0]: https://github.com/gregorio/nixietube/compare/v0.1.2...v0.2.0 [0.1.1]: https://github.com/gregorio/nixietube/compare/v0.1.0...v0.1.1 [0.1.0]: https://github.com/gregorio/nixietube/compare/8eb0b5a...v0.1.0
