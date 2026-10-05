// just_audio playback engine, implementing [PlayerEngine].
//
// Linux/Windows support comes from `just_audio_media_kit` (registered via
// `JustAudioMediaKit.ensureInitialized()` in main), which drives the
// bundled native backend. Control-plane details (retries, prefetch,
// session) live in [PlayerController], exactly like the Kotlin split.

import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

import 'player_engine.dart';

/// [PlayerEngine] backed by just_audio.
class JustAudioPlayerEngine implements PlayerEngine {
  JustAudioPlayerEngine() {
    _stateSub = _player.playerStateStream.listen((state) {
      final processing = state.processingState;
      // Edge-trigger: the backend can report the completed state more
      // than once per natural ending; only the transition into it ends
      // the track, otherwise every other song gets skipped.
      final fresh =
          processing == ja.ProcessingState.completed &&
          _lastProcessing != ja.ProcessingState.completed;
      _lastProcessing = processing;
      if (fresh && !_released) {
        for (final l in List.of(_listeners)) {
          l.onFinished();
        }
      }
    });
  }

  final ja.AudioPlayer _player = ja.AudioPlayer();
  final List<PlayerEngineListener> _listeners = [];
  late final StreamSubscription<ja.PlayerState> _stateSub;
  bool _released = false;

  /// Last seen processing state, for completed edge-triggering.
  ja.ProcessingState? _lastProcessing;

  @override
  Future<bool> play(String url) async {
    if (_released) return false;
    try {
      await _player.setUrl(url);
      await _player.play();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> pause() async {
    if (_released) return;
    try {
      await _player.pause();
    } catch (_) {}
  }

  @override
  Future<void> resume() async {
    if (_released) return;
    try {
      await _player.play();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    if (_released) return;
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  Future<void> seekTo(int ms) async {
    if (_released) return;
    try {
      await _player.seek(Duration(milliseconds: ms.clamp(0, 1 << 62)));
    } catch (_) {}
  }

  @override
  Future<void> setVolume(int volume) async {
    if (_released) return;
    try {
      await _player.setVolume(volume.clamp(0, 100) / 100.0);
    } catch (_) {}
  }

  @override
  int positionMs() {
    if (_released) return 0;
    try {
      return _player.position.inMilliseconds.clamp(0, 1 << 62);
    } catch (_) {
      return 0;
    }
  }

  @override
  int durationMs() {
    if (_released) return 0;
    try {
      return _player.duration?.inMilliseconds.clamp(0, 1 << 62) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  bool isPlaying() {
    if (_released) return false;
    try {
      return _player.playing;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _stateSub.cancel();
    _listeners.clear();
    try {
      await _player.dispose();
    } catch (_) {}
  }

  @override
  void addListener(PlayerEngineListener listener) {
    _listeners.add(listener);
  }
}
