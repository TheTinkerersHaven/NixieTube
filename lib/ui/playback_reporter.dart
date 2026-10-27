// Watchtime (history) reporting extracted from AppState.
//
// YouTube ties a watch to a client playback nonce (cpn) and expects
// beacons for track switches, play/pause/stop transitions and a
// periodic heartbeat. None of this touches UI state, so it lives here
// instead of in the AppState god-class.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/sys_config.dart';

const _loginCheckIntervalMs = 300000;
const _reportHeartbeatMs = 10000;

class PlaybackReporter {
  PlaybackReporter({
    required this.tube,
    required this.config,
    required this.notify,
  });

  final InnerTube tube;
  final SysConfig config;
  final void Function() notify;

  String? _lastReportedVideoId;
  bool _previousPlaying = false;
  bool _previousStopped = false;
  int _lastProgressMs = 0;
  int _lastReportedPositionMs = 0;
  String? _lastWatchCpn;
  double _lastWatchSegmentStartSec = 0.0;
  double _lastWatchDurationSec = 0.0;
  String? _lastWatchPlaylistId;

  int loginCheckedAt = 0;
  bool loginValid = true;

  /// Client playback nonce for watchtime beacons: 16 URL-safe chars,
  /// stable for one track playback (YouTube ties a watch to its cpn).
  String newWatchCpn() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final r = Random();
    return String.fromCharCodes(
      List.generate(16, (_) => chars.codeUnitAt(r.nextInt(chars.length))),
    );
  }

  /// Re-checks the saved cookie session's validity when the cached
  /// verdict is stale (at most every [_loginCheckIntervalMs]).
  /// stats/* beacons return 204 (blind ack) regardless of auth, so
  /// without this check an expired LOGIN_INFO would go unnoticed:
  /// beacons "succeed" while YouTube records nothing. Logs a warning
  /// and notifies listeners when the verdict flips. No-op when no
  /// cookie session is saved.
  Future<void> refreshLoginValidity() async {
    if ((tube.auth.cookie ?? '').isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - loginCheckedAt <= _loginCheckIntervalMs) return;
    loginCheckedAt = now;
    final ok = await tube.verifyLogin();
    if (!ok) {
      if (kDebugMode) {
        debugPrint(
          'watchtime: LOGIN_INFO expired (logged_in=0): '
          'stats/* beacons will not record history. Re-authenticate in '
          'Settings → Integrations.',
        );
      }
    }
    if (ok != loginValid) {
      loginValid = ok;
      notify();
    }
  }

  /// Sends one watchtime beacon for [videoId], logging failures to the
  /// watchtime log file (successes stay silent).
  Future<void> sendWatchtime(
    String videoId,
    String cpn,
    double startSec,
    double currentSec,
    String state,
    double durationSec, [
    String? playlistId,
  ]) async {
    // Re-check the cookie session's validity (cached for 5
    // min) so an expired LOGIN_INFO surfaces in the UI.
    await refreshLoginValidity();

    bool ok = false;
    try {
      ok = await tube.reportWatchtime(
        videoId,
        cpn,
        startSec,
        currentSec,
        state,
        durationSec,
        playlistId,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('watchtime: EXCEPTION $state $videoId ${e.runtimeType}');
      }
      return;
    }
    if (!ok) {
      if (kDebugMode) {
        final session = tube.auth;
        final cookiePresent = (session.cookie ?? '').isNotEmpty;
        final tokenPresent = (session.sessionToken ?? '').isNotEmpty;
        final tag = cookiePresent ? 'COOKIE' : 'ANONYMOUS';
        final tokenTag = tokenPresent ? 'TOKEN_YES' : 'TOKEN_NO';
        debugPrint(
          'watchtime: FAILED $state $videoId cmt=$currentSec auth=$tag '
          '$tokenTag',
        );
      }
    }
  }

  /// Mirrors the player-state reporting block: track switches emit
  /// paused (previous) + playing (new) beacons, play/pause/stop
  /// transitions emit their own, and steady playback heartbeats every
  /// [_reportHeartbeatMs]. Never touches UI state.
  Future<void> report(PlayerState s) async {
    final prevVid = _lastReportedVideoId;
    final prevPlay = _previousPlaying;
    final prevStop = _previousStopped;
    final progMs = _lastProgressMs;
    final prevPosMs = _lastReportedPositionMs;
    final prevCpn = _lastWatchCpn;
    final prevSegStartSec = _lastWatchSegmentStartSec;
    final prevDurSec = _lastWatchDurationSec;
    final prevPlaylistId = _lastWatchPlaylistId;
    try {
      final vid = s.current?.videoId;
      final posSec = s.positionMs / 1000.0;
      final durSec = s.durationMs / 1000.0;
      final playlistId = s.current?.playlistId;
      if (vid != null && vid != prevVid) {
        if (prevVid != null && prevCpn != null && !s.stopped) {
          // Report where the previous track actually stopped, not the
          // new track's ~0 position.
          await sendWatchtime(
            prevVid,
            prevCpn,
            prevSegStartSec,
            prevPosMs / 1000.0,
            'paused',
            prevDurSec,
            prevPlaylistId,
          );
        }
        final cpn = newWatchCpn();
        _lastReportedVideoId = vid;
        _lastWatchCpn = cpn;
        _lastWatchSegmentStartSec = 0.0;
        _lastWatchDurationSec = durSec;
        _lastWatchPlaylistId = playlistId;
        _lastReportedPositionMs = s.positionMs;
        await sendWatchtime(
          vid,
          cpn,
          0.0,
          posSec,
          'playing',
          durSec,
          playlistId,
        );
      } else if (vid != null && vid == prevVid && prevCpn != null) {
        if (s.playing && !prevPlay) {
          _lastWatchSegmentStartSec = prevPosMs / 1000.0;
          _lastReportedPositionMs = s.positionMs;
          await sendWatchtime(
            vid,
            prevCpn,
            prevSegStartSec,
            posSec,
            'playing',
            durSec,
            playlistId,
          );
        } else if (!s.playing && prevPlay && !s.stopped) {
          _lastReportedPositionMs = s.positionMs;
          await sendWatchtime(
            vid,
            prevCpn,
            prevSegStartSec,
            posSec,
            'paused',
            durSec,
            playlistId,
          );
          _lastWatchSegmentStartSec = posSec;
        } else if (s.stopped && !prevStop) {
          _lastReportedPositionMs = s.positionMs;
          await sendWatchtime(
            vid,
            prevCpn,
            prevSegStartSec,
            posSec,
            'paused',
            durSec,
            playlistId,
          );
          _lastWatchSegmentStartSec = posSec;
        } else if (s.playing) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - progMs >= _reportHeartbeatMs) {
            _lastProgressMs = now;
            _lastReportedPositionMs = s.positionMs;
            await sendWatchtime(
              vid,
              prevCpn,
              prevSegStartSec,
              posSec,
              'playing',
              durSec,
              playlistId,
            );
            _lastWatchSegmentStartSec = posSec;
          } else {
            _lastReportedPositionMs = s.positionMs;
          }
        } else {
          _lastReportedPositionMs = s.positionMs;
        }
      }
      _previousPlaying = s.playing;
      _previousStopped = s.stopped;
    } catch (_) {}
  }
}
