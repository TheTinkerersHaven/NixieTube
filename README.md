

<div align="center">
  <img alt="NixieTube" src="assets/icon/nixietube.png" width="200">
  <br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icon/NixieTube-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/icon/NixieTube-black.svg">
    <img alt="NixieTube" src="assets/icon/NixieTube-black.svg" height="40">
  </picture>

  <br>
  <p>A Material 3 Expressive YouTube Music client for desktop and mobile.</p>

  [![Flutter](https://img.shields.io/badge/Flutter-Dart-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
  [![Design](https://img.shields.io/badge/UI-Material%203%20Expressive-6750A4)](#expressive-design--theming)
  [![Platforms](https://img.shields.io/badge/Platforms-Linux%20%7C%20Android-2E7D32)](#installation)
  [![Releases](https://img.shields.io/github/v/release/TheTinkerersHaven/NixieTube?label=Release)](https://github.com/TheTinkerersHaven/NixieTube/releases)

  <!-- Replace with actual screenshots once captured -->
  <!-- ![NixieTube Showcase](docs/screenshots/hero.png) -->
</div>

NixieTube is a native YouTube Music client built with Flutter and **Material 3 Expressive**. Designed to feel equally at home on a Linux desktop and in one hand on mobile, it pairs direct InnerTube streaming with deep desktop integrations, live cover-art theming, synced lyrics, and scrobbling—without wrapping a browser tab.

## Highlights

### Playback & Library
- **Direct InnerTube Integration:** Stream music, browse home/explore rails, view artist pages, and access your YouTube Music library, playlists, and subscriptions.
- **History & Ratings Sync:** Reports watchtime beacons (toggleable) so plays appear in your YouTube history, alongside real-time like/dislike syncing.
- **Queue & Radio:** Drag-and-drop queue reordering, swipe-to-remove with undo, autoplay, and one-tap **Radio** / **Artist Mix** station generation.
- **Sleep Timer:** Stop playback after a set duration (15, 30, 45, or 60 minutes), at the end of the current track, or at the end of the queue.

### Expressive Design & Lyrics
- **Material 3 Expressive UI:** Built with M3E components, morphing loading indicators, skeleton placeholders, and adaptive layouts that shift seamlessly between wide desktop panes and gesture-driven mobile sheets.
- **Live Palette Backdrops:** Extracts colors from the active cover art to paint an animated ambient wash behind Now Playing.
- **System & Custom Theming:** Follows your desktop accent color automatically (via XDG Desktop Portal / GTK on Linux) or builds a scheme from a custom seed with per-role overrides (`Primary`, `Secondary`, `Tertiary`, `Surface`).
- **Synced & Fullscreen Lyrics:** Switch between multiple lyrics providers, follow time-synced lines automatically, or expand into a distraction-free fullscreen lyrics view.

### Desktop & Social Integrations
- **MPRIS Media Controls (Linux):** Exposes playback state, metadata, and media keys over the D-Bus session bus (`playerctl`, desktop widgets, hardware keys).
- **Discord Rich Presence:** Displays what you are listening to with a customizable status line (app name, track title, artist, or album), configurable pause-hide timeout, and optional custom Application ID.
- **Last.fm & ListenBrainz Scrobbling:** Built-in browser-approval auth for Last.fm (with optional custom API keys) and secure token storage for ListenBrainz.

### Accessibility & Updates
- **Accessibility First:** Includes **High Contrast** mode, **Reduce Motion** (freezes shimmers, crossfades, and slide transitions), and **Underline Links** toggles.
- **In-App Updater:** Checks GitHub Releases automatically and installs AppImage updates directly on supported desktop builds.

## Authentication

YouTube Music's InnerTube endpoints require an authenticated session cookie paired with `SAPISIDHASH` (standard OAuth tokens cannot access playback streams or watchtime history). NixieTube supports two ways to sign in:

1. **Built-in Browser (Linux & Android):** Opens a sign-in window directly inside the app and captures your session automatically once you log in to Google.
2. **Manual Cookie Import (All Platforms):** Paste the `Cookie` request header from an authenticated `music.youtube.com` session in your browser's DevTools.

All credentials and scrobbling tokens are stored locally on your device.

## Installation

### Prebuilt Releases
Download the latest Linux `AppImage` or mobile package from the [**GitHub Releases**](https://github.com/TheTinkerersHaven/NixieTube/releases) page.

```bash
chmod +x NixieTube-*.AppImage
./NixieTube-*.AppImage
```

### Building from Source

Ensure you have the [Flutter SDK](https://docs.flutter.dev/get-started/install) and platform toolchains installed.

```bash
git clone https://github.com/TheTinkerersHaven/NixieTube.git
cd NixieTube

flutter pub get

# Run on Linux desktop
flutter run -d linux

# Or build a release bundle
flutter build linux --release
```

> [!IMPORTANT]
> **Required before building for Android.**
> The Discord Social SDK is proprietary and can't be committed to this repo, so each developer needs their own copy of `discord_partner_sdk.aar`. Sign in to the [Discord Developer Portal](https://discord.com/developers/applications), open your application (make one if you don't have any), go to **Games → Social SDK → Downloads**, select the latest version, and download `DiscordSocialSdk-<version>.zip`. Unzip it and copy `discord_social_sdk/lib/release/discord_partner_sdk.aar` from the archive into this project at `android/app/libs/discord_partner_sdk.aar` (create the `libs` folder if it doesn't exist):
>
> ```bash
> mkdir -p android/app/libs
> unzip -o DiscordSocialSdk-<version>.zip 'discord_social_sdk/lib/release/discord_partner_sdk.aar' -d /tmp/discord_sdk
> cp /tmp/discord_sdk/discord_social_sdk/lib/release/discord_partner_sdk.aar android/app/libs/
> ```
>
> The path `android/app/libs/` is already gitignored — please don't force-add the AAR, and don't share it publicly. If the file is missing, the Gradle build fails with a clear error; you can also run `tool/setup_sdk.sh` (if present) to fetch/place it automatically.

## Tech Stack

| Layer | Technology |
| :--- | :--- |
| **Framework** | Flutter & Dart |
| **Design System** | Material 3 Expressive (`m3e_core`, `material_ui`) |
| **State Management** | `provider` with granular `select` rebuilds & `RepaintBoundary` isolation |
| **Desktop / System** | Linux D-Bus (`MPRIS`), XDG Portal / GTK accent detection, Discord IPC |
| **Scrobbling & Metadata** | InnerTube API, Last.fm API, ListenBrainz API |

---

<div align="center">

Made with ♥ by **TheTinkerersHaven** :3

</div>