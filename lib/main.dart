import 'dart:async' show unawaited;
import 'dart:io' show Platform, exit;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
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
import 'sys/listenbrainz.dart';
import 'sys/log.dart';
import 'sys/media_session.dart';
import 'sys/mpris.dart';
import 'sys/musicbrainz.dart';
import 'sys/paths.dart' show initPlatformPaths;
import 'sys/platform_features.dart';
import 'sys/sleep_inhibit.dart';
import 'sys/sys_config.dart';
import 'sys/tray_service.dart';
import 'ui/app.dart';
import 'ui/app_state.dart';
import 'ui/theme.dart';
import 'ui/widgets/track_menu_scope.dart';

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
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // One reading of the host, reused by every integration decision below.
  final platform = currentPlatform();
  // Phones draw behind the status and navigation bars. Android 14 does
  // not force this on its own, so opt in explicitly; the transparent
  // bar colours live in the root AnnotatedRegion (ui/app.dart), which
  // survives MaterialApp/AppBar re-applying the default styles.
  if (supportsBackgroundAudio(platform)) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  // Mobile apps have no writable HOME/XDG dirs: resolve the sandbox
  // before anything (logging, settings, caches) asks for a path.
  await initPlatformPaths();
  WidgetsBinding.instance.addObserver(_ImageCachePressureObserver());
  _configureImageCache();
  JustAudioMediaKit.ensureInitialized();
  // Console and file logging for the stream resolver, updater and the
  // rest of the app.
  initLogging();
  final config = SysConfig();
  final tube = InnerTube();
  final streamResolver = StreamResolver(cookie: tube.auth.cookie);
  // The first play otherwise pays for the YouTube homepage read that
  // yields the visitor id; fetching it while the app starts hides that
  // round trip from the user. Fire-and-forget: a failure is retried by
  // the normal resolve path.
  streamResolver.warmUp();
  final player = PlayerController(
    engine: JustAudioPlayerEngine(),
    tube: tube,
    resolveStream: streamResolver.resolve,
    refreshStream: streamResolver.refreshVisitor,
    resetStream: streamResolver.reset,
    createEngine: JustAudioPlayerEngine.new,
  );
  // Phones suspend a backgrounded app, so playback has to be attached to
  // an OS media session (a foreground service on Android, the audio
  // background mode on iOS) to survive the screen locking. The same
  // session draws the notification and lock-screen controls and serves
  // Android Auto, Wear and headset buttons. Desktop has no such thing to
  // attach to — MPRIS and the tray cover it — so nothing is started.
  if (supportsBackgroundAudio(platform)) {
    // audio_service requires init to finish before runApp; the handler
    // catches its own failures, so a phone with no plugin still starts.
    await startBackgroundAudio(player);
  }
  final state = AppState(
    tube: tube,
    player: player,
    art: ArtworkStore(),
    config: config,
    openUrl: (url) =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    streamResolver: streamResolver,
  );
  // The notification's like button needs the app's rating path (the
  // optimistic update, the liked list and the backend call), which only
  // exists once the state does.
  backgroundAudio?.connectRatings(
    canRate: () => state.ratingsAvailable,
    onLike: (videoId, rating) async {
      await state.rateTrack(videoId, rating);
    },
  );

  // Desktop integrations (best-effort; failures never block the UI).
  // Window close hides to the tray (see TrayService); quitting
  // flushes the session first, from either MPRIS or the tray menu.
  // Sleep inhibition must drop before exit, or the lock outlives us.
  final discord = DiscordPresence(
    appId: config.discordAppId,
    enabled: config.discordEnabled,
    statusText: discordStatusTextFromKey(config.discordStatusText),
    pauseHideAfter: Duration(minutes: config.discordPauseHideMinutes),
    supported: supportsDiscordRpc(platform),
  );
  unawaited(player.states.forEach(discord.update));

  final sleepInhibit = SleepInhibitService(controller: player);
  Future<void> quitApp() async {
    await sleepInhibit.dispose();
    await player.flushSession().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    try {
      await discord.shutdown().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // Queued cache writes (recents, play counts, enrichment) are flushed
    // in a microtask; exit() would drop them.
    state.flushCaches();
    exit(0);
  }

  final mpris = MprisService(controller: player, artworkStore: state.art)
    ..onQuit = () => unawaited(quitApp());
  if (config.mprisEnabled && supportsMpris(platform)) {
    unawaited(mpris.start());
  }
  final tray = TrayService(
    controller: player,
    onQuit: quitApp,
    scheme: state.displayScheme,
  );
  unawaited(tray.start().catchError((_) {}));

  final lastfm = LastFmService(config: config);
  unawaited(player.states.forEach(lastfm.update));
  final listenbrainz = ListenBrainzService(config: config);
  unawaited(player.states.forEach(listenbrainz.update));
  final musicbrainz = MusicBrainzService();

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
  // Phones have no mpv to probe — their player is the platform one — and
  // probing would only ask them to install a Linux package.
  if (isDesktop(platform)) {
    unawaited(_probeAudioBackend(state));
  }

  unawaited(player.restoreSession());
  unawaited(state.loadAuth());
  // Only an AppImage build can do anything with a found release, so a
  // phone never pays for a GitHub round trip it cannot act on.
  if (state.canInstallUpdates) {
    unawaited(state.checkForUpdates());
  }
  unawaited(state.loadHome());
  runApp(
    NixieTubeApp(
      state: state,
      mpris: mpris,
      discord: discord,
      lastfm: lastfm,
      musicbrainz: musicbrainz,
      listenbrainz: listenbrainz,
    ),
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
    this.musicbrainz,
    this.listenbrainz,
  });

  final AppState state;
  final MprisService mpris;
  final DiscordPresence discord;
  final LastFmService lastfm;
  final MusicBrainzService? musicbrainz;
  final ListenBrainzService? listenbrainz;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ChangeNotifierProvider.value(value: mpris),
        ChangeNotifierProvider.value(value: discord),
        ChangeNotifierProvider.value(value: lastfm),
        if (musicbrainz != null)
          Provider<MusicBrainzService>.value(value: musicbrainz!),
        if (listenbrainz != null)
          ChangeNotifierProvider.value(value: listenbrainz!),
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
class _ThemedMaterialApp extends StatefulWidget {
  const _ThemedMaterialApp({this.darkDynamic});

