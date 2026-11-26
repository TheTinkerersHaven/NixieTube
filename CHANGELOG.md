# Changelog

All notable changes to NixieTube are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.0] — Unreleased

### Added

- **Android signs in without pasting a cookie.** The app now opens the YouTube Music sign-in page inside itself and reads the session back with one tap — including the HttpOnly cookies that actually authenticate — instead of sending the user to a computer to copy a header by hand.
- **Playback survives the screen locking on a phone.** Android and iOS now register a media session with the system: a notification showing the song, the artist and its cover with play/pause and skip, lock-screen controls, and the transport buttons on Bluetooth and wired headsets. Until now a backgrounded app was suspended and the music stopped.
- **The playback notification can like the song.** On a phone the media notification gains a like button — tap it again to unlike — using the same rating as the player, so a song can be saved without opening the app.
- **Albums and playlists open with a glass hero card on a phone.** The top of an opened album or playlist is a 20dp-radius translucent glass card at 16dp margins with a hairline white border: a 120dp cover rounded to 12dp on the left, and to its right the 20sp bold title, a 22dp artist avatar row and the "Album • 20 songs • 54 min" meta line, followed by two equal-width 44dp stadium buttons (filled Play, tonal Shuffle) and a compact tracklist header with the song count on the left and a 32dp "Sort" pill on the right.
- **Search filters and autocomplete, the way YouTube Music does them.** The Songs / Albums / Artists chips now send YouTube Music's own server-side filter `params`, so each category is ranked and complete from the server instead of being carved out of the "All" response, and typing in the search box shows live InnerTube suggestions above the recent searches.
- **Search shows a best match card.** The unfiltered search now surfaces the top-result card shelf as a prominent "Best match" card above the categories — the entity parsed from the card itself (song with artist, album and duration, or an artist/album/playlist), tap to play or open, press-and-hold for its menu — instead of only folding its rows into the category lists. When the card links to a music video, the audio-only recording of the same title is preferred, so playback and ratings land on the song.
- **Overflow menus are reachable by touch on phones.** List items opened their menus only from a hover-revealed ⋮ button or a right-click — neither exists on a touch screen, so the menus were unreachable. Press and hold a track row, quick-pick tile or card now opens the same menu at the press point.

### Fixed

- **The album and playlist background wash no longer collapses to black once loading finishes.** The cover-tinted gradient is now sampled from the artwork URL the page actually shows, re-requesting when that URL changes as tracks load, instead of only sampling the URL known when the panel first mounted — so on phones the gradient keeps showing after the skeletons are done rather than turning solid.
- **The Last.fm scrobbling row is named by what it does.** It now reads a single "Scrobble to Last.fm" toggle, matching ListenBrainz's "Scrobble to ListenBrainz", instead of a separate "Last.fm" heading above a "Scrobble plays" switch.
- **Rail cards no longer overflow their fixed height by a pixel.** Track and browse rail cards on phones shrank their cover slightly and let the text block flex, so a two-line title can't push the card past the rail's fixed height (the yellow-black overflow stripe) at any text scale.
- **The dislike button sits evenly in a track row.** It carried its own asymmetric padding, leaving its icon 8dp from the row's edge where every other trailing control sits 12dp; it now matches them.
- **Opening the app through a deep link no longer crashes the navigator.** A cold start via an external link used to throw "Could not find a generator for route"; unknown routes now render home for a frame and are dropped instead.
- **The "System" color source subtitle matches the platform.** It now says the accent comes from wallpaper colors on Android and notes that iOS reports no system accent, instead of only mentioning the desktop's XDG portal / GTK theme.
- **Prefetch work can no longer interrupt playback teardown.** Cancelling or disposing a prefetch now invalidates timer and resolver work, preventing stale background updates from reaching the debug UI.
- **Manual cookie import in Settings keeps its input and signs in.** Pasting a cookie into the Settings account card and pressing "Sign in" previously wiped the text field and failed to log in because the segmented list wrapper re-instantiated the card on focus changes.
- **Age-restricted songs play when signed in.** The stream resolver now solves YouTube's signatureCipher — and the throttling `n` parameter — for the tracks only WEB_REMIX answers, so they no longer fail. It solves them from a copy of the player script the project has already solved and published, keeping that copy for later plays, so the song starts at once instead of after the script is parsed on the device.

