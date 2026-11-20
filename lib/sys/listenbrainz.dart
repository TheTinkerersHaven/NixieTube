// ListenBrainz scrobbling over the submit-listens API: a user token from
// listenbrainz.org/settings, now-playing updates on track start, and one
// scrobble per play once the standard threshold is reached (half the track
// or 4 minutes, tracks over 30 seconds). The token lives in the platform
// secret store via [SysConfig].

import 'dart:convert' show jsonEncode;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../core/models/models.dart' show Track;
import '../core/player/player_state.dart' show PlayerState;
import 'http_client.dart' show newResilientClient;
import 'lastfm.dart'
    show
        ScrobbleProgress,
        cleanScrobbleTitle,
        lastfmArtistName,
        minScrobbleDurationSec,
        scrobbleCapSec,
        seekBackToleranceMs;
import 'sys_config.dart' show SysConfig;
import 'version.dart' show appVersion;

/// ListenBrainz listens endpoint.
const listenBrainzSubmitUrl = 'https://api.listenbrainz.org/1/submit-listens';

/// User-Agent sent with ListenBrainz calls.
const _listenBrainzUserAgent =
    'NixieTube/$appVersion (https://github.com/TheTinkerersHaven/NixieTube)';

/// ListenBrainz client: now-playing updates and scrobbles.
///
/// The user token comes from Settings (stored in the secret store); all
/// network use is opt-in via `SysConfig.listenbrainzEnabled`. A
/// [ChangeNotifier] so the Settings card can watch [status].
class ListenBrainzService extends ChangeNotifier {
  ListenBrainzService({required this.config, Dio? dio})
    : _dio = dio ?? newResilientClient() {
    refreshStatus();
  }

  final SysConfig config;
  final Dio _dio;
  final ScrobbleProgress _progress = ScrobbleProgress();

  String _status = 'disabled';

  /// Short status for the Settings card: `disabled`, `token needed` or
  /// `token set`.
  String get status => _status;

  /// True when the toggle is on and a token is present.
  bool ready() =>
      config.listenbrainzEnabled && config.listenbrainzToken.trim().isNotEmpty;

  /// Recomputes [status] from the current settings.
  void refreshStatus() {
    final next = !config.listenbrainzEnabled
        ? 'disabled'
        : config.listenbrainzToken.trim().isEmpty
        ? 'token needed'
        : 'token set';
    if (next == _status) return;
    _status = next;
    notifyListeners();
  }

  /// Drops the stored token (Settings → sign out).
  void logout() {
    config.listenbrainzToken = '';
    refreshStatus();
  }

  /// Watches one player emission: now-playing on each new track, one
  /// scrobble per play once the standard threshold passes.
  Future<void> update(PlayerState s) => _handleState(s, _progress);

  Future<void> _handleState(PlayerState s, ScrobbleProgress progress) async {
    final track = s.current;
    final videoId = track?.videoId;
    if (videoId == null || videoId != progress.videoId) {
      progress.videoId = videoId;
      progress.startEpochSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      progress.lastPositionMs = 0;
      progress.scrobbled = false;
      if (videoId != null && track != null && ready()) {
        await _submit('playing_now', [_metadata(track)]);
      }
      return;
    }
    if (track != null && ready() && !progress.scrobbled) {
      await _handleProgress(s, track, progress);
    }
    progress.lastPositionMs = s.positionMs;
  }

  Future<void> _handleProgress(
    PlayerState s,
    Track track,
    ScrobbleProgress progress,
  ) async {
    if (s.positionMs < progress.lastPositionMs - seekBackToleranceMs) {
      progress.startEpochSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      progress.scrobbled = false;
      if (s.playing) {
        await _submit('playing_now', [_metadata(track)]);
      }
      return;
    }
    var durationSec = track.durationSec;
    if (durationSec <= 0) {
      final fromState = s.durationMs ~/ 1000;
      durationSec = fromState > 0 ? fromState : 0;
    }
    if (durationSec <= 0) return;
    if (durationSec <= minScrobbleDurationSec) return;
    final half = durationSec * 1000 ~/ 2;
    final thresholdMs = half < scrobbleCapSec * 1000
        ? half
        : scrobbleCapSec * 1000;
    if (s.playing && s.positionMs >= thresholdMs) {
      progress.scrobbled = await _submit('single', [
        _metadata(track, listenedAtSec: progress.startEpochSec),
      ]);
    }
  }

  /// Submits one listen (now-playing or scrobble) and reports success.
  Future<bool> _submit(
    String listenType,
    List<Map<String, dynamic>> payload,
  ) async {
    if (!ready()) return false;
    try {
      final res = await _dio.postUri<String>(
        Uri.parse(listenBrainzSubmitUrl),
        data: jsonEncode({'listen_type': listenType, 'payload': payload}),
        options: Options(
          headers: {
            'Authorization': 'Token ${config.listenbrainzToken.trim()}',
            'Content-Type': 'application/json',
            'User-Agent': _listenBrainzUserAgent,
          },
        ),
      );
      return res.statusCode != null &&
          res.statusCode! >= 200 &&
          res.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  /// One listen payload. [listenedAtSec] is present for scrobbles, not
  /// for now-playing.
  Map<String, dynamic> _metadata(Track track, {int? listenedAtSec}) {
    final album = track.album?.name.trim() ?? '';
    final payload = <String, dynamic>{
      'track_metadata': {
        'artist_name': lastfmArtistName(track),
        'track_name': cleanScrobbleTitle(track.title),
        if (album.isNotEmpty) 'release_name': album,
        'additional_info': {
          'media_player': 'NixieTube',
          'submission_client': 'NixieTube',
          'submission_client_version': appVersion,
          if (track.durationSec > 0) 'duration_ms': track.durationSec * 1000,
          if (track.videoId.isNotEmpty)
            'origin_url': 'https://youtu.be/${track.videoId}',
        },
      },
    };
    if (listenedAtSec != null) payload['listened_at'] = listenedAtSec;
    return payload;
  }

  @override
  void dispose() {
    _dio.close();
    super.dispose();
  }
}
