// Playback queue state, ported from Kotlin `PlayerState`/`RepeatMode`.
//
// Immutable snapshots; the controller owns mutation and emits copies.

import '../models/models.dart';

/// Queue repeat behavior.
enum RepeatMode { off, all, one }

/// Observable playback snapshot emitted by [PlayerController].
class PlayerState {
  const PlayerState({
    this.current,
    this.playing = false,
    this.stopped = false,
    this.loading = false,
    this.positionMs = 0,
    this.seekEpoch = 0,
    this.durationMs = 0,
    this.volume = 80,
    this.queue = const [],
    this.index = -1,
    this.shuffle = false,
    this.repeat = RepeatMode.off,
    this.autoplay = true,
    this.error,
  });

  /// Currently loaded track, if any.
  final Track? current;
  final bool playing;

  /// True after an explicit stop (session cleared).
  final bool stopped;

  /// True while the next stream URL is resolving/starting.
  final bool loading;
  final int positionMs;

  /// Incremented on every seek so sliders can re-anchor.
  final int seekEpoch;

  /// Track duration in milliseconds (catalog value until the engine reports).
  final int durationMs;
  final int volume;
  final List<Track> queue;
  final int index;
  final bool shuffle;
  final RepeatMode repeat;
  final bool autoplay;
  final String? error;

  PlayerState copyWith({
    Track? Function()? current,
    bool? playing,
    bool? stopped,
    bool? loading,
    int? positionMs,
    int? seekEpoch,
    int? durationMs,
    int? volume,
    List<Track>? queue,
    int? index,
    bool? shuffle,
    RepeatMode? repeat,
    bool? autoplay,
    String? Function()? error,
  }) {
    return PlayerState(
      current: current != null ? current() : this.current,
      playing: playing ?? this.playing,
      stopped: stopped ?? this.stopped,
      loading: loading ?? this.loading,
      positionMs: positionMs ?? this.positionMs,
      seekEpoch: seekEpoch ?? this.seekEpoch,
      durationMs: durationMs ?? this.durationMs,
      volume: volume ?? this.volume,
      queue: queue ?? this.queue,
      index: index ?? this.index,
      shuffle: shuffle ?? this.shuffle,
      repeat: repeat ?? this.repeat,
      autoplay: autoplay ?? this.autoplay,
      error: error != null ? error() : this.error,
    );
  }
}
