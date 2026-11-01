import 'dart:async' show unawaited;
import 'dart:io' show Platform, exit;

import 'package:material_ui/material_ui.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/artwork/artwork_store.dart';
import 'core/innertube/inner_tube.dart';
import 'core/innertube/stream_resolver.dart';
import 'core/player/audio_backend.dart';
import 'core/player/just_audio_player_engine.dart';
import 'core/player/player_controller.dart';
import 'sys/discord.dart';
import 'sys/lastfm.dart';
import 'sys/mpris.dart';
import 'sys/sleep_inhibit.dart';
import 'sys/sys_config.dart';
import 'sys/tray_service.dart';
import 'ui/app.dart';
import 'ui/app_state.dart';
import 'ui/theme.dart';

/// Caps the in-memory image cache. `maximumSizeBytes` is the memory bound;
/// `maximumSize` (entry count) is left at its default — setting it to a byte
/// value would conflate count with bytes and disable the entry-count LRU.
void _configureImageCache() {
  // Tile decodes are bounded to the box they show (typically a few
  // hundred KB of bitmap), so a moderate byte bound keeps an afternoon
  // of browsing resident — hundreds of covers — and turns scroll-back
  // reloads into cache hits. The OS memory-pressure observer and the
  // debug clear action empty it regardless.
  const desktopCache = 256 * 1024 * 1024;
  const mobileCache = 64 * 1024 * 1024;

  final int cacheSizeBytes =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS
      ? desktopCache
      : mobileCache;

  // `maximumSize` (entry count) is left at its default so the
  // entry-count LRU still applies underneath the byte bound.
  PaintingBinding.instance.imageCache.maximumSizeBytes = cacheSizeBytes;
}


/// Clears the in-memory image cache when the OS reports memory
/// pressure, so a long scroll session can't pin decoded covers
/// forever. The disk cache is the real store; the in-memory cache
/// is only a render shortcut.
class _ImageCachePressureObserver extends WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

/// App entrypoint: wires services (player, auth, tray, MPRIS,
/// Discord, Last.fm), restores the session, and runs the app. All
/// service startups are best-effort so none can break launch.
void main(List<String> args) {
  // Webview title-bar subprocess entry point (vendored
  // desktop_webview_window); the main app continues below.
  if (runWebViewTitleBarWidget(args)) return;
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addObserver(_ImageCachePressureObserver());
  // Configure adaptive image cache based on available memory.
  _configureImageCache();
  JustAudioMediaKit.ensureInitialized();
  final config = SysConfig();
  final tube = InnerTube();
  // The resolver and the engine factory stay reachable so the player
  // can restart its backend stack (fresh HTTP pool, visitor id and
  // native handle) when a stream-URL family keeps dying — the
  // in-process equivalent of the app restart that fixes it.
  final streamResolver = StreamResolver();
  final player = PlayerController(
    engine: JustAudioPlayerEngine(),
    tube: tube,
    resolveStream: streamResolver.resolve,
    refreshStream: streamResolver.refreshVisitor,
    resetStream: streamResolver.reset,
    createEngine: JustAudioPlayerEngine.new,
  );
  final state = AppState(
    tube: tube,
    player: player,
    art: ArtworkStore(),
    config: config,
    openUrl: (url) =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
  );

  // Desktop integrations (best-effort; failures never block the UI).
  // Window close hides to the tray (see TrayService); quitting
  // flushes the session first, from either MPRIS or the tray menu.
  // Sleep inhibition must drop before exit, or the lock outlives us.
  final sleepInhibit = SleepInhibitService(controller: player);
  Future<void> quitApp() async {
    await sleepInhibit.dispose();
    await player.flushSession().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    exit(0);
  }

  final mpris = MprisService(controller: player, artworkStore: state.art)
    ..onQuit = () => unawaited(quitApp());
  if (Platform.isLinux && config.mprisEnabled) {
    unawaited(mpris.start());
  }
  final tray = TrayService(
    controller: player,
    onQuit: quitApp,
    scheme: state.displayScheme,
  );
  unawaited(tray.start().catchError((_) {}));
  final discord = DiscordPresence(
    appId: config.discordAppId,
    enabled: config.discordEnabled,
    statusText: discordStatusTextFromKey(config.discordStatusText),
  );
  unawaited(player.states.forEach(discord.update));

  final lastfm = LastFmService(config: config);
  unawaited(player.states.forEach(lastfm.update));

  // The credentials live in the platform secret store: load them in
  // the background (the legacy plain-text file is migrated into the
  // store and deleted on the first run), then let the integrations
  // that read them pick the values up.
  unawaited(
    config.loadCredentials().then((_) {
      lastfm.refreshStatus();
    }),
  );

  // Sleep stays unblocked until the first play takes the lock.
  unawaited(sleepInhibit.start().catchError((_) {}));

  // Probe the native audio backend before the user plays anything: a
  // missing mpv otherwise fails on first play with console noise and
  // a 20s hang that reads as a freeze. Best-effort; the UI reports it.
  unawaited(_probeAudioBackend(state));

  unawaited(player.restoreSession());
  unawaited(state.loadAuth());
  unawaited(state.loadHome());
  runApp(
    NixieTubeApp(state: state, mpris: mpris, discord: discord, lastfm: lastfm),
  );
}

