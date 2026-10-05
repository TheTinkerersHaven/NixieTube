// Playback engine abstraction.
//
// Shaped like just_audio's AudioPlayer (single-URL load, transport,
// position/duration, completion + error events); the desktop Linux
// implementation is just_audio itself via `just_audio_media_kit`.

/// Listener for engine playback events.
abstract interface class PlayerEngineListener {
  /// Called when the current stream plays to completion.
  void onFinished();

  /// Called when the engine reports an unrecoverable error.
  void onError(String message);
}

/// Replaceable audio backend behind [PlayerController].
abstract interface class PlayerEngine {
  /// Loads [url], replacing the current stream.
  Future<bool> play(String url);

  /// Pauses playback, keeping the stream loaded.
  Future<void> pause();

  /// Resumes a paused stream.
  Future<void> resume();

  /// Stops playback and unloads the stream.
  Future<void> stop();

  /// Seeks to an absolute position.
  Future<void> seekTo(int ms);

  /// Sets the output volume, 0..100.
  Future<void> setVolume(int volume);

  /// Current position in milliseconds, 0 when nothing is loaded.
  int positionMs();

  /// Known duration in milliseconds, 0 when unknown.
  int durationMs();

  /// True while audio is actually being produced.
  bool isPlaying();

  /// Releases all native resources.
  Future<void> release();

  /// Subscribes a playback listener.
  void addListener(PlayerEngineListener listener);
}
