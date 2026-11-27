// The OS media session (phones).
//
// On Android and iOS a backgrounded app is suspended, so playback that
// is not attached to a media session stops the moment the screen locks
// or another app comes forward. Registering one fixes both halves of
// that: the session is backed by a foreground service (Android) or the
// `audio` background mode (iOS) that keeps the process alive, and it is
// what draws the notification, the lock-screen card, the Bluetooth and
// wired-headset buttons, Android Auto and Wear controls.
//
// The session is a mirror of [PlayerController], never a second source of
// truth: player states are translated into [PlaybackState]/[MediaItem]
// broadcasts, and requests that come back from the OS are forwarded to
// the controller. Nothing here runs on a desktop — MPRIS and the tray
// cover that job there.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import '../core/models/models.dart';
import '../core/player/player_controller.dart';
import '../core/player/player_state.dart';
import 'log.dart';

const _log = TaggedLog('media');

/// Notification channel the playback notification lives in. The id is
/// stable across builds so Android keeps the user's channel settings.
const androidNotificationChannelId = 'nixietube.playback';

/// Human-readable channel name shown in the system settings.
const androidNotificationChannelName = 'Now playing';

/// Custom media action backing the notification's like button.
const likeActionName = 'nixietube_like';

/// Translates the player into the media session's vocabulary.
///
/// Pure: [mediaItemFor], [processingStateOf], [mediaControlsFor] and
/// [playbackSignature] are top-level so the mapping is testable without
/// a platform.
class PlaybackAudioHandler extends BaseAudioHandler {
  PlaybackAudioHandler(this._controller);

  final PlayerController _controller;

  StreamSubscription<PlayerState>? _sub;
  bool _connected = false;

  String _mediaKey = '';
  String _queueKey = '';
  String _playbackKey = '';

  /// Position the last [playbackState] emission carried, and when it went
  /// out. The OS projects the live position from those two, so a later
  /// state is compared against them to notice a seek.
  Duration _sentPosition = Duration.zero;
  DateTime? _sentAt;

  /// Whether the notification shows a like button, and what tapping it
  /// does. Wired by [connectRatings] once the app state exists.
  bool Function()? _canRate;
  Future<void> Function(String videoId, RatingStatus rating)? _onLike;

  /// Connects the notification's like button to [onLike].
  ///
  /// [canRate] is asked on every player update, so the button follows
  /// sign-in and appears on the next state the session mirrors.
  void connectRatings({
    required bool Function() canRate,
    required Future<void> Function(String videoId, RatingStatus rating) onLike,
  }) {
    _canRate = canRate;
    _onLike = onLike;
    // The signature includes the rating flag, so this re-sends the
    // state and the button appears or disappears right away.
    if (_connected) _onState(_controller.state);
  }

  /// Re-sends the current state even when nothing about it changed.
  ///
  /// Used after the notification permission is granted: Android drops the
  /// foreground-service notification while it is denied and draws it
  /// again on the next update, which this forces.
  void repost() {
    if (!_connected) return;
    _mediaKey = '';
    _queueKey = '';
    _playbackKey = '';
    _onState(_controller.state);
  }

  /// Starts mirroring the player. Idempotent: a second call is a no-op.
  void connect() {
    if (_connected) return;
    _connected = true;
    _sub = _controller.states.listen(_onState);
    _onState(_controller.state);
  }

