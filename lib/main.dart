import 'dart:async' show unawaited;
import 'dart:io' show Platform, exit;

import 'package:material_ui/material_ui.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/artwork/artwork_store.dart';
import 'core/innertube/inner_tube.dart';
import 'core/innertube/stream_resolver.dart';
import 'core/player/just_audio_player_engine.dart';
import 'core/player/player_controller.dart';
import 'sys/discord.dart';
import 'sys/google_oauth.dart';
import 'sys/mpris.dart';
import 'sys/sys_config.dart';
import 'ui/app.dart';
import 'ui/app_state.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Cap the in-memory image cache: 540px covers decode to ~1MB each and
  // the on-disk renders are the real cache.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 * 1024 * 1024;
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
  final mpris = MprisService(controller: player, artworkStore: state.art)
    ..onQuit = () => unawaited(
      player
          .flushSession()
          .timeout(const Duration(seconds: 2), onTimeout: () {})
          .whenComplete(() => exit(0)),
    );
  if (Platform.isLinux && config.mprisEnabled) {
    unawaited(mpris.start());
  }
  final discord = DiscordPresence(
    appId: config.discordAppId,
    enabled: config.discordEnabled,
    statusText: discordStatusTextFromKey(config.discordStatusText),
  );
  unawaited(player.states.forEach(discord.update));

  player.restoreSession();
  unawaited(state.loadAuth());
  unawaited(state.loadHome());
  runApp(NixieTubeApp(state: state, mpris: mpris, discord: discord));
}

/// Application root.
class NixieTubeApp extends StatelessWidget {
  const NixieTubeApp({
    super.key,
    required this.state,
    required this.mpris,
    required this.discord,
  });

  final AppState state;
  final MprisService mpris;
  final DiscordPresence discord;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ChangeNotifierProvider.value(value: mpris),
        ChangeNotifierProvider.value(value: discord),
      ],
      child: MaterialApp(
        title: 'NixieTube',
        theme: buildTheme(),
        home: const Scaffold(body: AppShell()),
      ),
    );
  }
}
