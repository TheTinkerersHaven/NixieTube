// Discord Rich Presence over the local RPC socket.
//
// Discord renders the status line from the activity's `name`, and fills it
// in with the *application* name when we do not send one — so what the
// user picks in [DiscordStatusText] is sent as `name`, with the song and
// its artist on the lines below it.
//
// The IPC link is best-effort: Discord is often started after us, or
// restarted while we run, so a periodic retry re-attempts the handshake
// and re-pushes the current activity once it lands.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/player/player_state.dart';
import 'discord_ipc.dart';
import 'sys_config.dart' show defaultDiscordAppId;

// The presence contract and its activity payload live with the pure-Dart
// IPC client; re-exported so callers keep one import.
export 'discord_ipc.dart'
    show
        DiscordActivity,
        DiscordActivityType,
        DiscordAssets,
        DiscordButton,
        DiscordRpc,
        DiscordTimestamps;

/// What the user picks for Discord's status line (persisted as
/// `discord.statusText`), sent as the activity's `name`.
enum DiscordStatusText { app, song, artists, album }

/// Settings-row label for each status-line choice.
String discordStatusTextLabel(DiscordStatusText mode) => switch (mode) {
  DiscordStatusText.app => 'App Name',
  DiscordStatusText.song => 'Song Title',
  DiscordStatusText.artists => 'Song Artist',
  DiscordStatusText.album => 'Song Album',
};

/// Parses a persisted status-text key, defaulting to app mode.
DiscordStatusText discordStatusTextFromKey(String key) => switch (key) {
  'song' => DiscordStatusText.song,
  'artists' => DiscordStatusText.artists,
  'album' => DiscordStatusText.album,
  _ => DiscordStatusText.app,
};

/// Serializes a status-text mode back to its config key.
String discordStatusTextKey(DiscordStatusText mode) => switch (mode) {
  DiscordStatusText.app => 'app',
  DiscordStatusText.song => 'song',
  DiscordStatusText.artists => 'artists',
  DiscordStatusText.album => 'album',
};

/// Square 540px YTM artwork for Discord:
/// any googleusercontent `=w-h` thumbnail is rewritten to
/// `=w540-h540-l90-rj`, forcing YouTube's image server to center-crop
/// non-square (4:3 / 16:9) video thumbnails into a square cover. Anything
/// else yields no large image.
String? discordArtwork(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.contains('googleusercontent')) {
    final m = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
    if (m == null) return null;
    return url.replaceFirst(RegExp(r'=w\d+-h\d+[^?]*'), '=w540-h540-l90-rj');
  }
  if (url.contains('i.ytimg.com')) {
    // Video stills are 16:9; Discord crops the large image to a square
    // thumbnail itself, so the raw still is fine. Force https and a
    // high-res variant when the URL carries a size suffix.
    var u = url;
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = u.replaceFirst('http://', 'https://');
    return u;
  }
  return null;
}

/// Discord caps these fields at 128 characters.
const _discordTextLimit = 128;

String _clipDiscord(String text) => text.length > _discordTextLimit
    ? text.substring(0, _discordTextLimit)
    : text;

/// Builds the presence activity for a player snapshot, or null when
/// nothing should be shown. [mode] picks what the Discord status line
/// says: the activity headline ([DiscordActivity.name]), with the song and
/// its artist on the two lines below it.
DiscordActivity? presenceActivity(
  PlayerState s, [
  DiscordStatusText mode = DiscordStatusText.app,
]) {
  final track = s.current;
  if (track == null) return null;
  final title = _clipDiscord(track.title);
  final artist = _clipDiscord(track.artistNames());
  final album = _clipDiscord(track.album?.name ?? '');
  // The status line is the activity's own `name`. Left unset, Discord
  // substitutes the *application* name, so the choice only reaches the
  // screen when it is sent explicitly.
  final name = switch (mode) {
    DiscordStatusText.app => 'NixieTube',
    DiscordStatusText.song => title,
    DiscordStatusText.artists => artist,
    DiscordStatusText.album => album,
  };
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final posSec = s.positionMs ~/ 1000;
  final durSec = s.durationMs ~/ 1000;
  final art = discordArtwork(track.bestArtwork);
  return DiscordActivity(
    name: name,
    details: title,
    state: s.playing ? artist : '⏸ $artist'.trim(),
    timestamps: DiscordTimestamps(
      start: nowSec - posSec,
      end: (s.playing && durSec > 0) ? nowSec - posSec + durSec : null,
    ),
    assets: DiscordAssets(largeImage: art, largeText: track.album?.name),
    buttons: [
      DiscordButton(
        label: 'Listen on YouTube Music',
        url: 'https://music.youtube.com/watch?v=${track.videoId}',
      ),
    ],
    type: DiscordActivityType.listening,
  );
}

