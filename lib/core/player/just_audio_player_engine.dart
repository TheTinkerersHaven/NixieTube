// just_audio playback engine, implementing [PlayerEngine].
//
// Linux/Windows support comes from `just_audio_media_kit` (registered via
// `JustAudioMediaKit.ensureInitialized()` in main), which drives the
// bundled native backend. Control-plane details (retries, prefetch,
// session) live in [PlayerController].

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
    _errorSub = _player.errorStream.listen(_onError);
  }

  final ja.AudioPlayer _player = ja.AudioPlayer();
  final List<PlayerEngineListener> _listeners = [];
  late final StreamSubscription<ja.PlayerState> _stateSub;
  late final StreamSubscription<ja.PlayerException> _errorSub;
  bool _released = false;

  /// Last seen processing state, for completed edge-triggering.
  ja.ProcessingState? _lastProcessing;

  /// Completion for the open currently in flight, when one is.
  ///
  /// The backend reports a refused stream through its error stream while
  /// `setUrl` is still waiting on a load that will never complete, so the
  /// open races the error instead of sitting there until a timeout.
  Completer<String?>? _openFailure;

  /// Last reason handed to the listeners, so one failure that the backend
  /// re-reports on every subsequent event is only recovered from once.
  String? _lastError;

  /// Turns a backend error into something worth showing.
  ///
  /// A refused CDN stream reads as `Failed to open <very long url>.`; the
  /// URL is noise in a settings row, so it is dropped and what is left is
  /// the part that says what happened.
  static String _describe(Object error) {
    final raw = error is ja.PlayerException
        ? (error.message ?? '')
        : error.toString();
    final text = raw.trim();
    final withoutUrl = text.replaceFirst(
      RegExp(r'\s*Failed to open\b.*$', caseSensitive: false),
      '',
    );
    final cleaned = withoutUrl.trim();
    if (cleaned.isEmpty) return 'the stream was refused';
    return cleaned.length > 160 ? '${cleaned.substring(0, 160)}…' : cleaned;
  }

  /// Routes a backend error to whoever is waiting for it: an open in
  /// flight takes it as its own failure, anything else is a stream dying
  /// under us and goes to the listeners so the controller can recover.
  void _onError(ja.PlayerException error) {
    if (_released) return;
    final message = _describe(error);
    final open = _openFailure;
    if (open != null && !open.isCompleted) {
      // `play` reports this itself; notifying as well would start a second,
      // concurrent recovery for the same failure.
      open.complete(message);
      return;
    }
    if (message == _lastError) return;
    _lastError = message;
    for (final l in List.of(_listeners)) {
      l.onError(message);
    }
  }

  @override
  Future<String?> play(String url) async {
    if (_released) return 'player released';
    final failure = Completer<String?>();
    _openFailure = failure;
    try {
      final opened = _player
          .setUrl(url)
          .then<Object?>((_) => null, onError: (Object error) => error);
      // Whichever lands first decides the attempt: the load completing, or
      // the backend refusing the stream.
      final outcome = await Future.any<Object?>([opened, failure.future]);
      if (outcome != null) return '$outcome';
      await _player.play();
      _lastError = null;
      return null;
    } catch (error) {
      return _describe(error);
    } finally {
      if (identical(_openFailure, failure)) _openFailure = null;
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
    await _errorSub.cancel();
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
