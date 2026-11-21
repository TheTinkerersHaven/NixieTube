// What the running build can integrate with.
//
// The app ships on two very different hosts: a desktop session (Linux
// AppImage, plus the macOS/Windows scaffolding) and a phone. Several
// integrations only exist on one of them — MPRIS is a Linux session bus,
// Discord's Rich Presence socket lives next to the desktop client, the
// embedded login window is a WebKit view — so the decision "can this
// build use it?" belongs in one place instead of being re-derived with
// `Platform.isX` at every call site.
//
// [currentPlatform] is the only function that touches the OS; the
// predicates are pure and unit-tested.

import 'dart:io' show Platform;

/// The host the app is running on, as far as integrations care.
enum AppPlatform { linux, windows, macOS, android, ios, other }

/// The host this process is running on.
AppPlatform currentPlatform() {
  if (Platform.isLinux) return AppPlatform.linux;
  if (Platform.isWindows) return AppPlatform.windows;
  if (Platform.isMacOS) return AppPlatform.macOS;
  if (Platform.isAndroid) return AppPlatform.android;
  if (Platform.isIOS) return AppPlatform.ios;
  return AppPlatform.other;
}

/// Whether [platform] is a desktop session with a window, a tray and
/// local sockets for other desktop apps to talk to.
bool isDesktop(AppPlatform platform) => switch (platform) {
  AppPlatform.linux || AppPlatform.windows || AppPlatform.macOS => true,
  _ => false,
};

/// Whether the app can show a Google sign-in page inside itself, so the
/// user never has to import a cookie: a WebKit window on desktop, the
/// system WebView on Android.
///
/// iOS has neither — a `WKWebView` cannot hand its cookie store to the
/// app — so it stays on the cookie paste.
bool supportsEmbeddedLogin(AppPlatform platform) =>
    isDesktop(platform) || platform == AppPlatform.android;

/// Whether Discord Rich Presence can work.
///
/// Discord exposes presence over a local IPC socket owned by the desktop
/// client; a phone has neither the socket nor a Discord client to own it.
bool supportsDiscordRpc(AppPlatform platform) => isDesktop(platform);

/// Whether MPRIS media keys can be exported.
///
/// MPRIS is a D-Bus interface of the Linux desktop session.
bool supportsMpris(AppPlatform platform) => platform == AppPlatform.linux;

/// Whether a tray icon can be shown.
bool supportsTray(AppPlatform platform) => isDesktop(platform);

/// Whether playback must stay alive through an OS media session.
///
/// Android and iOS suspend a backgrounded app, so a phone needs the
/// foreground service / background audio mode the media session starts;
/// desktop keeps playing without one.
bool supportsBackgroundAudio(AppPlatform platform) => switch (platform) {
  AppPlatform.android || AppPlatform.ios => true,
  _ => false,
};