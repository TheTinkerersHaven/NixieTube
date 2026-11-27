// Playback engine abstraction.
//
// Shaped like just_audio's AudioPlayer (a playlist window, transport,
// position/duration, completion + error events); the desktop Linux
// implementation is just_audio itself via `just_audio_media_kit`.
//
// The engine plays a rolling two-entry window rather than one URL at a
// time: the next track is queued *inside the same player*, so the
// backend can hand over to it without closing the audio device. That is
// what keeps a continuous album free of the gap a reopen costs, and it
// is also why a skip that lands on the queued entry is instant.

/// Listener for engine playback events.
abstract interface class PlayerEngineListener {
  /// Called when the stream in the window plays to completion, with
  /// nothing queued behind it.
  void onFinished();

  /// Called when the entry queued behind the playing one took over by
  /// itself (the track ended and the backend moved on inside the same
  /// audio device). The caller owns the queue, so it decides whether
  /// that was the right track and what to queue next.
  void onAdvanced();

  /// Called when the engine reports an error that no in-flight open is
  /// waiting on — a stream that dies *after* it started. Without this the
  /// controller's whole recovery path is unreachable, because a dropped
  /// stream otherwise just stops making progress with nothing to report.
  void onError(String message);
}

/// Replaceable audio backend behind [PlayerController].
abstract interface class PlayerEngine {
  /// Opens [url] as the playing entry and, when [nextUrl] is given, queues
  /// it behind in the same player, so the backend reaches it without
  /// tearing the stream down: one audio device, no gap.
  ///
  /// Returns null when the stream opened, or the reason it could not be
  /// opened. The reason matters: a signed CDN URL can be refused by the
  /// edge while it is still perfectly valid, and that is only visible in
  /// the backend's own error event — a bare "failed" leaves the user (and
  /// the recovery path) with nothing to act on.
  Future<String?> play(String url, {String? nextUrl});

  /// Replaces the entry queued behind the playing one, or clears it when
  /// [url] is null. The playing entry is untouched.
  Future<void> setNext(String? url);

  /// Drops the entry that just finished, so the queued one is the only
  /// one left. Called once the advance has been adopted.
  Future<void> promoteNext();

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
