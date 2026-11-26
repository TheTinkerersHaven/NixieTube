// Discord Rich Presence on Android via the official Discord Social SDK
// (discord_partner_sdk.aar in android/app/libs). No OAuth and no user
// token are involved: the installed Discord app hosts an AIDL RPC service
// (com.discord.socialsdk.rpc.IDiscordRpcService) that speaks the same JSON
// protocol as the desktop IPC socket, so presence is published as the
// application id alone. The Kotlin side (DiscordSdkPlugin.kt) binds the
// service; this file speaks the frames over a method channel.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/services.dart';

import '../core/player/player_state.dart';
import 'discord.dart';
import 'log.dart';

const _log = TaggedLog('discord-sdk');

const MethodChannel _methodChannel = MethodChannel('nixietube/discord_sdk');
const MethodChannel _eventsChannel = MethodChannel(
  'nixietube/discord_sdk/events',
);

/// One SET_ACTIVITY frame payload (the JSON string the Discord app's RPC
/// service expects — identical to the desktop IPC frame body, minus the
/// 8-byte header which AIDL replaces).
String setActivityFrameJson({
  required int processId,
  required DiscordActivity? activity,
  required String nonce,
}) => jsonEncode({
  'cmd': 'SET_ACTIVITY',
  'nonce': nonce,
  'args': {'pid': processId, 'activity': activity?.toJson()},
});

/// How often a failed connect (Discord app missing or not running) is
/// retried while presence is enabled.
const discordSdkRetryInterval = Duration(seconds: 10);

/// Android implementation of [DiscordPresenceBase] on top of the Discord
/// app's RPC service, reached through the Social SDK AAR's AIDL interfaces.
class DiscordSdkPresence extends DiscordPresenceBase {
  DiscordSdkPresence({
    required String appId,
    bool enabled = false,
    DiscordStatusText statusText = DiscordStatusText.app,
    this.pauseHideAfter = discordPauseHideAfter,
    this.retryInterval = discordSdkRetryInterval,
    bool supported = true,
  }) {
    _appId = appId;
    _enabled = enabled && supported;
    _statusText = statusText;
    _supported = supported;
    if (!supported) _status = discordUnsupportedStatus;
  }

  late final String _appId;
  late bool _enabled;
  late DiscordStatusText _statusText;
  late final bool _supported;

  @override
  Duration pauseHideAfter;

  final Duration retryInterval;

  String _status = 'disabled';
  bool _connected = false;
  bool _started = false;
  Timer? _retryTimer;
  int _nonce = 0;
  String? _lastFrame;
  DateTime? _pausedAt;
  PlayerState? _last;

  @override
  bool get supported => _supported;

  @override
  String get status => _status;

  @override
  bool get enabled => _enabled;

  @override
  String get appId => _appId;

  @override
  DiscordStatusText get statusText => _statusText;

  void _setStatus(String value) {
    if (_status != value) {
      _status = value;
      notifyListeners();
    }
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _eventsChannel.setMethodCallHandler(_onEvent);
    if (_enabled) await _connect();
  }

  Future<dynamic> _onEvent(MethodCall call) async {
    final event = call.arguments;
    if (event is! List || event.isEmpty) return null;
    switch (event[0]) {
      case 'connected':
        _connected = true;
        _retryTimer?.cancel();
        _retryTimer = null;
        _setStatus('connected');
        // Re-push the current track on the fresh link.
        if (_last != null) unawaited(update(_last!));
        break;
      case 'closed':
        _connected = false;
        _setStatus('Discord app closed the link');
        _scheduleRetry();
        break;
      case 'frame':
        // READY / events from the app are not needed for presence.
        break;
    }
    return null;
  }

  Future<void> _connect() async {
    if (_connected) return;
    final installed =
        await _methodChannel.invokeMethod<bool>('isInstalled') ?? false;
    if (!installed) {
      _setStatus('Discord app not installed');
      _scheduleRetry();
      return;
    }
    _setStatus('connecting');
    final ok = await _methodChannel.invokeMethod<bool>('connect', {
      'appId': _appId,
    });
    if (ok == true) {
      _connected = true;
      _setStatus('connected');
      if (_last != null) unawaited(update(_last!));
    } else {
      _connected = false;
      _setStatus('Discord app not running');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_enabled || _connected || _retryTimer != null) return;
    _retryTimer = Timer(retryInterval, () {
      _retryTimer = null;
      unawaited(_connect());
    });
  }

  Future<void> _send(DiscordActivity? activity) async {
    final frame = setActivityFrameJson(
      processId: pid,
      activity: activity,
      nonce: '$pid-${_nonce++}',
    );
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    try {
      await _methodChannel.invokeMethod('sendFrame', {'json': frame});
    } catch (e) {
      _log.w('sendFrame failed: $e');
    }
  }

  @override
  Future<void> update(PlayerState s) async {
    _last = s;
    if (!_enabled || !_supported) return;
    if (!_connected) {
      unawaited(_connect());
      return;
    }
    final track = s.current;
    if (track == null) {
      await _send(null);
      return;
    }
    if (s.playing) {
      _pausedAt = null;
    } else if (_pausedAt == null) {
      _pausedAt = DateTime.now();
    } else if (DateTime.now().difference(_pausedAt!) > pauseHideAfter) {
      await _send(null);
      return;
    }
    final activity = presenceActivity(s, _statusText);
    await _send(activity);
  }

  @override
  void setEnabled(bool value) {
    if (!supported) {
      _setStatus(discordUnsupportedStatus);
      return;
    }
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _lastFrame = null;
      unawaited(_send(null));
      unawaited(_methodChannel.invokeMethod('disconnect'));
      _connected = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _setStatus('disabled');
    } else {
      unawaited(_connect());
    }
  }

  @override
  void setAppId(String value) {
    if (_appId == value) return;
    _appId = value;
    _lastFrame = null;
    unawaited(_methodChannel.invokeMethod('disconnect'));
    _connected = false;
    if (_enabled) unawaited(_connect());
  }

  @override
  void setStatusText(DiscordStatusText mode) {
    _statusText = mode;
    _lastFrame = null; // re-push with the new status line
    notifyListeners();
    final last = _last;
    if (_enabled && _connected && last != null) unawaited(update(last));
  }

  @override
  void setPauseHideMinutes(int minutes) {
    pauseHideAfter = Duration(minutes: minutes);
  }

  @override
  Future<void> shutdown() async {
    _lastFrame = null;
    await _send(null);
    await _methodChannel.invokeMethod('disconnect');
    _connected = false;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _eventsChannel.setMethodCallHandler(null);
    unawaited(_methodChannel.invokeMethod('disconnect'));
    super.dispose();
  }
}