  /// Stops mirroring the player and takes the notification down.
  Future<void> disconnect() async {
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    _mediaKey = '';
    _queueKey = '';
    _playbackKey = '';
    _sentAt = null;
    mediaItem.add(null);
    queue.add(const []);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  /// Closes the app for good: playback stops and the notification is
  /// taken down, so the notification panel ends in the same state a
  /// fully closed app leaves behind. Unlike [disconnect] the mirror
  /// stays connected — when the engine outlives the activity (the app
  /// was reopened before the process was reaped) the session picks up
  /// again on the next play.
  Future<void> closeForGood() async {
    _controller.stop();
    mediaItem.add(null);
    queue.add(const []);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  /// The task was removed (the app was swiped away or closed): close
  /// for good instead of leaving the notification up.
  @override
  Future<void> onTaskRemoved() async => closeForGood();

  void _onState(PlayerState s) {
    if (!_connected) return;
    final track = s.current;

    // --- now playing ---------------------------------------------------
    // Rebuilt only when the track, its length or its cover changes: the
    // 500ms position ticks must not re-send the artwork.
    final mediaKey = track == null
        ? ''
        : '${track.videoId}|${s.durationMs}|${track.displayArtwork ?? ''}';
    if (mediaKey != _mediaKey) {
      _mediaKey = mediaKey;
      mediaItem.add(track == null ? null : mediaItemFor(track, s.durationMs));
    }

    // --- queue ---------------------------------------------------------
    // Ids only: a few hundred cheap strings, and the OS reads them
    // lazily. [PlaybackState.queueIndex] keeps the position in step.
    final queueKey = s.queue.map((t) => t.videoId).join(',');
    if (queueKey != _queueKey) {
      _queueKey = queueKey;
      queue.add([
        for (final t in s.queue) mediaItemFor(t, t.durationSec * 1000),
      ]);
    }

    // --- playback state ------------------------------------------------
    // The signature changes only for something the notification shows, so
    // a state is emitted only when it matters. Every emission carries the
    // real position: [PlaybackState.updatePosition] is the position at
    // [updateTime], and clients project the live value from there, so a
    // zero would jump the seek bar back to the start.
    //
    // That projection is also why an unchanged signature is not enough to
    // skip an emission: a seek changes nothing the signature covers, and
    // the OS would keep projecting the pre-seek position as if the track
    // were still running from there. A position that no longer matches
    // what the last emission implies re-sends the state.
    final canRate = _canRate?.call() ?? false;
    final signature = playbackSignature(
      state: s,
      mediaKey: mediaKey,
      queueKey: queueKey,
      canRate: canRate,
    );
    if (signature == _playbackKey && !_positionDrifted(s)) return;
    _playbackKey = signature;
    _sentPosition = Duration(milliseconds: s.positionMs);
    _sentAt = DateTime.now();

    playbackState.add(playbackStateFor(s, canRate: canRate));
  }

  /// Whether [s]'s position has left the window the last emission
  /// implies, which means the OS is projecting a position the player no
  /// longer has (a seek, or a stream restarting).
  bool _positionDrifted(PlayerState s) {
    final at = _sentAt;
    if (at == null) return true;
    return positionDrifted(
      sent: _sentPosition,
      elapsed: DateTime.now().difference(at),
      live: Duration(milliseconds: s.positionMs),
      playing: s.playing && processingStateOf(s) == AudioProcessingState.ready,
    );
  }

  // --- requests from the OS -------------------------------------------

  @override
  Future<void> play() async => _controller.play();

  @override
  Future<void> pause() async => _controller.pause();

  /// Stops playback and takes the notification down. The player emits
  /// the matching stopped state, which is what removes the notification,
  /// so [BaseAudioHandler.stop]'s wait is not needed.
  @override
  Future<void> stop() async {
    _controller.stop();
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    _controller.seekTo(position.inMilliseconds);
  }

  @override
  Future<void> fastForward() async {
    await seek(_targetFrom(forwardInterval));
  }

  @override
  Future<void> rewind() async {
    await seek(_targetFrom(-forwardInterval));
  }

  /// Seeks by [delta] from the current position, clamped by the
  /// controller.
  Duration _targetFrom(Duration delta) {
    final current = playbackState.value.position;
    final target = current + delta;
    return target < Duration.zero ? Duration.zero : target;
  }

  @override
  Future<void> skipToNext() async => _controller.next();

  @override
  Future<void> skipToPrevious() async => _controller.previous();

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < _controller.state.queue.length) {
      _controller.playAt(index);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _controller.setRepeat(repeatModeOf(repeatMode));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _controller.setShuffle(shuffleMode != AudioServiceShuffleMode.none);
  }

  /// The notification's like button toggles the current track's rating.
  /// Unknown names fall through to the base handler.
  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == likeActionName) {
      final track = _controller.state.current;
      final onLike = _onLike;
      if (track != null && onLike != null) {
        final next = track.rating == RatingStatus.like
            ? RatingStatus.indifferent
            : RatingStatus.like;
        await onLike(track.videoId, next);
      }
      return null;
    }
    return super.customAction(name, extras);
  }
}

