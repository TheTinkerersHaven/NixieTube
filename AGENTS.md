# NixieTube — agent operating rules

## Project overview

NixieTube is a native Linux desktop client for YouTube Music, built with Flutter (Dart). It plays music, manages your library (playlists, liked songs, followed artists, recent activity), shows lyrics, scrobbles to Last.fm, exposes MPRIS / Discord Rich Presence, and lives in the system tray. Distributed as an AppImage.

- **Auth:** one browser-cookie session (InnerTube) covers playback, history, likes and the whole library. Credentials live in the platform secret store (libsecret / keyring), never in a plain-text file.
- **Audio:** `just_audio` + `media_kit` (mpv backend) on Linux.
- **UI:** M3E (`material_ui`, `m3e_core`) with Material 3 (`useMaterial3: true`), dynamic color, Google Sans Flex font.
- **Network:** all calls via a shared Dio client with timeouts; resolved stream URLs cached 5 minutes; artwork cached on disk.
- **Update:** checks GitHub releases at startup, shows a dismissable banner, installs a new AppImage atomically (`<exe>.new` → rename).

## Where things live

```
lib/
├── main.dart                  App entry point, services, tray, themed root
├── theme.dart                 YTM-red seed scheme, dynamic color, radii
├── core/
│   ├── artwork/artwork_store.dart   Disk-cached covers
│   ├── innertube/                   InnerTube client: auth, library, browse, search, radio, ratings, lyrics, stream resolve
│   ├── models/models.dart           Track, shelf, playlist, detail models
│   └── player/                      Queue, shuffle/repeat/radio, sleep timer, session persistence, engines
├── sys/
│   ├── updater.dart           GitHub release check + atomic AppImage replace
│   ├── browser_cookies.dart   One-click cookie import from browsers
│   ├── browser_login.dart     Cookie payload helpers
│   ├── cache_store.dart       On-disk JSON caches
│   ├── discord.dart           Discord Rich Presence
│   ├── http_client.dart       Shared Dio factory
│   ├── lastfm.dart            Last.fm auth + scrobbling
│   ├── mpris.dart             MPRIS D-Bus interface
│   ├── paths.dart             XDG config/cache directories
│   ├── secure_store.dart      Credential store (platform keystore)
│   ├── sys_config.dart        Settings store + credential migration
│   ├── tray_icon.dart         Dynamic tray icon renderer
│   └── tray_service.dart      Tray menu, show/hide, quit
├── ui/
│   ├── app.dart               Single-window shell (rail, overlays, banners)
│   ├── app_state.dart         Central ChangeNotifier: nav, library, ratings, pins, recents, login sessions, update state
│   ├── theme.dart             Seed schemes, dynamic color, radii
│   ├── screens/               Home, library, search, detail, Now Playing, settings, first-run setup
│   └── widgets/               Artwork tiles, rails, cards, player bar, seek slider, dialogs, lyrics list
```

Key symbols:
- `AppState` (`lib/ui/app_state.dart`) — the central `ChangeNotifier`. Most UI reads go through `context.select<AppState, ...>`; writes go through methods on the state.
- `Updater` (`lib/sys/updater.dart`) — `checkForUpdates()` hits the GitHub releases API; `applyUpdate()` downloads to `<exe>.new` and atomically renames.
- `UpdateInfo` — data class returned by `checkForUpdates()`, carries `version` and the download URL.

## File editing

- Always modify files with the built-in `edit`, `write`, and `patch` tools.
- Never use sed, awk, perl, python, echo/cat redirection or heredocs to change files.
- Use bash only for running builds, tests, git, and read-only inspection.

## Git: the user owns commits, tags, and pushes

The agent must **never** commit, push, tag, or force-push on the user's behalf. All changes stay **uncommitted on the working tree** until the user explicitly asks to commit.

- `git commit`, `git tag`, `git push`, `git push --tags`, and any force-push are user-only operations.
- When the user does commit, sign-offs/gpg signing are handled by the user (`git -c commit.gpgsign=false` or their own signing setup); the agent must not add `-c commit.gpgsign=false` or otherwise circumvent the user's signing flow.
- **Never force-push remote tags.**
- Before any release: the user decides when the tree is clean, what goes into the commit, the tag name, and when to push.

## Code style & conventions

- Never hard-wrap prose. In Markdown and any text written for a reader (README, CHANGELOG, AGENTS, docs, and replies to the user), a paragraph or a bullet stays on one line; the renderer wraps it. Only `dart format` decides code line breaks, and comments follow the wrapping of the file around them.
- M3 (`useMaterial3: true`); M3E components throughout; no hardcoding user-facing content except explicitly requested section names.
- Keep resource usage minimal; verify via execution, not speculation.
- Check whether an existing dependency already implements a feature before hand-rolling it.
- Prefer `dart pub global run dartdoc` with 9.0.0 pinned for `dart doc`.