### Changed

- **Quick picks show a mobile 3x3 layout and cleaner navigation cues.** On phones, nine picks form a tight segmented grid with rounded external corners; song tiles no longer display a navigation arrow, while artist and album tiles keep the cue that they open another page.
- **The player now follows the album-cover-led layout.** Mobile and desktop Now Playing now show the playlist, album, mix, radio or shelf queue that started playback, including Quick Picks and Liked Songs, instead of inferring a source from the current track.
- **Phone track rails use single-line cards, evenly spaced.** Mobile covers are a little larger and sit closer together, the rails take less vertical space around the header and their neighbours, and every card is the same height: one line of title right under the cover, one line of subtitle right under it — no card drags its rail taller, and no reserved line opens a hole between the texts.
- **Playback uses native InnerTube client fallbacks.** Stream resolution now uses the signed-in WEB_REMIX and cookie-oriented TVHTML5 profiles before VISIONOS and Android VR fallbacks, replacing the yt-dlp subprocess and cookie-file handoff with direct Dio player requests.
- **Song info closes when you follow a link.** Opening an artist or album from the Now Playing info sheet (or from the song-info dialog) no longer leaves the sheet or dialog covering the page it opens.
- **Playback starts sooner.** The YouTube visitor id the stream URLs need is fetched while the app starts instead of on the first play, and the next song's stream is resolved as soon as the current one begins, so pressing next no longer waits on a resolve.
- **Phone and tablet player bars drop the volume slider.** Android and iOS builds no longer draw it in the player bar or the Now Playing transport, where the hardware volume keys already do the job; desktop keeps it.
- **Leaving fullscreen lyrics returns to the Lyrics sheet.** On a phone, exiting fullscreen lyrics (with the button or the back gesture) brings the Now Playing sheet back on the Lyrics tab instead of dropping the reader on the plain player view.
- **The artist banner fades into the background on phones.** The mobile scrim now fades the banner out earlier and holds the last stretch at the page colour, so the image's bottom edge no longer shows as a cut above the title.
- **The album page's top bar no longer duplicates the hero title on a phone.** The 56dp app bar hides the album title while the hero card is visible and fades it in over the first ~100dp of scroll, keeping the 40dp circular tonal overflow button on the right.
- **Album track rows on a phone no longer repeat the album.** Rows inside an opened album drop the cover thumbnail and the "• album name" subtitle, keep a fixed 28dp track index with the duration folded into the subtitle, and — like every other list — keep the like and dislike toggles; the row's left padding now matches the trailing buttons' own icon inset so the row reads evenly left to right.

