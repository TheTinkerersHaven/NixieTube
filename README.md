<p align="center">
  <img alt="NixieTube" src="assets/icon/nixietube.png" width="200">
</p>

<p align="center">A YouTube Music desktop client for Linux — playback, library, quick picks and lyrics, in a Material 3 Expressive interface.</p>

<p align="center">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47-FF0000?style=flat-square&logo=flutter&logoColor=white">
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.13-FF0000?style=flat-square&logo=dart&logoColor=white">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-Linux-FF0000?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-FF0000?style=flat-square">
</p>

<!--
The repository is private, so shields.io cannot read it: badges that query the GitHub API render as "repo not found" until it is made public. Uncomment these once it is:

  <img alt="Release" src="https://img.shields.io/github/v/release/TheTinkerersHaven/NixieTube?style=flat-square&color=FF0000">
  <img alt="Build" src="https://img.shields.io/github/actions/workflow/status/TheTinkerersHaven/NixieTube/build.yml?style=flat-square&color=FF0000">
-->

---

## Get the app

Grab the latest build from the [Releases page](https://github.com/TheTinkerersHaven/NixieTube/releases/latest):

| Platform | Download |
|----------|----------|
| Linux    | `NixieTube-<version>-x86_64.AppImage` — make it executable with `chmod +x`, then run it |

## Using NixieTube

**Signing in.** One sign-in covers everything: a browser-cookie session unlocks playback, listening history and the whole account library (playlists, liked songs, recent activity, followed artists). Press **Log in with browser**, sign into Google in the login window (consent, 2FA and passkeys all work there), then press the floating **I've signed in** button inside that window — or open YouTube Music in your own browser and use **I've signed in — import now**. A manual cookie paste is available as a last resort. The session (cookie, session token and the Last.fm credentials) is kept in the platform secret store — the keyring on Linux — not in a plain-text file.

**First start.** A fresh install opens with a short setup: what the app is, the sign-in, and a few choices (accent color, reduced motion, high contrast, Last.fm). **Skip setup** ends it for good, an account that is already signed in never sees it, and **Settings → Setup** puts it back whenever you want a walkthrough.

**Listening.** The home screen opens on your quick picks and liked songs, then mixes, discover and shelves. **Long-press** a quick-pick tile to pin it to the front. Everything you play moves to the head of recent activity, so picks stay fresh; they also survive restarts ahead of the server history.

**Your library.** The library holds your playlists, the artists you follow and the songs you liked — the liked list straight from YouTube's own "Liked Music" playlist, newest like first, with the count YouTube reports for it.

**Sleep timer.** On the Now Playing screen, open the ⋮ menu and pick **Sleep timer**: 15/30/45/60 minutes, end of track, or end of queue. The header menu entry shows the remaining time while armed.

**Tray.** Closing the window hides the app to the tray instead of quitting — playback keeps going. The tray menu has transport controls, Show/Hide and Quit; the tray (and window) icon is the 4-sided M3E cookie re-rendered in your theme colors.

**Scrobbling & integrations.** Last.fm scrobbling, Discord Rich Presence and MPRIS (media keys, `playerctl`) live under **Settings → Desktop integrations**. Listening-history reporting to YouTube is a separate toggle under Playback.

**Covers.** Artwork is cached on disk (raw downloads plus rendered crops) with integrity checks. If covers ever look stale, **Settings → Debug → Clear artwork cache** re-fetches everything from scratch.

---

## Building from source

### Prerequisites

- Flutter SDK `^3.47.0`

On **Linux**, install the build and runtime dependencies:

```bash
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libsecret-1-dev file \
  libwebkit2gtk-4.1-dev libsoup-3.0-dev libayatana-appindicator3-dev
```

`libwebkit2gtk`/`libsoup` back the embedded Google-login window; `libayatana-appindicator` backs the tray icon; `libsecret` is the library the credential store links against.

The saved session also needs a running [Secret Service](https://specifications.freedesktop.org/secret-service/) backend — `gnome-keyring` (with the `secrets` component) or `kwallet`/`ksecretd`. Desktop sessions normally start one for you. Verify the backend is reachable:

```bash
# Should print a stored value (round-trip test)
echo "test" | secret-tool store --label=test app nixietube_test
secret-tool lookup app nixietube_test
secret-tool clear app nixietube_test
```

### Run

```bash
flutter pub get
flutter run -d linux
```

### Build

```bash
flutter build linux --release
```

Tagged builds additionally produce an AppImage (see *Releases* below).

### Tests and docs

```bash
flutter analyze
flutter test
dart pub global activate dartdoc 9.0.0
dart pub global run dartdoc --output doc/api .
```

> `dart doc` with the bundled SDK crashes inside dartdoc itself
> ([dart-lang/dartdoc#4180](https://github.com/dart-lang/dartdoc/issues/4180));
> the pinned 9.0.0 release generates cleanly. Doc generation is
> configured in [dartdoc_options.yaml](dartdoc_options.yaml).

## Configuration

Compile-time options, set with `--dart-define`:

| Define       | Default             | Purpose |
|--------------|---------------------|---------|
| `APP_VERSION` | `0.0.0+unknown`     | Version shown in Settings; CI derives it from `pubspec.yaml` |

```bash
flutter run --dart-define=APP_VERSION=0.3.0+1
```

## Architecture

Everything the app needs from YouTube comes over one InnerTube session: the browser cookie is the only credential, and it is read from the platform keyring at startup. Playlists, the liked list and the writes on them all go through that one client.

```
lib/
├── main.dart                  App entry point, services, tray, themed root
├── theme.dart                 YTM-red seed scheme, dynamic color, radii
├── core/
│   ├── artwork/artwork_store.dart   Disk-cached covers: letterbox strip, center-square crop, banner renders
│   ├── innertube/auth_session.dart  Cookie + SAPISIDHASH session
│   ├── innertube/account_library.dart  Account library over InnerTube: playlists, likes, activity, writes
│   ├── innertube/inner_tube.dart    InnerTube client (cookie): browse, search, radio, ratings, square covers
│   ├── innertube/json.dart          JSON navigation helpers
│   ├── innertube/lyrics.dart        LRCLIB + YTM lyrics providers
│   ├── innertube/metadata.dart      Credit/owner/kind normalization
│   ├── innertube/parse.dart         Response parsers, shelf ranking, quick-picks fill, cookie helpers
│   ├── innertube/stream_resolver.dart  Playable URL resolution
│   ├── models/models.dart           Track, shelf, playlist, detail models
│   └── player/
│       ├── player_controller.dart   Queue, shuffle/repeat/radio, sleep timer, session persistence
│       ├── player_engine.dart       Audio backend abstraction
│       ├── just_audio_player_engine.dart  just_audio backend
│       └── player_state.dart        Immutable playback snapshots
├── sys/
│   ├── browser_cookies.dart     One-click cookie import from browsers
│   ├── browser_login.dart       Cookie payload helpers (pure, tested)
│   ├── cache_store.dart         On-disk JSON caches (credits, counts)
│   ├── discord.dart             Discord Rich Presence client
│   ├── http_client.dart         Shared Dio factory (timeouts, status)
│   ├── lastfm.dart              Last.fm auth + scrobbling
│   ├── mpris.dart               MPRIS D-Bus player interface
│   ├── paths.dart               XDG config/cache directories
│   ├── secure_store.dart        Credential store (platform keystore)
│   ├── sys_config.dart          Settings store + credential migration
│   ├── tray_icon.dart           Dynamic 4-sided-cookie icon renderer
│   └── tray_service.dart        Tray menu, show/hide, quit
└── ui/
    ├── a11y.dart                High-contrast / reduced-motion helpers
    ├── app.dart                 Single-window shell (rail, overlays)
    ├── app_state.dart           Central ChangeNotifier: nav, library, ratings, pins, recents, login sessions
    ├── theme.dart               Seed schemes, dynamic color, radii
    ├── screens/               Home, library, search, detail, Now Playing, settings, first-run setup
    └── widgets/               Artwork tiles, rails, cards, player bar, seek slider, dialogs, lyrics list
```

Playback state flows one way: `PlayerController` emits immutable `PlayerState` snapshots; `AppState` mirrors what the UI needs and the screens select narrow slices of it, so progress ticks never rebuild the tree. Heavy work (decodes, JSON, session saves) runs on isolates; network calls are all bounded with timeouts.

## Releases

The app version is centrally managed in `pubspec.yaml` (`version: <build-name>+<build-number>`); git tags track the build-name as `v<build-name>`. The changelog lives in [CHANGELOG.md](CHANGELOG.md).

1. **Bump `pubspec.yaml`**, build-name and `+N` alike.
2. **Run the Release workflow** (`Actions` → `Release` → manual) — it reads the version, creates and pushes tag `v<build-name>`, and triggers the `Build` workflow. Or tag manually (`git tag v1.2.3 && git push origin v1.2.3`); never force-push a remote tag.
3. The `Build` workflow analyzes, verifies tag↔pubspec agreement, builds the Linux bundle plus AppImage, and publishes a GitHub Release.

## Credits

NixieTube stands on the shoulders of:

- [Flutter](https://flutter.dev) — UI framework (BSD-3-Clause)
- [YouTube Music](https://music.youtube.com) InnerTube APIs — unofficial API surface; all trademarks belong to Google
- [LRCLIB](https://lrclib.net) — synced/plain lyrics
- [M3E (`m3e_core`, `material_ui`, `motor`)](https://pub.dev/packages/m3e_core) — Material 3 Expressive components, shapes and springs
- [just_audio](https://pub.dev/packages/just_audio) + [media_kit](https://pub.dev/packages/media_kit) (`just_audio_media_kit`, `media_kit_libs_linux`, mpv) — audio playback
- [desktop_webview_window](https://github.com/MixinNetwork/flutter-plugins) (Apache-2.0) — embedded login window
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — the platform keyring the session is kept in
- [tray_manager](https://pub.dev/packages/tray_manager) / [window_manager](https://pub.dev/packages/window_manager) — tray icon, window controls
- [flutter_discord_rpc](https://pub.dev/packages/flutter_discord_rpc), [dbus](https://pub.dev/packages/dbus), [dynamic_color](https://pub.dev/packages/dynamic_color), [google_fonts](https://pub.dev/packages/google_fonts), [skeletonizer](https://pub.dev/packages/skeletonizer), [url_launcher](https://pub.dev/packages/url_launcher), [path_provider](https://pub.dev/packages/path_provider), [provider](https://pub.dev/packages/provider), [dio](https://pub.dev/packages/dio), [crypto](https://pub.dev/packages/crypto), [image](https://pub.dev/packages/image), [flutter_rust_bridge](https://pub.dev/packages/flutter_rust_bridge)
- [Metrolist](https://github.com/MetrolistGroup/Metrolist) (GPL-3.0) — inspiration for preferring the API's own square crops
- [AppImage](https://appimage.org) (`appimagetool`) — Linux distribution

## License

MIT — see [LICENSE](LICENSE).