## Build, analyze, test

Before considering any work done:

```bash
flutter analyze          # must be clean (1 pre-existing info lint is OK)
flutter test             # all tests green
flutter build linux --release  # must succeed
```

- Bump the `+<num>` build in `pubspec.yaml` (`version: 0.4.1+N`) on every build; the build number must change whenever the binary changes so the version stays meaningful.
- When adding a user-facing feature, update `CHANGELOG.md` under `[Unreleased]` and bump the build number.

## Testing gotchas

- M3E buttons need `tapAt(getCenter(...))` in widget tests.
- Skeletonizer widget tests use bounded pumps — never `pumpAndSettle`.
- `testWidgets` fails on stray timers; the pending-timer check runs **before** `addTearDown`.
- Real `dart:io` futures never complete under `FakeAsync`; this suite uses real short delays in plain `test()` (no `fake_async`).
- `mockDio` builds on `newHttpClient()` so injected dios have no retry interceptor.
- A sandbox (a custom `SysConfig` path, as the tests use) must never touch the real keyring.

## Domain knowledge

- **Auth session:** cookie + SAPISIDHASH. `AuthSession.fromCookie(cookie)` parses it; `loginValid` is true when the saved cookie session still reads the library.
- **Stream resolution:** `StreamResolver` resolves playable URLs via yt-dlp; results are cached 5 minutes with TTL. Lookahead prefetches up to 3 tracks ahead.
- **AppImage updates:** `Updater.applyUpdate()` only replaces when running from an `.AppImage` path; local `flutter run` skips gracefully. The new binary takes effect on next launch.
- **Banner pattern:** banners live in `lib/ui/app.dart` as `_SessionBanner`, `_AudioBackendBanner`, `_UpdateBanner`. Each reads its visibility via `context.select` and is dismissed via `AppState.dismiss*Banner()`, which also must be read via `context.select` so Provider rebuilds the banner when the flag flips.
- **Square thumbnails:** must use YouTube's own square art — no client-side auto-crop and no bar trimming; the artwork store never crops (whole-frame decode).

## Writing the changelog

`CHANGELOG.md` is what users read: CI publishes the section for the released version as the GitHub release body. It records the difference between the last release and this one — not the work it took to get there. `0.3.0` is the reference for both format and tone.

### Format

- One heading per release: `## [<version>] — YYYY-MM-DD`, with the version from `pubspec.yaml` before the `+` and an em dash before the date (`## [0.3.0] — 2026-10-22`). The heading must keep that exact `## [<version>]` shape.
- Group the entries under `### Added`, `### Fixed` and `### Changed`, only the groups that have entries, in that order.
- Each entry is one bullet of the form `- **A short sentence saying what changed.** What the app did before, or why it matters now, in one or two sentences.` The summary is bold and ends with its period; the explanation is plain text.
- One bullet is one line. Never hard-wrap a bullet to fit a width: wrapping turns the rest of it into a stray paragraph, and the extracted release notes lose it.
- A blank line separates the heading from its list and one group from the next.

### CI extraction

CI (`.github/workflows/build.yml`) copies the release body with `awk`: it starts capturing at the line matching `## [<tag version>]` and stops at the next line starting with `## [`. So:

- The version in the heading must match the git tag exactly (`v0.3.0` → `## [0.3.0] …`); never include the build number there.
- Inside a release section use only `###` headings — any other `## ` line ends the capture early.
- The section must not be empty, or the release job fails.

### Content

- Write for the app's user, not the developer: what the app now does, and what it did before when that is the change.
- One change, one bullet. Merge a change that lands in several places into a single entry ("the card and the page show the cover") instead of one bullet per screen, and describe a replaced subsystem as one change rather than one bullet per removed part.
- Describe the net change of the release. While a version is unreleased, a bug in a feature added in that same version is not a `Fixed` entry: the release ships the feature working, so the bullet says what it does now. Never write "the toggles work" or "the buttons no longer crash" about something introduced in this section — only changes against the previous release belong here.
- `Added` is a new capability; `Changed` is existing behavior that now works differently, including removals ("…is gone"); `Fixed` is a bug that shipped in a released version.
- No entries for tests, refactors or dependency bumps unless the app behaves differently because of them. File paths and private symbols belong in the commit, not in the changelog.
- Every bullet must be true of the code being released and verifiable in the diff — no plans, no "will".
- Do not repeat a bullet from an earlier release; if this release refines it, say what is new.

## When the user says "release"

1. The user reviews the diff and decides what is included.
2. The user commits (signed as they prefer).
3. The user tags (e.g. `v0.1.x`) and pushes; the agent may be asked to draft release notes but must not execute the push or tag itself.