/// Forward/rewind step, matching the system's 10s default.
const forwardInterval = Duration(seconds: 10);

/// The media session's [MediaItem] for [track]. [durationMs] wins over
/// the catalog length when the backend reported one, so the seek bar
/// matches what the player actually has.
MediaItem mediaItemFor(Track track, int durationMs) {
  final art = track.displayArtwork;
  final artUri = (art != null && art.startsWith('http'))
      ? Uri.tryParse(art)
      : null;
  return MediaItem(
    id: track.videoId,
    title: track.title,
    artist: track.artistNames().isEmpty ? null : track.artistNames(),
    album: track.album?.name,
    duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
    artUri: artUri,
  );
}

/// The session's processing state for [s].
AudioProcessingState processingStateOf(PlayerState s) {
  if (s.stopped || s.current == null) return AudioProcessingState.idle;
  if (s.error != null) return AudioProcessingState.error;
  if (s.loading) return AudioProcessingState.buffering;
  return AudioProcessingState.ready;
}

/// Whether the transport can move [offset] queue entries from [s]'s
/// position: the head blocks "previous" until the track restarts, and
/// the tail only blocks "next" when nothing can follow (no autoplay, no
/// repeat, end of the queue).
bool canMoveBy(PlayerState s, int offset) {
  if (s.current == null) return false;
  final target = s.index + offset;
  if (target >= 0 && target < s.queue.length) return true;
  if (offset > 0) return s.autoplay || s.repeat != RepeatMode.off;
  return false;
}

/// The notification's buttons for [s]: previous, play/pause, next, and —
/// when [canRate] — a like/unlike button. Each is omitted when the
/// transport cannot act on it. There is deliberately no stop button: the
/// notification is taken down when playback stops, and a stop control
/// would only crowd the row.
List<MediaControl> mediaControlsFor(PlayerState s, {bool canRate = false}) => [
  if (canMoveBy(s, -1)) MediaControl.skipToPrevious,
  s.playing ? MediaControl.pause : MediaControl.play,
  if (canMoveBy(s, 1)) MediaControl.skipToNext,
  if (canRate && s.current != null)
    likeControl(liked: s.current!.rating == RatingStatus.like),
];

/// The custom notification button that likes or unlikes the current
/// track. [liked] only changes the label; the icon stays a thumb up.
MediaControl likeControl({required bool liked}) => MediaControl.custom(
  androidIcon: 'drawable/ic_nixietube_thumb_up',
  label: liked ? 'Unlike' : 'Like',
  name: likeActionName,
  extras: {'liked': liked},
);

/// Builds the session's [PlaybackState] for [s]. [positionOverride]
/// replaces the player's position for callers that need a fixed value;
/// it defaults to the live position, which is what the platform expects.
PlaybackState playbackStateFor(
  PlayerState s, {
  Duration? positionOverride,
  bool canRate = false,
}) {
  final duration = s.durationMs > 0
      ? Duration(milliseconds: s.durationMs)
      : null;
  final controls = mediaControlsFor(s, canRate: canRate);
  // Up to three buttons in the compact view, and never the stop button.
  final compact = <int>[];
  for (var i = 0; i < controls.length && compact.length < 3; i++) {
    if (controls[i].action != MediaAction.stop) compact.add(i);
  }
  final playing =
      s.playing && processingStateOf(s) == AudioProcessingState.ready;
  return PlaybackState(
    processingState: processingStateOf(s),
    playing: playing,
    controls: controls,
    androidCompactActionIndices: compact,
    systemActions: duration == null
        ? const {MediaAction.seek}
        : const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
    updatePosition: positionOverride ?? Duration(milliseconds: s.positionMs),
    bufferedPosition: Duration(milliseconds: s.positionMs),
    speed: 1.0,
    queueIndex: s.index >= 0 ? s.index : null,
    repeatMode: switch (s.repeat) {
      RepeatMode.one => AudioServiceRepeatMode.one,
      RepeatMode.all => AudioServiceRepeatMode.all,
      RepeatMode.off => AudioServiceRepeatMode.none,
    },
    shuffleMode: s.shuffle
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none,
  );
}