/// Probes the native audio backend and reports a failure so playback
/// refuses to start with guidance instead of hanging.
Future<void> _probeAudioBackend(AppState state) async {
  final result = await probeAudioBackend();
  if (result.status == AudioBackendStatus.ok) return;
  final message = result.message;
  if (message == null) return;
  state.reportAudioBackendUnavailable(message);
}

/// Application root.
class NixieTubeApp extends StatelessWidget {
  const NixieTubeApp({
    super.key,
    required this.state,
    required this.mpris,
    required this.discord,
    required this.lastfm,
  });

  final AppState state;
  final MprisService mpris;
  final DiscordPresence discord;
  final LastFmService lastfm;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ChangeNotifierProvider.value(value: mpris),
        ChangeNotifierProvider.value(value: discord),
        ChangeNotifierProvider.value(value: lastfm),
      ],
      child: const _ThemedApp(),
    );
  }
}

/// The themed shell. The [DynamicColorBuilder] must wrap the
/// [MaterialApp]: it fetches the platform accent (XDG portal /
/// GTK theme on Linux) asynchronously and rebuilds exactly here
/// when it lands — [ColorScheme]s cannot travel through the
/// config notifier, so they enter the tree at this boundary.
class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return _ThemedMaterialApp(darkDynamic: darkDynamic);
      },
    );
  }
}

/// Publishes the effective [scheme] for non-widget consumers (tray
/// icon) and returns it for [MaterialApp]. Only the tray listens, so
/// publishing mid-build schedules no widget rebuilds.
ColorScheme? _publishScheme(BuildContext context, ColorScheme? scheme) {
  final displayScheme = context.read<AppState>().displayScheme;
  if (displayScheme.value != scheme) displayScheme.value = scheme;
  return scheme;
}

/// The [MaterialApp] itself. Selects the accessibility flags
/// plus every theme setting, so the root rebuilds when any of
/// them flips (theme + skeleton effect) and on nothing else —
/// the frequent progress ticks never rebuild the tree.
class _ThemedMaterialApp extends StatelessWidget {
  const _ThemedMaterialApp({this.darkDynamic});

  /// System dark scheme from [DynamicColorBuilder], or null
  /// when the platform reports no dynamic colors.
  final ColorScheme? darkDynamic;

  @override
  Widget build(BuildContext context) {
    final highContrast = context.select<AppState, bool>(
      (s) => s.config.highContrast,
    );
    final reducedMotion = context.select<AppState, bool>(
      (s) => s.config.reducedMotion,
    );
    final themeSource = context.select<AppState, String>(
      (s) => s.config.themeSource,
    );
    final themeSeed = context.select<AppState, int>(
      (s) => s.config.themeSeedColor,
    );
    final themePrimary = context.select<AppState, int?>(
      (s) => s.config.themePrimaryOverride,
    );
    final themeSecondary = context.select<AppState, int?>(
      (s) => s.config.themeSecondaryOverride,
    );
    final themeTertiary = context.select<AppState, int?>(
      (s) => s.config.themeTertiaryOverride,
    );
    final themeSurface = context.select<AppState, int?>(
      (s) => s.config.themeSurfaceOverride,
    );
    final rememberedSystem = context.select<AppState, int?>(
      (s) => s.config.themeSystemPrimary,
    );
    // Remember the live desktop accent for the next cold start: the
    // tray/window icon renders before this async fetch lands, so
    // without the remembered value it would start on the built-in
    // fallback every launch. Writes only on change; `set` itself
    // never notifies, so no build loop.
    final liveDynamic = darkDynamic;
    if (liveDynamic != null) {
      final live = liveDynamic.primary.toARGB32();
      if (rememberedSystem != live) {
        context.read<AppState>().config.themeSystemPrimary = live;
      }
    }
    final theme = buildTheme(
      highContrast: highContrast,
      scheme: _publishScheme(
        context,
        resolveColorScheme(
          source: ThemeSource.fromKey(themeSource),
          seedColor: themeSeed,
          systemDark: darkDynamic,
          rememberedSystemPrimary: rememberedSystem,
          primaryOverride: themePrimary,
          secondaryOverride: themeSecondary,
          tertiaryOverride: themeTertiary,
          surfaceOverride: themeSurface,
        ),
      ),
    );
    return MaterialApp(
      title: 'NixieTube',
      theme: theme,
      home: SkeletonizerConfig(
        // One high-contrast shimmer for every skeleton in the app (home
        // feed, artwork tiles, …) — the package's dark-mode default is
        // nearly invisible on this theme. Reduced motion swaps it for a
        // static solid placeholder: skeletons stay, the movement goes.
        data: SkeletonizerConfigData(
          // Resolver form (the plain `effect` is deprecated in
          // skeletonizer 3): brightness is ignored — the app
          // is dark-only, so every skeleton shares the one
          // high-contrast shimmer. Reduced motion swaps it
          // for a static solid placeholder: skeletons stay,
          // the movement goes.
          effectResolver: (_) => reducedMotion
              ? const SolidColorEffect(color: Color(0xFF2C2C2E))
              : const ShimmerEffect(
                  baseColor: Color(0xFF2C2C2E),
                  highlightColor: Color(0xFF4B4B4F),
                  duration: Duration(milliseconds: 1400),
                ),
        ),
        child: const Scaffold(body: AppShell()),
      ),
    );
  }
}
