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

  /// Sends one watchtime beacon, logging failures to the watchtime log
  /// file (successes stay silent).
  Future<void> sendWatchtime(WatchtimeBeacon beacon) async {
    // Re-check the cookie session's validity (cached for 5
    // min) so an expired LOGIN_INFO surfaces in the UI.
    await refreshLoginValidity();

    bool ok = false;
    try {
      ok = await tube.reportWatchtime(beacon);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'watchtime: EXCEPTION ${beacon.state.wireName} ${beacon.videoId} '
          '${e.runtimeType}',
        );
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
          'watchtime: FAILED ${beacon.state.wireName} ${beacon.videoId} '
          'cmt=${beacon.currentSec} auth=$tag $tokenTag',
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
    final prevCpn = _lastWatchCpn;
    try {
      final vid = s.current?.videoId;
      if (vid != null && vid != prevVid) {
        await _reportTrackSwitch(s, vid);
      } else if (vid != null && vid == prevVid && prevCpn != null) {
        await _reportSameTrack(s, vid, prevCpn, prevPlay, prevStop);
      }
      _previousPlaying = s.playing;
      _previousStopped = s.stopped;
    } catch (_) {}
  }

  /// Reports the end of the previous track and the start of the new one.
  Future<void> _reportTrackSwitch(PlayerState s, String vid) async {
    final posSec = s.positionMs / 1000.0;
    final durSec = s.durationMs / 1000.0;
    final playlistId = s.current?.playlistId;
    final prevVid = _lastReportedVideoId;
    final prevCpn = _lastWatchCpn;
    if (prevVid != null && prevCpn != null && !s.stopped) {
      // Report where the previous track actually stopped, not the
      // new track's ~0 position.
      await sendWatchtime(
        WatchtimeBeacon(
          videoId: prevVid,
          cpn: prevCpn,
          startSec: _lastWatchSegmentStartSec,
          currentSec: _lastReportedPositionMs / 1000.0,
          state: WatchtimeState.paused,
          durationSec: _lastWatchDurationSec,
          playlistId: _lastWatchPlaylistId,
        ),
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
      WatchtimeBeacon(
        videoId: vid,
        cpn: cpn,
        startSec: 0.0,
        currentSec: posSec,
        state: WatchtimeState.playing,
        durationSec: durSec,
        playlistId: playlistId,
      ),
    );
  }

  /// Reports the play/pause/stop transition or heartbeat of the track
  /// that keeps playing.
  Future<void> _reportSameTrack(
    PlayerState s,
    String vid,
    String cpn,
    bool prevPlay,
    bool prevStop,
  ) async {
    final posSec = s.positionMs / 1000.0;
    final durSec = s.durationMs / 1000.0;
    final playlistId = s.current?.playlistId;
    if (s.playing && !prevPlay) {
      _lastWatchSegmentStartSec = _lastReportedPositionMs / 1000.0;
      _lastReportedPositionMs = s.positionMs;
      await sendWatchtime(
        WatchtimeBeacon(
          videoId: vid,
          cpn: cpn,
          startSec: _lastWatchSegmentStartSec,
          currentSec: posSec,
          state: WatchtimeState.playing,
          durationSec: durSec,
          playlistId: playlistId,
        ),
      );
      return;
    }
    if ((!s.playing && prevPlay && !s.stopped) || (s.stopped && !prevStop)) {
      _lastReportedPositionMs = s.positionMs;
      await sendWatchtime(
        WatchtimeBeacon(
          videoId: vid,
          cpn: cpn,
          startSec: _lastWatchSegmentStartSec,
          currentSec: posSec,
          state: WatchtimeState.paused,
          durationSec: durSec,
          playlistId: playlistId,
        ),
      );
      _lastWatchSegmentStartSec = posSec;
      return;
    }
    if (!s.playing) {
      _lastReportedPositionMs = s.positionMs;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProgressMs < _reportHeartbeatMs) {
      _lastReportedPositionMs = s.positionMs;
      return;
    }
    _lastProgressMs = now;
    _lastReportedPositionMs = s.positionMs;
    await sendWatchtime(
      WatchtimeBeacon(
        videoId: vid,
        cpn: cpn,
        startSec: _lastWatchSegmentStartSec,
        currentSec: posSec,
        state: WatchtimeState.playing,
        durationSec: durSec,
        playlistId: playlistId,
      ),
    );
    _lastWatchSegmentStartSec = posSec;
  }
}
