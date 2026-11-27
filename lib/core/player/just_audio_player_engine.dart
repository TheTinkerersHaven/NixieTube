// just_audio playback engine, implementing [PlayerEngine].
//
// Linux/Windows support comes from `just_audio_media_kit` (registered via
// `JustAudioMediaKit.ensureInitialized()` in main), which drives the
// bundled native backend. Control-plane details (retries, prefetch,
// session) live in [PlayerController].
//
// Playback is a rolling two-entry playlist rather than one URL at a time:
// just_audio keeps the playlist itself and hands it to the platform, so
// ExoPlayer gets a native `ConcatenatingMediaSource` and mpv gets a
// playlist it can prefetch. Both keep one audio device open across the
// boundary and strip the container's priming/padding, which is the
// difference between an album that runs continuously and one that dips
// for a few tens of milliseconds between tracks.

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
    _lastIndex = _player.currentIndex;
    _indexSub = _player.currentIndexStream.listen(_onIndex);
  }

  /// Reports a move *forward* in the playlist: the queued entry took over
  /// because the track in front of it ended. The shift back to index 0
  /// that a promote causes, and the reset a new window causes, are both
  /// silent — they are ours, not a handover.
  void _onIndex(int? index) {
    if (_released || index == null) return;
    final previous = _lastIndex;
    _lastIndex = index;
    _playing = index;
    if (previous == null || index <= previous) return;
    for (final l in List.of(_listeners)) {
      l.onAdvanced();
    }
  }

  /// Runs playlist edits one at a time, in call order: the plugin relays
  /// them to one native playlist, and an insert that lands between a
  /// remove's two steps leaves the window holding the wrong entries.
  ///
  /// Bounded: a just_audio playlist edit can wait forever on the index
  /// event it expects next (its sequence broadcast parks until the playing
  /// index is reported, and a platform that has just gone idle never
  /// reports one). Without the ceiling that stuck edit blocks this chain
  /// for the rest of the session, and every later open — which waits on it
  /// — never reaches the backend: a player that shows a song and no
  /// longer plays anything.
  Future<void> _serial(Future<void> Function() op) {
    final next = _ops.then((_) async {
      try {
        await op().timeout(_editTimeout);
      } catch (_) {
        // Whatever the edit was going to leave queued is unknown now.
        _queuedUrl = null;
      }
    });
    _ops = next;
    return next;
  }

  /// Drops the entries before the playing one, so the window is always
  /// the playing entry followed by the queued one. After a handover —
  /// theirs or ours — the finished entry is still sitting at index 0.
  ///
  /// Which entry plays comes from [_playing], never from the player's own
  /// [ja.AudioPlayer.currentIndex]: that one only catches up when the
  /// backend reports the move, and removing the entry that is still
  /// playing would cut the sound off.
  Future<void> _dropFinished() async {
    var current = _active;
    while (current > 0 && _player.audioSources.isNotEmpty) {
      await _player.removeAudioSourceAt(0);
      current--;
      _playing = current;
      _lastIndex = current;
    }
  }

  final ja.AudioPlayer _player = ja.AudioPlayer();
  final List<PlayerEngineListener> _listeners = [];
  late final StreamSubscription<ja.PlayerState> _stateSub;
  late final StreamSubscription<ja.PlayerException> _errorSub;
  late final StreamSubscription<int?> _indexSub;
  bool _released = false;

  /// The entry last seen as active in the player's playlist, so a move
  /// forward can be told apart from the shift a promote causes.
  int? _lastIndex;

  /// Index the backend last reported as playing, kept across the window
  /// edits we make ourselves.
  int _playing = 0;

  /// The entry that is playing, as fresh as the reports get: the player's
  /// own index is updated before our listener runs, so taking the later
  /// of the two avoids removing an entry that just started.
  int get _active {
    final reported = _player.currentIndex ?? 0;
    return reported > _playing ? reported : _playing;
  }

  /// URL of the entry queued behind the playing one, so asking for the
  /// same one again is free and a stale one is replaced.
  String? _queuedUrl;

  /// Pending playlist edits, see [_serial].
  Future<void> _ops = Future.value();

  /// Ceiling for one playlist edit and for waiting on the chain, see
  /// [_serial].
  static const Duration _editTimeout = Duration(seconds: 4);

  /// Counts opens, so an open that a newer one has superseded does not
  /// start playing its stream over the newer one's.
  int _playGen = 0;

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
  Future<String?> play(String url, {String? nextUrl}) async {
    if (_released) return 'player released';
    final gen = ++_playGen;
    // Pending window edits land first: they address the playlist this is
    // about to replace. Bounded, because a chain that never comes back is
    // exactly the state this open exists to get out of.
    await _ops.timeout(_editTimeout, onTimeout: () => null);
    // A newer open (the user skipped again while this one resolved) owns
    // the player: replacing the playlist here would play this stream over
    // the one the screen has moved on to.
    if (_released || gen != _playGen) return 'superseded';
    // A new window replaces whatever was queued in the old one.
    _queuedUrl = null;
    final failure = Completer<String?>();
    _openFailure = failure;
    try {
      final opened = _player
          .setAudioSources([
            ja.AudioSource.uri(Uri.parse(url)),
            if (nextUrl != null) ja.AudioSource.uri(Uri.parse(nextUrl)),
          ], initialIndex: 0)
          .then<Object?>((_) => null, onError: (Object error) => error);
      // Whichever lands first decides the attempt: the load completing, or
      // the backend refusing the stream.
      final outcome = await Future.any<Object?>([opened, failure.future]);
      if (outcome != null) return '$outcome';
      // Superseded while the load ran: the newer open starts its own
      // stream, so this one must not start playing underneath it.
      if (gen != _playGen) {
        return 'superseded';
      }
      _lastIndex = _player.currentIndex ?? 0;
      _playing = _lastIndex ?? 0;
      _queuedUrl = nextUrl;
      // just_audio's play() future completes when playback *ends* (paused,
      // stopped or finished), not when audio starts. Awaiting it kept the
      // controller in its loading state for the whole song and let the
      // open timeout fire mid-playback, restarting the track.
      unawaited(_player.play().catchError((Object _) {}));
      _lastError = null;
      return null;
    } catch (error) {
      return _describe(error);
    } finally {
      if (identical(_openFailure, failure)) _openFailure = null;
    }
  }

  @override
  Future<void> setNext(String? url) => _serial(() async {
    if (_released) return;
    // Finished entries go, then whatever is queued behind the playing
    // one: this way the window is repaired even if a promote never ran.
    // [_dropFinished] leaves the playing entry at 0, so the rest of the
    // playlist is exactly what has to go — the playing index the player
    // reports is not consulted here, because a report that still names the
    // entry that was just removed would keep a stale one queued.
    await _dropFinished();
    while (_player.audioSources.length > 1) {
      await _player.removeAudioSourceAt(1);
    }
    // Only a no-op when the entry is demonstrably still there: the removal
    // above may have just dropped the very entry [_queuedUrl] names, and
    // returning then would leave the playlist without it while the caller
    // believes its next track is queued.
    if (url == _queuedUrl && _player.audioSources.length > 1) return;
    _queuedUrl = null;
    if (url == null) return;
    await _player.addAudioSource(ja.AudioSource.uri(Uri.parse(url)));
    _queuedUrl = url;
  });

  @override
  Future<void> promoteNext() => _serial(() async {
    if (_released) return;
    // Only the finished entry goes: the one playing keeps the device.
    await _dropFinished();
    _queuedUrl = null;
  });

  @override
  Future<void> pause() async {
    if (_released) return;
    final gen = _playGen;
    try {
      await _player.pause();
    } catch (_) {}
    // A skip that opened a new stream while this pause was in flight owns
    // the player now. The platform call lands after that open's own play
    // request, which would leave the screen on a song parked silently at
    // its first frames — playing, as far as the state is concerned.
    if (!_released && gen != _playGen) {
      unawaited(_player.play().catchError((Object _) {}));
    }
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
    await _indexSub.cancel();
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
