// Discord Rich Presence via `flutter_discord_rpc`, ported from Kotlin
// `Discord.kt` (same presence fields, same artwork rules).
//
// One deliberate deviation: the backend exposes no activity `name`
// override, so the DiscordStatusText modes (app/song/artists) have no
// visible effect — presence always renders the standard app/song/artist
// shape. The setting is still persisted for forward compatibility.
//
// The IPC link is best-effort: Discord is often started after us, or
// restarted while we run, so a periodic retry re-attempts the handshake
// and re-pushes the current activity once it lands.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';

import '../core/player/player_state.dart';
import 'sys_config.dart' show defaultDiscordAppId;

/// What Discord shows as the activity name mode (persisted; see note above).
enum DiscordStatusText { app, song, artists }

/// Parses a persisted status-text key, defaulting to app mode.
DiscordStatusText discordStatusTextFromKey(String key) => switch (key) {
  'song' => DiscordStatusText.song,
  'artists' => DiscordStatusText.artists,
  _ => DiscordStatusText.app,
};

/// Serializes a status-text mode back to its config key.
String discordStatusTextKey(DiscordStatusText mode) => switch (mode) {
  DiscordStatusText.app => 'app',
  DiscordStatusText.song => 'song',
  DiscordStatusText.artists => 'artists',
};

/// 540px square YTM artwork only (mirrors the Kotlin artwork rule):
/// googleusercontent URLs with a square `=w-h` suffix, rewritten to
/// `=w540-h540-l90-rj`. Anything else yields no large image.
String? discordArtwork(String? url) {
  if (url == null || url.isEmpty) return null;
  if (!url.contains('googleusercontent')) return null;
  final m = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
  if (m == null || m.group(1) != m.group(2)) return null;
  return url.replaceFirst(RegExp(r'=w\d+-h\d+[^?]*'), '=w540-h540-l90-rj');
}

/// Builds the presence activity for a player snapshot, or null when
/// nothing should be shown.
RPCActivity? presenceActivity(PlayerState s) {
  final track = s.current;
  if (track == null) return null;
  final details = track.title.length > 128
      ? track.title.substring(0, 128)
      : track.title;
  final artist = track.artistNames();
  final state = s.playing ? artist : '⏸ $artist'.trim();
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final posSec = s.positionMs ~/ 1000;
  final durSec = s.durationMs ~/ 1000;
  final art = discordArtwork(track.displayArtwork);
  return RPCActivity(
    state: state,
    details: details,
    timestamps: RPCTimestamps(
      start: nowSec - posSec,
      end: (s.playing && durSec > 0) ? nowSec - posSec + durSec : null,
    ),
    assets: RPCAssets(largeImage: art, largeText: track.album?.name),
    buttons: [
      RPCButton(
        label: 'Listen on YouTube Music',
        url: 'https://music.youtube.com/watch?v=${track.videoId}',
      ),
    ],
    activityType: ActivityType.listening,
  );
}

/// How often the presence re-attempts a handshake that is not up yet.
const discordRetryInterval = Duration(seconds: 10);

/// The native RPC operations the presence drives. Injectable so tests
/// exercise the retry loop without the Rust library or a live Discord.
abstract interface class DiscordRpc {
  /// Whether the IPC link is up. Only meaningful once [initialize] has
  /// succeeded.
  bool get isConnected;

  Future<void> initialize(String appId);
  Future<void> connect();
  Future<void> setActivity(RPCActivity activity);
  Future<void> clearActivity();
  Future<void> disconnect();
}

/// The real `flutter_discord_rpc` client.
class _NativeDiscordRpc implements DiscordRpc {
  @override
  bool get isConnected => FlutterDiscordRPC.instance.isConnected;

  @override
  Future<void> initialize(String appId) => FlutterDiscordRPC.initialize(appId);

  @override
  Future<void> connect() => FlutterDiscordRPC.instance.connect();

  @override
  Future<void> setActivity(RPCActivity activity) =>
      FlutterDiscordRPC.instance.setActivity(activity: activity);

  @override
  Future<void> clearActivity() => FlutterDiscordRPC.instance.clearActivity();

  @override
  Future<void> disconnect() => FlutterDiscordRPC.instance.disconnect();
}

/// Discord Rich Presence client: IPC lifecycle plus presence pushes.
class DiscordPresence extends ChangeNotifier {
  DiscordPresence({
    String appId = '',
    bool enabled = false,
    DiscordStatusText statusText = DiscordStatusText.app,
    DiscordRpc? rpc,
    this.retryInterval = discordRetryInterval,
  }) {
    _appId = appId;
    _enabled = enabled;
    _statusText = statusText;
    _rpc = rpc ?? _NativeDiscordRpc();
  }