- **Album and playlist pages animate like Settings.** Opening a detail page from another detail page (artist → album) or opening a playlist from the library now uses the same push animation instead of appearing instantly.
- **Quick picks use the whole grid.** Pinned picks count toward the grid's slots, and the first row sits closer to the "Quick picks" title.
- **Phone rails use the artist page's smaller cards.** Every home section now fits the same compact cards and gap as the artist page rails, and song-only shelves show those cover rails instead of the sideways row lists.
- **Artist top songs read better on phones.** The duration moves into the artist line and the play-count column drops out, so long titles keep their width and the rows pack tighter.
- **The library title lines up with its content.** On a phone the title now shares the playlist cards' left gutter instead of hugging the screen edge.
- **The mini player sits above the phone's navigation bar.** The bar is shorter and its surface now ends under the player card instead of running behind it, and the library's new-playlist button floats above the player rather than hiding beneath it.
- **Discord Rich Presence works on Android via the official Social SDK.** The app now ships Discord's `discord_partner_sdk.aar` and publishes presence through the installed Discord app's own RPC service (the `com.discord.socialsdk.rpc.IDiscordRpcService` AIDL interface) — no OAuth, no token, no deep link: the application id alone is enough. Desktop keeps using the local IPC socket; MPRIS stays desktop-only. (iOS needs the SDK's xcframework, which is not vendored, so the toggle stays off there.)
- **The artist bio sits between the top songs and the rails on a phone.** The About panel follows the top-song list directly, so it isn't buried under the album, single, related-playlist and similar-artist carousels, while a wide window keeps it beside the songs as before.
- **The artist page on a phone packs its content tighter under a shorter hero.** The collapsing banner stays but shrinks from ~45% to ~34% of the screen height, and everything below it is compacted: Play, Shuffle, Mix and Subscribe (when signed in) now sit in a single connected M3E button group instead of a horizontally scrolled button row, top-song rows keep their cover thumbnails with a fixed index, and the bio sits right after the songs instead of under all four rails.
- **The phone mini player gains a previous button.** The bar now carries previous beside play/pause and next, so stepping back a track no longer means opening Now Playing first.
- **The player bar under phone lyrics drops the volume button.** Fullscreen lyrics drew the desktop bar on every screen, so a phone showed a volume control it has no use for — hardware volume keys do that job. The bar now follows the window width: the phone layout has three transport buttons and no volume, while a desktop window keeps the volume button and slider.
- **The scrobbling cards are named by what they do.** The Last.fm and ListenBrainz cards no longer repeat their service as a heading above a "Scrobble plays" toggle; each toggle now reads "Scrobble to Last.fm" or "Scrobble to ListenBrainz", so the two cards are told apart without the extra titles.
- **App updates point at the download page when a build cannot install them.** Only the Linux AppImage can replace its own binary, so any other build now offers "Download" on the update banner and a download-page button in Settings instead of an install button that could not do anything.
- **Closing the app on Android closes it for good.** Closing the app with the back gesture or swiping it away now stops playback and removes the media notification, so the notification panel ends in the same state a fully closed app leaves behind, instead of keeping the song playing with the notification still up.
- **Phone Settings uses the same structure as desktop.** The page now opens with the large "Settings" title aligned to the content gutter (with a back button when pushed), and every section group renders as an M3 Expressive segmented list — 24dp expressive outer radius, even 16dp inner padding — so rows align identically inside segments and standalone cards on phones and desktop alike; the App updates "Open the download page" and Setup "Run the setup again" buttons sit on their cards' trailing edge like the other row actions.

## [0.4.6] — 2026-11-18

### Fixed

- **Android builds now start from the app's own storage.** Config, cache and log directories use the platform app-support directory on Android/iOS instead of XDG paths under the read-only working directory.
- **Installed mobile builds can reach the network.** The internet permission now lives in the Android main manifest instead of only the debug one, and the macOS release entitlement allows outgoing connections, so login, the library and playback work outside a development run.
- **Songs leave the loading state when they start.** The playback engine reports playing as soon as the stream opens instead of waiting for the backend's play call to return at the end of the track, which kept the spinner up over already-playing audio and re-opened the stream mid-song.

### Changed

- **Phone layouts use dedicated mobile views.** Narrow windows and phone screens use dedicated views separated from desktop: a bottom navigation bar with a compact mini player, a full-screen Now Playing view with large artwork and drawer access to lyrics and queue, and vertically stacked album headers with full-width tracks; desktop preserves its rail and split views.
- **The phone views are tuned for the narrow screen.** Liked songs now live in the library's "Liked songs" playlist instead of taking a column on the home screen, the album sort options sit in two centered pairs so all four fit, Now Playing packs its cover, title and controls closer together, the Up next and Lyrics sheet keeps its rows off the screen edge, and fullscreen lyrics dismisses that sheet on the way in.
- **Phone screens opened on top of another screen can go back.** Settings now has a back button in its title bar, and Android's back gesture closes the phone overlays and pops the in-app stack (a detail page, an open playlist or Settings) instead of leaving the app; the bottom navigation keeps the section the screen was opened from highlighted, and tapping the library tab returns from an open playlist to the library list.
- **Phone spacing follows the smaller screen.** Headers sit closer to the status bar with a single-line title, the artist page's back button clears the status bar, the album header no longer adds a second inset inside the already-padded track list, and the Now Playing sheet keeps its last rows clear of the gesture pill.
- **The phone layout draws behind the system bars.** The status and navigation bars are transparent and the app fills the screen behind them, so the home gradient and the library and album washes run edge-to-edge; the bottom bar continues behind the gesture pill while its icons stay above it, and the Now Playing controls clear both bars.
- **Settings use M3 segmented lists.** Sections now render their controls as connected segments instead of separate cards with divider-separated rows; the Scrobbling section holds both services in one group.
- **Vivid cover colors no longer fight the accent.** The tinted backdrop now mutes and darkens saturated covers before blending them into the surface, so a bright red or yellow sleeve reads as a muted maroon or olive wash behind a blue accent; neutral and already-dark covers keep their color.

### Added

- **ListenBrainz scrobbling.** Settings now has a ListenBrainz card: enter the user token from listenbrainz.org/settings and plays are sent there alongside Last.fm, with the same half-track/4-minute threshold. The token lives in the platform secret store, not in the settings file.
- **Album info now includes MusicBrainz release data.** When MusicBrainz knows the release, the album panel adds its release date, label and country, and falls back to MusicBrainz's release type when YouTube Music doesn't classify the album.
- **Album and playlist cards have a right-click menu with shuffle.** Right-clicking an album or playlist card now opens Play, Shuffle, Open and Copy link, so a full album can be started in order or shuffled without opening the album page first; the same menu also lists the album's info.
- **The album info panel shows more than a description.** It now lists the album's year, release type, song count, total runtime and artist, and falls back to the Last.fm summary and genre tags when YouTube Music has no description; open it from the album page's ⋮ menu or a card's right-click menu. Opening it from a card shows a loading note while the album page is fetched, and the album is remembered so a second look is instant.

## [0.4.5] — 2026-11-17

### Fixed

- **Song info now fills in the year and like count.** Opening a song's info from a list, such as the home screen's liked songs, showed both as "Unknown" because list rows carry neither; the panel now resolves them from YouTube Music when it opens.
- **The now-playing artist line is centered and wraps.** Short artist lists line up with the centered title and album instead of starting at the left edge, and long lists wrap onto more lines rather than needing a sideways scroll to read.

### Changed

- **Titles use the font's default roundness.** The now-playing title, section headings and track titles no longer push the Google Sans Flex ROND axis to its maximum; at 50 the letterforms keep the font's intended shape instead of the exaggerated rounding.
- **The app honors the system "Reduce Motion" setting.** Animations and the loading shimmer now stop when the desktop's accessibility setting asks for reduced motion, in addition to the existing in-app toggle.
- **The lyrics tab keeps its two providers apart.** The LRCLIB and YT Music tabs now each fetch and show only their own lyrics, and one with nothing to show says "No lyrics available" instead of filling in with the other provider's lines; when LRCLIB has no lyrics for a track, the tab moves to YT Music by itself, leaving the saved preference alone.
- **The active lyric line stands out more.** It now swells a little larger and settles without the old spring-back wobble, while the surrounding lines use a lighter weight so the sung line is the only emphasized one.
- **Settings and listening history survive an interrupted write.** Everything the app saves to disk (preferences, recent plays, play counts, remembered credits and artwork) is now written to a temporary file and swapped in, so a crash or force-quit can no longer leave a half-written file that silently resets it; repeated plays of the same song also no longer show up twice in quick picks.

## [0.4.4] — 2026-11-10

### Fixed

- **Installing an update actually replaces the AppImage.** The updater looked for the file to replace at the running executable's path, which inside an AppImage points into the temporary mount, so an install finished without touching the real file; it now uses the file the AppImage runtime reports, and a download that is not a real AppImage binary is discarded instead of written over the working build.

## [0.4.3] — 2026-11-08

### Added

- **Configurable Discord pause-hide timeout.** The 15-minute default can now be set to 5, 10 or 15 minutes from the Discord settings dialog.
- **Diagnostic logs in a rotating file.** App diagnostics now go through a single logger that writes to the console and to a rotating file under the cache directory, replacing the scattered print and ad-hoc log files.

### Fixed

- **The update banner takes you straight to the update.** Its button used to land on the top of Settings, and the available version only appeared after pressing "Check for updates" again; it now opens Settings scrolled to App updates, where the release found at startup is already waiting, and the banner stays out of the way on that page and while an install runs.
- **A failed install now says so.** When the running build cannot be replaced (for example a plain `flutter run` build), the App updates card reports the failure instead of silently returning to the idle state.
- **Discord Rich Presence clears on quit.** Quitting the app now tells Discord to remove the presence (and disconnects the IPC link) instead of leaving it up for Discord's own stale-presence timeout; a flaky link during a pause no longer resets the 15-minute hide clock either.

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