  /// System dark scheme from [DynamicColorBuilder], or null
  /// when the platform reports no dynamic colors.
  final ColorScheme? darkDynamic;

  @override
  State<_ThemedMaterialApp> createState() => _ThemedMaterialAppState();
}

class _ThemedMaterialAppState extends State<_ThemedMaterialApp> {
  /// One menu coordinator for the whole app: opening a track menu closes
  /// whichever one is already open, so a right-click elsewhere swaps the
  /// menu in the same gesture.
  final _menus = TrackMenuCoordinator();

  @override
  void dispose() {
    _menus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final darkDynamic = widget.darkDynamic;
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
    if (darkDynamic != null) {
      final live = darkDynamic.primary.toARGB32();
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
      // The menu coordinator sits above the navigator, so every track
      // row and rail card can swap the open menu in one gesture.
      //
      // The overlay style is an AnnotatedRegion (not a one-shot
      // SystemChrome call) so it participates in the per-frame
      // hit-test: MaterialApp, Scaffolds and AppBars can re-apply their
      // default light/dark style, but this region stays on top and
      // keeps the status and navigation bars transparent. The builder
      // sits below the app's AnimatedTheme, so the brightness (and
      // therefore the icon colours) follows the live theme.
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            systemNavigationBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: TrackMenuScope(
            coordinator: _menus,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: _SkeletonConfig(
        reducedMotion: reducedMotion,
        child: const Scaffold(body: AppShell()),
      ),
    );
  }
}

/// Applies the skeleton shimmer (or a static solid placeholder under
/// reduced motion) around [child].
///
/// The OS "Reduce Motion" flag is OR-ed with the in-app toggle:
/// [MediaQuery.maybeReduceMotionOf] rebuilds this widget when the system
/// setting flips, so the shimmer stops without an app restart. This keeps
/// the skeleton effect consistent with [motionDuration] in `a11y.dart`,
/// which honors the same flag for every other animation.
class _SkeletonConfig extends StatelessWidget {
  const _SkeletonConfig({required this.reducedMotion, required this.child});

  /// The in-app reduced-motion toggle.
  final bool reducedMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced =
        reducedMotion || (MediaQuery.maybeReduceMotionOf(context) ?? false);
    return SkeletonizerConfig(
      // One high-contrast shimmer for every skeleton in the app (home
      // feed, artwork tiles, …) — the package's dark-mode default is
      // nearly invisible on this theme. Reduced motion swaps it for a
      // static solid placeholder: skeletons stay, the movement goes.
      data: SkeletonizerConfigData(
        // Resolver form (the plain `effect` is deprecated in
        // skeletonizer 3): brightness is ignored — the app
        // is dark-only, so every skeleton shares the one
        // high-contrast shimmer.
        effectResolver: (_) => reduced
            ? const SolidColorEffect(color: Color(0xFF2C2C2E))
            : const ShimmerEffect(
                baseColor: Color(0xFF2C2C2E),
                highlightColor: Color(0xFF4B4B4F),
                duration: Duration(milliseconds: 1400),
              ),
      ),
      child: child,
    );
  }
}
