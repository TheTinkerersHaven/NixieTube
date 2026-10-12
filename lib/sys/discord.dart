// Discord Rich Presence via `flutter_discord_rpc`, ported from Kotlin
// `Discord.kt` (same presence fields, same artwork rules).
//
// One deliberate deviation: the backend exposes no activity `name`
// override, so the DiscordStatusText modes (app/song/artists) have no
// visible effect — presence always renders the standard app/song/artist
// shape. The setting is still persisted for forward compatibility.

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

/// Discord Rich Presence client: IPC lifecycle plus presence pushes.
class DiscordPresence extends ChangeNotifier {
  DiscordPresence({
    String appId = '',
    bool enabled = false,
    DiscordStatusText statusText = DiscordStatusText.app,
  }) {
    _appId = appId;
    _enabled = enabled;
    _statusText = statusText;
  }

  late String _appId;
  late bool _enabled;
  late DiscordStatusText _statusText;
  String _status = 'disabled';
  String _dedup = '';
  bool _initialized = false;
  Future<void>? _initFuture;
  String? _firstInitError;

  String get status => _status;
  bool get enabled => _enabled;
  String get appId => _appId;
  DiscordStatusText get statusText => _statusText;

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
      unawaited(shutdown());
    } else {
      _setStatus('idle');
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
      await FlutterDiscordRPC.initialize(
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

  /// Pushes presence for [s], clearing when there is no track.
  Future<void> update(PlayerState s) async {
    if (!_enabled) {
      if (_status != 'disabled') _setStatus('disabled');
      return;
    }
    final track = s.current;
    final key =
        '${track?.videoId}:${s.playing}:${track?.rating.index}:${s.positionMs ~/ 15}';
    if (key == _dedup) return;
    try {
      await _ensureInitialized();
    } catch (_) {
      // Init failure already surfaced as an error status; retry later.
      return;
    }
    try {
      if (track == null) {
        if (FlutterDiscordRPC.instance.isConnected) {
          await FlutterDiscordRPC.instance.clearActivity();
        }
        _dedup = key;
        _setStatus('idle');
        return;
      }
      if (!FlutterDiscordRPC.instance.isConnected) {
        try {
          await FlutterDiscordRPC.instance.connect();
        } catch (_) {
          // No Discord client around; stay idle and retry on a later key.
          _setStatus('idle');
          return;
        }
      }
      final activity = presenceActivity(s);
      if (activity == null) return;
      await FlutterDiscordRPC.instance.setActivity(activity: activity);
      _dedup = key;
      _setStatus('active');
    } catch (e) {
      _setStatus('idle');
    }
  }

  /// Tears down the IPC connection.
  Future<void> shutdown() async {
    _dedup = '';
    if (_initialized) {
      try {
        await FlutterDiscordRPC.instance.disconnect();
      } catch (_) {}
    }
    _initialized = false;
    _setStatus(_enabled ? 'idle' : 'disabled');
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
