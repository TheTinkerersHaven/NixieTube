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
import 'core/player/just_audio_player_engine.dart';
import 'core/player/player_controller.dart';
import 'sys/discord.dart';
import 'sys/google_oauth.dart';
import 'sys/lastfm.dart';
import 'sys/mpris.dart';
import 'sys/sys_config.dart';
import 'sys/tray_service.dart';
import 'ui/app.dart';
import 'ui/app_state.dart';
import 'ui/theme.dart';

/// Caps the in-memory image cache. `maximumSizeBytes` is the memory bound;
/// `maximumSize` (entry count) is left at its default — setting it to a byte
/// value would conflate count with bytes and disable the entry-count LRU.
void _configureImageCache() {
  // Default cache sizes based on platform
  const defaultMobileCache = 32 * 1024 * 1024; // 32MB for mobile
  const defaultDesktopCache = 64 * 1024 * 1024; // 64MB for desktop

  final int cacheSizeBytes = Platform.isLinux || Platform.isWindows || Platform.isMacOS
      ? defaultDesktopCache
      : defaultMobileCache;

  // Configure the image cache: 540px covers decode to ~1MB each and
  // the on-disk renders are the real cache.
  PaintingBinding.instance.imageCache.maximumSizeBytes = cacheSizeBytes;
}

void main(List<String> args) {
  // Webview title-bar subprocess entry point (vendored
  // desktop_webview_window); the main app continues below.
  if (runWebViewTitleBarWidget(args)) return;
  WidgetsFlutterBinding.ensureInitialized();
  // Configure adaptive image cache based on available memory.
  _configureImageCache();
  JustAudioMediaKit.ensureInitialized();
  final config = SysConfig();
  final tube = InnerTube();
  final oauth = GoogleOAuth(config: config);
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
    oauth: oauth,
    config: config,
    openUrl: (url) =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
  );

  // Desktop integrations (best-effort; failures never block the UI).
  // Window close hides to the tray (see TrayService); quitting
  // flushes the session first, from either MPRIS or the tray menu.
  Future<void> quitApp() => player
      .flushSession()
      .timeout(const Duration(seconds: 2), onTimeout: () {})
      .whenComplete(() => exit(0));
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

  unawaited(player.restoreSession());
  unawaited(state.loadAuth());
  unawaited(state.loadHome());
  runApp(
    NixieTubeApp(
      state: state,
      mpris: mpris,
      discord: discord,
      lastfm: lastfm,
    ),
  );
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
    final theme = buildTheme(
      highContrast: highContrast,
      scheme: _publishScheme(
        context,
        resolveColorScheme(
          source: ThemeSource.fromKey(themeSource),
          seedColor: themeSeed,
          systemDark: darkDynamic,
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
