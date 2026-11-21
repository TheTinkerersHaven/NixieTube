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
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart';

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
  int _lastSeekEpoch = -1;
  String? _lastTrackId;
  bool _lastPlaying = false;

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
    _lastSeekEpoch = -1;
    _lastTrackId = null;
    mediaItem.add(null);
    queue.add(const []);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

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
    // Position is only broadcast when it jumps (a seek, a new track, a
    // pause): clients project the live position from it themselves, and a
    // per-tick broadcast would redraw the notification twice a second.
    final seeked = s.seekEpoch != _lastSeekEpoch;
    final trackChanged = track?.videoId != _lastTrackId;
    final playingChanged = s.playing != _lastPlaying;
    _lastSeekEpoch = s.seekEpoch;
    _lastTrackId = track?.videoId;
    _lastPlaying = s.playing;

    final signature = playbackSignature(
      state: s,
      mediaKey: mediaKey,
      queueKey: queueKey,
    );
    if (signature == _playbackKey) return;
    _playbackKey = signature;

    playbackState.add(
      playbackStateFor(
        s,
        updatePosition: seeked || trackChanged || playingChanged,
      ),
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
}

/// Forward/rewind step, matching the system's 10s default.
const forwardInterval = Duration(seconds: 10);

/// The media session's [MediaItem] for [track]. [durationMs] wins over
/// the catalog length when the backend reported one, so the seek bar
/// matches what the player actually has.
MediaItem mediaItemFor(Track track, int durationMs) {
  final art = track.displayArtwork;
  final artUri = (art != null && art.startsWith('http')) ? Uri.tryParse(art) : null;
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

/// The notification's buttons for [s]: previous, play/pause, stop, next,
/// each omitted when the transport cannot act on it.
List<MediaControl> mediaControlsFor(PlayerState s) => [
  if (canMoveBy(s, -1)) MediaControl.skipToPrevious,
  s.playing ? MediaControl.pause : MediaControl.play,
  MediaControl.stop,
  if (canMoveBy(s, 1)) MediaControl.skipToNext,
];

/// Builds the session's [PlaybackState] for [s]. [updatePosition] is
/// false for the steady-state ticks a playing track emits twice a
/// second, so the position is only re-sent when it actually moved.
PlaybackState playbackStateFor(
  PlayerState s, {
  bool updatePosition = true,
  Duration? positionOverride,
}) {
  final duration = s.durationMs > 0 ? Duration(milliseconds: s.durationMs) : null;
  final controls = mediaControlsFor(s);
  // Up to three buttons in the compact view, and never the stop button.
  final compact = <int>[];
  for (var i = 0; i < controls.length && compact.length < 3; i++) {
    if (controls[i].action != MediaAction.stop) compact.add(i);
  }
  final playing = s.playing && processingStateOf(s) == AudioProcessingState.ready;
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
    updatePosition: positionOverride ??
        (updatePosition ? Duration(milliseconds: s.positionMs) : Duration.zero),
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
/// tick that changes nothing does not re-broadcast the state.
String playbackSignature({
  required PlayerState state,
  required String mediaKey,
  required String queueKey,
}) => [
  mediaKey,
  queueKey,
  state.index,
  state.playing,
  state.loading,
  state.stopped,
  state.error != null,
  state.repeat.name,
  state.shuffle,
].join('|');

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
  return backgroundAudio;
}

/// Drops the media session (and its notification).
Future<void> stopBackgroundAudio() async {
  final handler = backgroundAudio;
  backgroundAudio = null;
  await handler?.disconnect();
}