/// Maps the session's repeat mode back onto the player's.
RepeatMode repeatModeOf(AudioServiceRepeatMode mode) => switch (mode) {
  AudioServiceRepeatMode.one => RepeatMode.one,
  AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => RepeatMode.all,
  AudioServiceRepeatMode.none => RepeatMode.off,
};

/// Identity of everything the notification shows, so a 500ms position
/// tick that changes nothing does not re-broadcast the state. [canRate]
/// and the current track's rating change the like button.
String playbackSignature({
  required PlayerState state,
  required String mediaKey,
  required String queueKey,
  bool canRate = false,
}) => [
  mediaKey,
  queueKey,
  state.index,
  state.playing,
  state.loading,
  state.stopped,
  state.error != null,
  state.autoplay,
  state.repeat.name,
  state.shuffle,
  state.current?.rating.name ?? '',
  canRate,
].join('|');

/// How far the player's position may sit from what the last emission
/// implies before the session re-sends it.
///
/// The player publishes its position every 500ms while the OS projects
/// the live one in between, so ordinary ticks land well inside this
/// window; a seek — or a stream restarting the track — is orders of
/// magnitude larger and must reach the OS, which otherwise keeps
/// projecting the position it was told.
const playbackDriftTolerance = Duration(milliseconds: 1200);

/// Whether [live] has left the window an emission of [sent] at that
/// moment implies, [elapsed] later, while [playing].
///
/// A paused session does not project at all, so any change there is a
/// drift by definition.
bool positionDrifted({
  required Duration sent,
  required Duration elapsed,
  required Duration live,
  required bool playing,
  Duration tolerance = playbackDriftTolerance,
}) {
  final expected = playing ? sent + elapsed : sent;
  return (live - expected).abs() > tolerance;
}

/// The live handler, once [startBackgroundAudio] has registered one.
/// Process-wide: a second session would fight the first for the OS media
/// session, and the platform allows one notification.
PlaybackAudioHandler? backgroundAudio;

/// Registers the media session for [controller] and starts mirroring it.
///
/// Best-effort: a missing plugin (tests, an unsupported host) or a
/// misconfigured manifest is logged and leaves the app playing without a
/// notification rather than blocking startup.
Future<PlaybackAudioHandler?> startBackgroundAudio(
  PlayerController controller,
) async {
  final handler = PlaybackAudioHandler(controller);
  try {
    backgroundAudio = await AudioService.init(
      builder: () => handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: androidNotificationChannelId,
        androidNotificationChannelName: androidNotificationChannelName,
        // A paused track keeps the foreground service (and therefore the
        // notification): pausing must not need a new foreground service,
        // which Android 12+ refuses to start from the background.
        androidStopForegroundOnPause: false,
        notificationColor: Color(0xFFB3261E),
      ),
    );
  } catch (error) {
    _log.w('media session unavailable: $error');
    backgroundAudio = null;
    return null;
  }
  backgroundAudio!.connect();
  unawaited(_askForNotifications());
  return backgroundAudio;
}

/// Asks for the notification permission (Android 13+).
///
/// Without it every notification is dropped, the playback one — a
/// foreground-service notification — included, so the media session
/// would run with nothing to show. A refusal is not an error: playback
/// keeps working and the notification stays hidden until the user
/// grants it from the system settings.
Future<void> _askForNotifications() async {
  const channel = MethodChannel('nixietube/permissions');
  try {
    final granted = await channel.invokeMethod<bool>('notificationsGranted');
    if (granted ?? true) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'notificationsResult' && call.arguments == true) {
        backgroundAudio?.repost();
      }
      return null;
    });
    await channel.invokeMethod<bool>('requestNotifications');
  } catch (error) {
    _log.w('notification permission unavailable: $error');
  }
}

/// Drops the media session (and its notification).
Future<void> stopBackgroundAudio() async {
  final handler = backgroundAudio;
  backgroundAudio = null;
  await handler?.disconnect();
}

/// Closes the app for good on a phone: stops playback and takes the
/// media notification down. Called when the host reports the app was
/// closed (the activity finishing) or the task was removed, so the
/// notification panel ends in the same state as a fully closed app.
Future<void> closeBackgroundAudioForGood() async {
  await backgroundAudio?.closeForGood();
}