/// How often the presence re-attempts a handshake that is not up yet,
/// before a link has ever come up in this run.
const discordRetryInterval = Duration(seconds: 10);

/// How often the handshake is re-attempted once a link *has* been up and
/// been lost again.
///
/// Discord refuses a new handshake for roughly half a minute after a
/// session ends (measured against the live client): an immediate retry,
/// or a fixed one tighter than that, only ever lands inside the refusal
/// window, where it is rejected for keeping it open. The presence then
/// reports itself connected to a socket nothing is listening on, and no
/// amount of retrying brings it back — which is exactly how a lost link
/// turns into "the status-line picker does nothing".
const discordReconnectInterval = Duration(seconds: 35);

/// Ceiling the reconnect delay backs off to. Keeps a client that is being
/// restarted in a loop from being probed once per second forever.
const discordRetryMaxInterval = Duration(seconds: 60);

/// How long a playing session runs on the pushed start timestamp before
/// presence is re-sent to correct clock drift.
const discordResyncInterval = Duration(seconds: 30);

/// How far the live position may run ahead of (or behind) the pushed
/// presence's implication of "last seen position + elapsed" before the
/// push is re-sent immediately: misses this band mean a seek.
const discordSeekRealignment = Duration(milliseconds: 1200);

/// How long a track may stay paused before its presence is withdrawn.
const discordPauseHideAfter = Duration(minutes: 15);

/// The real client: a pure-Dart IPC link, no native bridge involved.
class _NativeDiscordRpc implements DiscordRpc {
  _NativeDiscordRpc([DiscordIpcClient? client])
    : _client = client ?? DiscordIpcClient();

  final DiscordIpcClient _client;

  @override
  bool get isConnected => _client.isConnected;

  @override
  Future<void> initialize(String appId) => _client.initialize(appId);

  @override
  Future<void> connect() => _client.connect();

  @override
  Future<void> setActivity(DiscordActivity activity) =>
      _client.setActivity(activity);

  @override
  Future<void> clearActivity() => _client.clearActivity();

  @override
  Future<void> disconnect() => _client.disconnect();
}