  late String _appId;
  late bool _enabled;
  late DiscordStatusText _statusText;
  late final DiscordRpc _rpc;
  String _status = 'disabled';
  String _dedup = '';
  bool _initialized = false;
  Future<void>? _initFuture;
  String? _firstInitError;
  Timer? _retryTimer;
  PlayerState? _last;

  /// How often a handshake that is not up yet is re-attempted while the
  /// presence is enabled.
  final Duration retryInterval;

  String get status => _status;
  bool get enabled => _enabled;
  String get appId => _appId;
  DiscordStatusText get statusText => _statusText;

  /// Whether the IPC link is up; false before the client even exists.
  bool get _connected => _initialized && _rpc.isConnected;

  void _setStatus(String value) {
    if (_status != value) {
      _status = value;
      notifyListeners();
    }
  }

  /// Swaps the API application, dropping the live session: the next
  /// update reconnects under the new id.
  void setAppId(String value) {
    if (_appId == value) return;
    _appId = value;
    _dedup = '';
    if (_enabled) {
      unawaited(shutdown());
    }
  }

  /// Toggles presence, tearing down the IPC connection when off.
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _dedup = '';
    if (!value) {
      _cancelRetry();
      unawaited(shutdown());
    } else {
      _setStatus('idle');
      _armRetry();
      final last = _last;
      if (last != null) unawaited(update(last));
    }
    notifyListeners();
  }

  /// Switches the activity-name mode (persisted by the caller).
  void setStatusText(DiscordStatusText value) {
    _statusText = value;
    notifyListeners();
  }

  /// Forgets the last pushed state so the next update re-sends even
  /// when nothing changed (used after reconnects).
  void invalidate() {
    _dedup = '';
  }

  Future<void> _ensureInitialized() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    try {
      await _rpc.initialize(
        _appId.trim().isEmpty ? defaultDiscordAppId : _appId.trim(),
      );
      _initialized = true;
    } catch (e) {
      _initFuture = null;
      // `initialize` sets its singleton before failing, so every retry
      // reports "already been initialized" — keep the original cause.
      final msg = '$e';
      if (!msg.contains('already been initialized')) {
        _firstInitError = msg;
      }
      _setStatus('error: ${_firstInitError ?? msg}');
      rethrow;
    }
  }

  /// Makes sure the RPC client exists and its IPC link is up. Returns
  /// whether the link is usable; failures have already been folded into
  /// [status] for the settings row.
  Future<bool> _ensureConnected() async {
    try {
      await _ensureInitialized();
    } catch (_) {
      // Init failure already surfaced as an error status; retry later.
      return false;
    }
    if (_connected) return true;
    try {
      await _rpc.connect();
    } catch (_) {
      // No Discord client around; stay idle and retry on the timer.
      _setStatus('idle');
      return false;
    }
    return _connected;
  }

  /// Pushes presence for [s], clearing when there is no track.
  Future<void> update(PlayerState s) async {
    _last = s;
    if (!_enabled) {
      _cancelRetry();
      if (_status != 'disabled') _setStatus('disabled');
      return;
    }
    _armRetry();
    final track = s.current;
    final key =
        '${track?.videoId}:${s.playing}:${track?.rating.index}:${s.positionMs ~/ 15}';
    if (key == _dedup) return;
    if (!await _ensureConnected()) return;
    try {
      if (track == null) {
        if (_connected) {
          await _rpc.clearActivity();
        }
        _dedup = key;
        _setStatus('idle');
        return;
      }
      final activity = presenceActivity(s);
      if (activity == null) return;
      await _rpc.setActivity(activity);
      _dedup = key;
      _setStatus('active');
    } catch (e) {
      _setStatus('idle');
    }
  }

  /// Keeps the handshake ready while the presence is enabled. A tick
  /// that finds the link up (or no player state yet) does nothing, so
  /// a healthy session pays only a timer wake-up.
  void _armRetry() {
    _retryTimer ??= Timer.periodic(retryInterval, (_) => unawaited(_retry()));
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _retry() async {
    if (!_enabled) {
      _cancelRetry();
      return;
    }
    if (_connected) return;
    final last = _last;
    if (last == null) return;
    // Forget the last push: the reconnected client must re-render the
    // activity instead of believing it is already on screen.
    _dedup = '';
    await update(last);
  }

  /// Tears down the IPC connection. State is settled synchronously (so
  /// callers see the new status at once) and only the teardown awaits.
  Future<void> shutdown() async {
    _dedup = '';
    final wasInitialized = _initialized;
    _initialized = false;
    _setStatus(_enabled ? 'idle' : 'disabled');
    if (wasInitialized) {
      try {
        await _rpc.disconnect();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _cancelRetry();
    unawaited(shutdown());
    super.dispose();
  }
}