/// Discord Rich Presence client: IPC lifecycle plus presence pushes.
class DiscordPresence extends ChangeNotifier {
  DiscordPresence({
    String appId = '',
    bool enabled = false,
    DiscordStatusText statusText = DiscordStatusText.app,
    DiscordRpc? rpc,
    this.retryInterval = discordRetryInterval,
    this.reconnectInterval = discordReconnectInterval,
    this.maxRetryInterval = discordRetryMaxInterval,
    this.pauseHideAfter = discordPauseHideAfter,
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

  /// When playback paused on the current track, the moment it paused;
  /// cleared on play or track change. Presence is withdrawn once this
  /// ages past [discordPauseHideAfter].
  DateTime? _pausedAt;
  String? _pausedTrackId;

  /// Position bookkeeping for [update]'s resync cadence: the last pushed
  /// elapsed reading, whether playback was running then, and when it was
  /// pushed. Discord ticks the elapsed clock itself from the pushed
  /// start timestamp, so a re-push is owed only when the player diverged
  /// from that clock (a seek within the same track) or periodically, to
  /// correct small drift — one frame per ~half a minute, not on every
  /// 500 ms tick.
  int _pushedPosMs = 0;
  bool _pushedPlaying = false;
  DateTime _pushedAt = DateTime.now();
  bool _initialized = false;

  /// Whether an [DiscordRpc.initialize] has ever completed. The native
  /// client survives [DiscordRpc.disconnect], so a later re-initialize
  /// answering "already been initialized" is harmless *only* after one
  /// genuinely succeeded — otherwise it is a half-built singleton that
  /// no amount of retrying can finish.
  bool _initConfirmed = false;
  Future<void>? _initFuture;
  String? _firstInitError;
  Timer? _retryTimer;
  PlayerState? _last;

  /// Whether a link has ever come up, which is what makes a later retry
  /// obey [reconnectInterval] instead of [retryInterval].
  bool _linkedOnce = false;

  /// Delay before the next handshake attempt; grows while the link stays
  /// down and is reset the moment one comes up.
  Duration _retryDelay = Duration.zero;

  /// How often a handshake that is not up yet is re-attempted while the
  /// presence is enabled and no link has been up yet.
  final Duration retryInterval;

  /// The retry interval once a link has been up and lost again; past the
  /// window in which Discord refuses a fresh handshake.
  final Duration reconnectInterval;

  /// Ceiling the retry delay backs off to.
  final Duration maxRetryInterval;

  /// How long a track may stay paused before its presence is withdrawn.
  Duration pauseHideAfter;

  Duration get _retryFloor => _linkedOnce ? reconnectInterval : retryInterval;

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
    _forgetPresence();
    if (_enabled) {
      unawaited(shutdown());
    }
  }

  /// Toggles presence, tearing down the IPC connection when off.
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _forgetPresence();
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

  /// Updates how long a paused track stays on Discord before being
  /// withdrawn. Re-evaluates the current presence so a change takes
  /// effect immediately.
  void setPauseHideMinutes(int minutes) {
    final value = Duration(minutes: minutes);
    if (pauseHideAfter == value) return;
    pauseHideAfter = value;
    notifyListeners();
    final last = _last;
    if (_enabled && last != null) unawaited(update(last));
  }

  /// Switches the status-line mode (persisted by the caller). The dedup
  /// key is forgotten so the very next update re-pushes under the new
  /// mode instead of waiting for the track to change.
  void setStatusText(DiscordStatusText value) {
    if (_statusText == value) return;
    _statusText = value;
    _forgetPresence();
    final last = _last;
    if (_enabled && last != null) unawaited(update(last));
    notifyListeners();
  }

  /// Forgets the pushed presence: content and position bookkeeping,
  /// so the next update re-sends even when nothing changed and the
  /// resync cadence starts from a clean slate (used after reconnects).
  void invalidate() {
    _forgetPresence();
  }

  void _forgetPresence() {
    _dedup = '';
    _pushedPosMs = 0;
    _pushedPlaying = false;
    _pushedAt = DateTime.now();
    _pausedAt = null;
    _pausedTrackId = null;
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
      _initConfirmed = true;
    } catch (e) {
      final msg = '$e';
      // The package assigns its Dart singleton *before* standing up the
      // native client, so an attempt that failed partway leaves the
      // singleton behind and every later call answers "already been
      // initialized" even though the native side never came up. Trust
      // that message only once an initialize has actually completed:
      // that is the disable/re-enable case, where the client is set up
      // and only the link was closed. Otherwise the real cause is kept
      // and reported, instead of faking a working client that then sits
      // at "idle" until the app restarts.
      if (_initConfirmed && msg.contains('already been initialized')) {
        _initialized = true;
        return;
      }
      _initFuture = null;
      // Keep the first real cause: a later "already been initialized"
      // must not mask what actually went wrong.
      _firstInitError ??= msg;
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
    if (_connected) {
      _noteLinkUp();
      return true;
    }
    try {
      await _rpc.connect();
    } catch (e) {
      // No Discord client around (or the IPC link is refused); stay idle
      // and retry on the timer. The cause is surfaced because a bare
      // "idle" cannot tell "Discord is not running yet" apart from a
      // client that will never come up without a restart.
      _setStatus('idle: $e');
      return false;
    }
    if (_connected) _noteLinkUp();
    return _connected;
  }

  /// A handshake landed: from here on a lost link must wait out Discord's
  /// post-session refusal window before we probe again.
  void _noteLinkUp() {
    _linkedOnce = true;
    _retryDelay = _retryFloor;
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
    // Track how long the current track has been paused; presence is
    // withdrawn once it exceeds [discordPauseHideAfter].
    if (s.playing || track == null) {
      _pausedAt = null;
      _pausedTrackId = track?.videoId;
    } else if (_pausedTrackId != track.videoId) {
      _pausedAt = DateTime.now();
      _pausedTrackId = track.videoId;
    } else {
      _pausedAt ??= DateTime.now();
    }
    final pausedTooLong =
        !s.playing &&
        track != null &&
        _pausedAt != null &&
        DateTime.now().difference(_pausedAt!) >= pauseHideAfter;
    final key = pausedTooLong
        ? '${track.videoId}:hidden'
        : '${track?.videoId}:${s.playing}:${track?.rating.index}';
    if (key == _dedup && !_resyncDue(s)) return;
    if (!await _ensureConnected()) return;
    try {
      if (track == null || pausedTooLong) {
        if (_connected) {
          await _rpc.clearActivity();
        }
        _notePush(s, key);
        _setStatus('idle');
        return;
      }
      final activity = presenceActivity(s, _statusText);
      if (activity == null) return;
      await _rpc.setActivity(activity);
      _notePush(s, key);
      _setStatus('active');
    } catch (e) {
      _setStatus('idle: $e');
    }
  }

  /// True when the pushed presence no longer matches what the player
  /// reports: the position ran away from the clock the pushed start
  /// timestamp implies (a seek), or a playing session reached its
  /// periodic correction.
  bool _resyncDue(PlayerState s) {
    final sinceMs = DateTime.now().difference(_pushedAt).inMilliseconds;
    final expectedMs = _pushedPlaying ? _pushedPosMs + sinceMs : _pushedPosMs;
    if ((s.positionMs - expectedMs).abs() >
        discordSeekRealignment.inMilliseconds) {
      return true;
    }
    return _pushedPlaying && sinceMs >= discordResyncInterval.inMilliseconds;
  }

  /// Remembers what was just pushed so [_resyncDue] can tell a drift
  /// correction from a content change.
  void _notePush(PlayerState s, String key) {
    _dedup = key;
    _pushedPosMs = s.positionMs;
    _pushedPlaying = s.playing;
    _pushedAt = DateTime.now();
  }

  /// Keeps the handshake ready while the presence is enabled. A tick
  /// that finds the link up does nothing, so a healthy session pays only
  /// a timer wake-up.
  void _armRetry() {
    if (_retryDelay == Duration.zero) _retryDelay = _retryFloor;
    if (_retryTimer != null) return;
    _retryTimer = Timer(_retryDelay, () {
      _retryTimer = null;
      if (!_enabled) return;
      unawaited(_retryTick());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// One retry tick: re-attempt the handshake, then decide how long the
  /// next attempt waits. The delay only ever grows while the link is down
  /// and is dropped back to the floor as soon as one comes up, so a lost
  /// link is picked up again quickly without hammering a Discord that is
  /// mid-restart.
  Future<void> _retryTick() async {
    await _retry();
    if (!_enabled) return;
    if (_connected) {
      _retryDelay = _retryFloor;
      _armRetry();
      return;
    }
    final doubled = _retryDelay * 2;
    _retryDelay = doubled > maxRetryInterval ? maxRetryInterval : doubled;
    _armRetry();
  }

  /// Re-attempts the handshake, forgetting the last push so the fresh link
  /// re-renders the activity instead of believing it is already up.
  Future<void> _retry() async {
    if (!_enabled) {
      _cancelRetry();
      return;
    }
    if (_connected) return;
    final last = _last;
    if (last == null) return;
    // Preserve pause timing across reconnects: a flaky link must not
    // reset the 15-minute hide clock. Only the push bookkeeping is
    // forgotten so the fresh link re-renders the activity.
    _dedup = '';
    _pushedPosMs = 0;
    _pushedPlaying = false;
    _pushedAt = DateTime.now();
    await update(last);
  }

  /// Tears down the IPC connection. State is settled synchronously (so
  /// callers see the new status at once) and only the teardown awaits.
  ///
  /// The cached init future is dropped too: it holds a *completed*
  /// future, and reusing it after a disconnect would leave
  /// [_initialized] false forever, so re-enabling the presence could
  /// never hand it back — the status line would stay dead until restart.
  Future<void> shutdown() async {
    _forgetPresence();
    final wasInitialized = _initialized;
    _initialized = false;
    _initFuture = null;
    _setStatus(_enabled ? 'idle' : 'disabled');
    if (wasInitialized) {
      try {
        if (_rpc.isConnected) await _rpc.clearActivity();
      } catch (_) {}
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
