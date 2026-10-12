// Playback queue ownership, ported from Kotlin `PlayerController`.
//
// Resolves stream URLs, drives the [PlayerEngine], polls position via a
// ticker, retries dying streams with a bounded budget, and persists/restores
// sessions. Stale async work is fenced by an incrementing play token.
// No Flutter imports: safe to reuse under any frontend.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:isolate';
import 'dart:math' show Random;

import '../innertube/inner_tube.dart';
import '../innertube/metadata.dart' show canonical;
import '../innertube/stream_resolver.dart';
import '../models/models.dart';
import '../../sys/paths.dart';
import 'player_engine.dart';
import 'player_state.dart';

/// Mid-stream resume attempts before surfacing the error.
const maxStreamRetries = 2;

/// Back-to-back finish events closer than this belong to the same natural
/// ending (duplicate backend delivery, not a new one). Real songs are
/// orders of magnitude longer; manual seeks bypass the check.
const finishDebounce = Duration(seconds: 3);

/// Upper bound for one engine open attempt. A dead edge can blackhole
/// the TCP connect (no RST), in which case MPV never answers and the
/// track would spin forever with no error and no recovery. Normal
/// opens take seconds; exceeding this means the open is hung.
const playOpenTimeout = Duration(seconds: 20);

/// Position ticker cadence while playing.
const tickerInterval = Duration(milliseconds: 500);

/// Below this position, previous restarts the track instead of going back.
const previousRestartThresholdMs = 3000;

/// How many played positions shuffle previous() can walk back.
const shuffleHistorySize = 200;

/// How long a seek target is held before the engine position wins.
const seekSettleTimeout = Duration(seconds: 6);

/// Engine positions within this window count as arrived after a seek.
const seekArrivalToleranceMs = 1000;

/// Engine positions at or below this count as a restarted track right
/// after a fresh start (the real position is ~0 there).
const freshPositionThresholdMs = 1500;

/// Outer bound for the fresh-start hold: a frozen engine still wins
/// eventually instead of pinning the slider at 0 forever.
const freshPositionTimeout = Duration(seconds: 6);

/// Serializable snapshot of queue/index/position persisted across restarts.
class SessionData {
  const SessionData({
    this.version = 1,
    this.queue = const [],
    this.index = -1,
    this.positionMs = 0,
    this.volume = 80,
  });

  final int version;
  final List<Track> queue;
  final int index;
  final int positionMs;
  final int volume;

  Map<String, dynamic> toJson() => {
    'version': version,
    'queue': queue.map((t) => t.toJson()).toList(),
    'index': index,
    'positionMs': positionMs,
    'volume': volume,
  };

  factory SessionData.fromJson(Map<String, dynamic> json) => SessionData(
    version: (json['version'] as num?)?.toInt() ?? 1,
    queue: ((json['queue'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => Track.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
        .toList(),
    index: (json['index'] as num?)?.toInt() ?? -1,
    positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
    volume: (json['volume'] as num?)?.toInt() ?? 80,
  );
}

/// Owns the playback queue and exposes it as a [PlayerState] stream.
class PlayerController implements PlayerEngineListener {
  PlayerController({
    required PlayerEngine engine,
    required InnerTube tube,
    Future<ResolvedStream?> Function(String videoId)? resolveStream,
    Future<void> Function()? refreshStream,
    Future<void> Function()? resetStream,
    PlayerEngine Function()? createEngine,
    Random? random,
    String? configDirPath,
    this.playTimeout = playOpenTimeout,
  }) {
    _engine = engine;
    _tube = tube;
    _resetStream = resetStream;
    _createEngine = createEngine;
    if (resolveStream != null) {
      _resolveStream = resolveStream;
      _refreshStream = refreshStream;
    } else {
      final resolver = StreamResolver();
      _resolveStream = resolver.resolve;
      _refreshStream = refreshStream ?? resolver.refreshVisitor;
      _resetStream ??= resolver.reset;
    }
    _random = random ?? Random();
    _configDirPath = configDirPath;
    _engine.setVolume(80);
    _engine.addListener(this);
  }

  late PlayerEngine _engine;
  late final InnerTube _tube;
  late final Future<ResolvedStream?> Function(String videoId) _resolveStream;

  /// Forces the stream source to drop cached visitor/session state before
  /// the next resolve. Null for injected test resolvers.
  late final Future<void> Function()? _refreshStream;

  /// Drops all HTTP-side stream state (pooled connections, visitor id),
  /// mirroring an app restart. Null disables that half of last-resort
  /// recovery (e.g. under test doubles).
  Future<void> Function()? _resetStream;

  /// Builds a fresh engine for last-resort recovery, mirroring an app
  /// restart for the native backend (fresh handle: DNS, pooled
  /// connections, demuxer state). Null disables engine recycling.
  PlayerEngine Function()? _createEngine;
  late final Random _random;
  late final String? _configDirPath;

  /// Per-attempt ceiling for engine opens (see [playOpenTimeout]).
  /// Injectable for tests; production always uses the default.
  final Duration playTimeout;

  PlayerState _state = const PlayerState();
  final _states = StreamController<PlayerState>.broadcast(sync: true);

  /// Current snapshot (mirrors `state.value`).
  PlayerState get state => _state;

  /// Snapshot stream (mirrors the `state` StateFlow).
  Stream<PlayerState> get states => _states.stream;

  void _update(PlayerState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  Timer? _ticker;

  /// Fencing token: stale resolve/ticker work aborts when it no longer matches.
  int _playToken = 0;
  int _lastSessionSaveMs = 0;

  /// Serializes background session saves so they land on disk in order.
  Future<void> _saveChain = Future.value();

  /// Waits for pending session saves to land (e.g. before app exit).
  Future<void> flushSession() => _saveChain;

  // Video id the engine actually has loaded. A restored session sets player
  // state without touching the engine, so resume must detect the mismatch
  // and start fresh instead of resuming an empty engine.
  String? _loadedVideoId;

  /// Consecutive mid-stream retry attempts for the current track (max 2).
  int _streamRetries = 0;

  /// Whether the current failure episode already spent its backend
  /// restart. Reset on every explicit start; a recycled backend that
  /// still fails surfaces the error instead of looping restarts.
  bool _recycledForEpisode = false;

  /// Last consumed natural finish, for duplicate-delivery debouncing.
  DateTime? _lastFinishAt;

  /// Most recent seek target, held until the engine position arrives.
  int? _pendingSeekTargetMs;

  /// Time the pending seek was issued, for the 6s settle timeout.
  DateTime? _pendingSeekAt;

  /// Fresh-start guard: right after a new track opens, the engine
  /// briefly keeps reporting the previous track's position. While set,
  /// the ticker holds 0 instead of publishing those stale reads
  /// (which would teleport the slider to the old spot and sweep back).
  /// Cleared once the engine demonstrably restarts (position back near
  /// zero, or moving) or the timeout elapses.
  bool _awaitingFreshPosition = false;
  DateTime? _freshHoldStart;
  int? _lastRawEnginePos;

  /// Recently played queue positions for shuffle previous(). Bounded;
  /// cleared whenever playback starts somewhere explicit.
  final List<int> _shuffleHistory = [];

  /// Prefetched next-track stream so transitions skip the resolve delay.
  String? _prefetchedVideoId;
  ResolvedStream? _prefetchedStream;
  int _prefetchGen = 0;

  bool _disposed = false;

  /// Releases the ticker and the state stream. Does not release the engine.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playToken++;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _ticker?.cancel();
    _ticker = null;
    _prefetchGen++;
    _states.close();
  }

  @override
  void onFinished() {
    unawaited(_onTrackFinished());
  }

  @override
  void onError(String message) {
    unawaited(handleEngineError(message));
  }

  /// Re-resolves [videoId] under fresh visitor/session state, so a retry
  /// mints a new URL family instead of another dead URL from the same
  /// poisoned resolve context. Never throws.
  Future<ResolvedStream?> _resolveFresh(String videoId) async {
    try {
      await _refreshStream?.call();
    } catch (_) {}
    try {
      return await _resolveStream(videoId);
    } catch (_) {
      return null;
    }
  }

  /// Last-resort recovery for a dying stream family: drops the HTTP pool
  /// and visitor id plus the native handle (fresh MPV instance: DNS,
  /// pooled connections, demuxer state) — the in-process equivalent of
  /// the app restart that users report as the fix — then plays [track]
  /// once more, resuming at [resumeAt] when given. Returns true when
  /// playback actually started; the caller then skips surfacing an
  /// error. At most once per failure episode; without any recovery
  /// hooks wired it returns false immediately, preserving old behavior.
  Future<bool> _tryBackendRestart(
    Track track,
    int token, [
    int? resumeAt,
  ]) async {
    if (_recycledForEpisode) return false;
    if (_createEngine == null && _resetStream == null) return false;
    if (token != _playToken) return false;
    _recycledForEpisode = true;
    _clearPrefetch();
    try {
      await _resetStream?.call();
    } catch (_) {}
    if (token != _playToken) return false;
    final factory = _createEngine;
    if (factory != null) {
      final old = _engine;
      try {
        await old.release();
      } catch (_) {}
      if (token != _playToken) return false;
      try {
        _engine = factory();
      } catch (_) {
        return false;
      }
      _loadedVideoId = null;
      _engine.addListener(this);
      unawaited(_engine.setVolume(_state.volume));
    }
    ResolvedStream? stream;
    try {
      stream = await _resolveStream(track.videoId);
    } catch (_) {
      stream = null;
    }
    if (token != _playToken || stream == null) return false;
    if (!await _playUrl(stream.url)) return false;
    if (token != _playToken) return false;
    if (resumeAt != null && resumeAt > 0) {
      await _engine.seekTo(resumeAt);
      if (token != _playToken) return false;
    }
    _loadedVideoId = track.videoId;
    _update(_state.copyWith(loading: false, playing: true));
    updateTrackStats(track.videoId, stream.likes, stream.dislikes);
    _startTicker();
    final cur = _state;
    if (cur.queue.isNotEmpty &&
        cur.index >= 0 &&
        cur.index < cur.queue.length) {
      prefetchNextFor(cur.index, List.of(cur.queue));
    }
    return true;
  }

  /// Plays [url] on the engine with a hard ceiling. A hung open (dead
  /// edge blackholing the connect) must become a plain failure — with
  /// the hung command stopped — so retries, backend restart and error
  /// surfacing can take over instead of spinning forever.
  Future<bool> _playUrl(String url) async {
    try {
      return await _engine.play(url).timeout(playTimeout);
    } catch (_) {
      try {
        unawaited(_engine.stop());
      } catch (_) {}
      return false;
    }
  }

  /// Retries a dying stream with a fresh URL, else surfaces [message].
  Future<void> handleEngineError(String message) async {
    final failed = _state;
    final track = failed.current;
    final resumeAt = failed.positionMs;
    // Expiring URLs and flaky streams die mid-playback; mint a fresh URL
    // and resume where we left off. Bounded retries: a permanently
    // unplayable track still surfaces its error.
    final retrySameTrack =
        track != null &&
        !failed.stopped &&
        _streamRetries < maxStreamRetries &&
        _state.current?.videoId == track.videoId;
    if (track != null && retrySameTrack) {
      _streamRetries++;
      final stream = await _resolveFresh(track.videoId);
      final now = _state;
      if (stream != null &&
          now.current?.videoId == track.videoId &&
          !now.stopped) {
        _update(now.copyWith(loading: true, error: () => null));
        if (await _playUrl(stream.url)) {
          await _engine.seekTo(resumeAt);
          _loadedVideoId = track.videoId;
          _update(_state.copyWith(loading: false, playing: true));
          _startTicker();
          return;
        }
      }
    }
    _streamRetries = 0;
    // Last resort before paging the user: restart the backend stack,
    // unless the user already moved on while the retries were in flight.
    if (track != null &&
        !failed.stopped &&
        _state.current?.videoId == track.videoId) {
      if (await _tryBackendRestart(track, _playToken, resumeAt)) return;
    }
    _update(
      _state.copyWith(playing: false, loading: false, error: () => message),
    );
  }

  /// Replaces the queue with [tracks] and starts at [startIndex].
  void playTracks(List<Track> tracks, [int startIndex = 0]) {
    if (tracks.isEmpty) return;
    _shuffleHistory.clear();
    _update(
      _state.copyWith(
        queue: List.of(tracks),
        index: startIndex.clamp(0, tracks.length - 1),
      ),
    );
    _startCurrent();
  }

  /// Inserts [track] immediately after the current index.
  void enqueueNext(Track track) {
    final q = List<Track>.of(_state.queue);
    final at = (_state.index + 1).clamp(0, q.length);
    q.insert(at, track);
    _update(_state.copyWith(queue: q));
    refreshPrefetch();
  }

  /// Appends [track] to the end of the queue.
  void enqueueLast(Track track) {
    _update(_state.copyWith(queue: [..._state.queue, track]));
    refreshPrefetch();
  }

  /// Appends unseen radio tracks to the queue without touching playback.
  ///
  /// Unlike [playTracks]/[playAt], this never calls [_startCurrent]: the
  /// engine keeps playing the current track from its live position. Used
  /// when a station is (re)started for the track already playing, and
  /// when a single's radio mix lands after playback began.
  void appendRadio(List<Track> upcoming) {
    if (upcoming.isEmpty) return;
    final known = _state.queue.map((q) => q.videoId).toSet();
    final fresh = upcoming.where((t) => !known.contains(t.videoId)).toList();
    if (fresh.isEmpty) return;
    _update(_state.copyWith(queue: [..._state.queue, ...fresh]));
    refreshPrefetch();
  }

  /// Replaces everything after the current index with [upcoming] (unseen
  /// only), keeping playback untouched: the current track keeps playing
  /// from its live position and the played history stays behind it. Used
  /// when a radio station takes over Up next. Returns how many tracks
  /// were actually swapped in. Falls back to [appendRadio] when there is
  /// no current position; keeps the tail when nothing in the mix is new.
  int replaceUpcoming(List<Track> upcoming) {
    final s = _state;
    if (s.index < 0 || s.index >= s.queue.length) {
      final before = _state.queue.length;
      appendRadio(upcoming);
      return _state.queue.length - before;
    }
    final head = s.queue.sublist(0, s.index + 1);
    final known = head.map((t) => t.videoId).toSet();
    final fresh = upcoming.where((t) => !known.contains(t.videoId)).toList();
    if (fresh.isEmpty) return 0;
    _update(s.copyWith(queue: [...head, ...fresh]));
    refreshPrefetch();
    return fresh.length;
  }

  /// Jumps to the queue entry at [index] and starts it.
  void playAt(int index) {
    final q = _state.queue;
    if (index >= 0 && index < q.length) {
      _shuffleHistory.clear();
      _update(_state.copyWith(index: index));
      _startCurrent();
    }
  }

  /// Moves the queue entry from [oldIndex] to [newIndex], keeping the
  /// current track playing from its live position. [newIndex] is the
  /// final insertion index (the `ReorderableListView.onReorderItem`
  /// convention, already adjusted for the removed item). Positions
  /// shuffle history is keyed on break, so it is forgotten. No-op for
  /// out-of-range or identity moves.
  void moveQueue(int oldIndex, int newIndex) {
    final s = _state;
    final n = s.queue.length;
    if (oldIndex < 0 || oldIndex >= n || newIndex < 0 || newIndex >= n) return;
    if (oldIndex == newIndex) return;
    final q = List<Track>.of(s.queue);
    final moved = q.removeAt(oldIndex);
    q.insert(newIndex, moved);
    var idx = s.index;
    if (oldIndex == s.index) {
      idx = newIndex;
    } else if (oldIndex < s.index && newIndex >= s.index) {
      idx -= 1;
    } else if (oldIndex > s.index && newIndex <= s.index) {
      idx += 1;
    }
    _shuffleHistory.clear();
    _update(s.copyWith(queue: q, index: idx));
    refreshPrefetch();
  }

  /// Removes the queue entry at [index]. Removing the current track
  /// starts whatever lands on its position; removing the last song
  /// stops fully. Anything else keeps playback untouched.
  /// Returns false for out-of-range indices.
  bool removeAt(int index) {
    final s = _state;
    if (index < 0 || index >= s.queue.length) return false;
    _shuffleHistory.clear();
    if (index == s.index) {
      final q = List<Track>.of(s.queue)..removeAt(index);
      if (q.isEmpty) {
        // Explicitly dismissing the playing song stops everything.
        _playToken++;
        _ticker?.cancel();
        _ticker = null;
        unawaited(_engine.stop());
        _clearPrefetch();
        _loadedVideoId = null;
        _pendingSeekTargetMs = null;
        _pendingSeekAt = null;
        _awaitingFreshPosition = false;
        _freshHoldStart = null;
        _lastRawEnginePos = null;
        _update(
          s.copyWith(
            current: () => null,
            queue: const [],
            index: -1,
            playing: false,
            stopped: true,
            loading: false,
            positionMs: 0,
            error: () => null,
          ),
        );
        try {
          _sessionFile().deleteSync();
        } catch (_) {}
        return true;
      }
      final idx = index.clamp(0, q.length - 1);
      _update(s.copyWith(queue: q, index: idx));
      _startCurrent();
      return true;
    }
    final q = List<Track>.of(s.queue)..removeAt(index);
    final idx = index < s.index ? s.index - 1 : s.index;
    _update(s.copyWith(queue: q, index: idx));
    refreshPrefetch();
    return true;
  }

  /// Inserts [track] at [index] (clamped), shifting the current index
  /// when the insert lands at or before it. Powers remove-undo: with
  /// nothing loaded, the restored song starts playing again.
  void insertAt(int index, Track track) {
    final s = _state;
    final at = index.clamp(0, s.queue.length);
    final q = List<Track>.of(s.queue)..insert(at, track);
    if (s.current == null) {
      _shuffleHistory.clear();
      _update(s.copyWith(queue: q, index: 0));
      _startCurrent();
      return;
    }
    final idx = (s.index >= 0 && at <= s.index) ? s.index + 1 : s.index;
    _shuffleHistory.clear();
    _update(s.copyWith(queue: q, index: idx));
    refreshPrefetch();
  }

  /// Discards everything except the current song, which keeps playing
  /// from its live position. With nothing loaded, stops fully and
  /// forgets the session like an explicit stop does.
  void clearQueue() {
    final s = _state;
    final current = s.current;
    if (current == null || s.index < 0 || s.index >= s.queue.length) {
      _playToken++;
      _ticker?.cancel();
      _ticker = null;
      unawaited(_engine.stop());
      _clearPrefetch();
      _loadedVideoId = null;
      _pendingSeekTargetMs = null;
      _pendingSeekAt = null;
      _awaitingFreshPosition = false;
      _freshHoldStart = null;
      _lastRawEnginePos = null;
      _shuffleHistory.clear();
      _update(
        _state.copyWith(
          current: () => null,
          queue: const [],
          index: -1,
          playing: false,
          stopped: true,
          loading: false,
          positionMs: 0,
          error: () => null,
        ),
      );
      try {
        _sessionFile().deleteSync();
      } catch (_) {}
      return;
    }
    _shuffleHistory.clear();
    _update(s.copyWith(queue: [current], index: 0));
    refreshPrefetch();
    saveSession();
  }

  /// Toggles between pause and resume; restarts when stopped or the engine
  /// holds another track.
  void togglePlayPause() {
    final s = _state;
    if (s.current == null || s.loading) return;
    if (s.stopped || _loadedVideoId != s.current!.videoId) {
      _startCurrent();
      return;
    }
    if (s.playing) {
      unawaited(_engine.pause());
      _update(s.copyWith(playing: false));
      saveSession();
    } else {
      unawaited(_engine.resume());
      _update(s.copyWith(playing: true, stopped: false, error: () => null));
      _startTicker();
    }
  }

  /// Resumes playback; restarts when stopped or not loaded in the engine.
  void play() {
    final s = _state;
    if (s.current == null || s.playing || s.loading) return;
    if (s.stopped || _loadedVideoId != s.current!.videoId) {
      _startCurrent();
      return;
    }
    unawaited(_engine.resume());
    _update(s.copyWith(playing: true, stopped: false, error: () => null));
    _startTicker();
  }

  /// Pauses playback, keeping the stream loaded. No-op when nothing
  /// is playing.
  void pause() {
    final s = _state;
    if (s.current == null || !s.playing || s.loading) return;
    unawaited(_engine.pause());
    _update(s.copyWith(playing: false));
    saveSession();
  }

  /// Stops playback, invalidates in-flight work, and deletes the session.
  void stop() {
    _clearSleepTimer();
    _playToken++;
    _ticker?.cancel();
    _ticker = null;
    unawaited(_engine.stop());
    _clearPrefetch();
    _loadedVideoId = null;
    _pendingSeekTargetMs = null;
    _pendingSeekAt = null;
    _awaitingFreshPosition = false;
    _freshHoldStart = null;
    _lastRawEnginePos = null;
    _update(
      _state.copyWith(
        playing: false,
        stopped: true,
        loading: false,
        positionMs: 0,
      ),
    );
    // Explicit stop forgets the session; quitting any other way resumes it.
    try {
      _sessionFile().deleteSync();
    } catch (_) {}
  }

  /// One-shot sleep timer future; null unless a duration timer is
  /// armed. End-of-track/queue modes need no timer — they hook the
  /// natural finish path instead, so zero timers tick while armed.
  Timer? _sleepTimer;

  /// Arms a sleep timer that pauses after [duration]. Replaces any
  /// armed timer. Ignored without a loaded track or for non-positive
  /// durations.
  void setSleepTimerDuration(Duration duration) {
    _clearSleepTimer(notify: false);
    if (duration <= Duration.zero || _state.current == null) return;
    final endsAt =
        DateTime.now().millisecondsSinceEpoch + duration.inMilliseconds;
    _sleepTimer = Timer(duration, _onSleepTimerFired);
    _update(
      _state.copyWith(
        sleepTimerMode: SleepTimerMode.duration,
        sleepTimerEndsAtMs: () => endsAt,
      ),
    );
  }

  /// Arms a sleep timer that pauses at the next natural track finish
  /// instead of advancing. Replaces any armed timer.
  void setSleepTimerEndOfTrack() {
    if (_state.current == null) return;
    _clearSleepTimer(notify: false);
    _update(
      _state.copyWith(
        sleepTimerMode: SleepTimerMode.endOfTrack,
        sleepTimerEndsAtMs: () => null,
      ),
    );
  }

  /// Arms a sleep timer that pauses when the queue ends instead of
  /// looping or continuing radio. In shuffle mode (which has no end)
  /// it pauses at the next finish instead. Replaces any armed timer.
  void setSleepTimerEndOfQueue() {
    if (_state.current == null || _state.queue.isEmpty) return;
    _clearSleepTimer(notify: false);
    _update(
      _state.copyWith(
        sleepTimerMode: SleepTimerMode.endOfQueue,
        sleepTimerEndsAtMs: () => null,
      ),
    );
  }

  /// Disarms any sleep timer.
  void cancelSleepTimer() => _clearSleepTimer();

  /// Cancels the timer; emits a state reset unless [notify] is false
  /// (the setters emit their own update right after replacing).
  void _clearSleepTimer({bool notify = true}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (notify &&
        (_state.sleepTimerMode != SleepTimerMode.off ||
            _state.sleepTimerEndsAtMs != null)) {
      _update(
        _state.copyWith(
          sleepTimerMode: SleepTimerMode.off,
          sleepTimerEndsAtMs: () => null,
        ),
      );
    }
  }

  void _onSleepTimerFired() {
    _sleepTimer = null;
    if (_disposed || _state.sleepTimerMode != SleepTimerMode.duration) return;
    _clearSleepTimer();
    pause();
  }

  /// True when the current track is the last one with a definite end
  /// (ordered queue, at its tail). Shuffle never ends; repeat-all
  /// still counts the pass end as the queue end.
  bool _isQueueEnd() {
    final s = _state;
    if (s.shuffle || s.queue.isEmpty || s.index < 0) return false;
    return s.index >= s.queue.length - 1;
  }

  /// Persists queue, index, position, and volume; skipped while stopped.
  /// Encoding (large queues run to megabytes of JSON) and the disk write
  /// run off the UI thread, chained so concurrent saves land in order.
  void saveSession() {
    try {
      final s = _state;
      if (s.current == null || s.stopped) return;
      if (s.queue.isEmpty || s.index < 0 || s.index >= s.queue.length) {
        return;
      }
      final payload = SessionData(
        queue: s.queue,
        index: s.index,
        positionMs: s.positionMs < 0 ? 0 : s.positionMs,
        volume: s.volume,
      ).toJson();
      _lastSessionSaveMs = DateTime.now().millisecondsSinceEpoch;
      final path = _sessionFile().path;
      _saveChain = _saveChain.then(
        (_) => Isolate.run(() {
          File(path).writeAsStringSync(jsonEncode(payload));
        }).catchError((_) {}),
      );
    } catch (_) {}
  }

  /// Restores the persisted session paused at its saved position without
  /// autoplaying. Streams are re-resolved on play, so no stale URLs are kept.
  /// The file read, JSON parse and queue reconstruction run on a worker
  /// isolate — a large saved queue can run to megabytes of JSON, which
  /// must never stall app startup.
  Future<bool> restoreSession() async {
    final path = _sessionFile().path;
    SessionData? data;
    try {
      data = await Isolate.run<SessionData?>(() {
        try {
          final f = File(path);
          if (!f.existsSync()) return null;
          return SessionData.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
          );
        } catch (_) {
          return null;
        }
      });
    } catch (_) {
      return false;
    }
    if (data == null) return false;
    if (data.queue.isEmpty ||
        data.index < 0 ||
        data.index >= data.queue.length) {
      return false;
    }
    final track = data.queue[data.index];
    final catalogMs = track.durationSec * 1000;
    final pos = data.positionMs.clamp(0, catalogMs > 0 ? catalogMs : (1 << 62));
    final volume = data.volume.clamp(0, 100);
    unawaited(_engine.setVolume(volume));
    _update(
      _state.copyWith(
        queue: List.of(data.queue),
        index: data.index,
        current: () => track,
        playing: false,
        stopped: false,
        loading: false,
        positionMs: pos,
        durationMs: catalogMs,
        volume: volume,
        error: () => null,
      ),
    );
    return true;
  }

  File _sessionFile() {
    final dir = _configDirPath ?? configDir().path;
    Directory(dir).createSync(recursive: true);
    return File('$dir/playback-session.json');
  }

  /// Advances to the next track, honoring repeat and radio autoplay.
  void next({bool manual = true}) {
    final s = _state;
    if (s.repeat == RepeatMode.one && !manual) {
      _startCurrent();
      return;
    }
    if (s.shuffle && s.queue.length > 1) {
      // Shuffled advance: random next track, never the current one.
      // Repeat ONE is handled above; ALL/OFF both keep shuffling (there
      // is no queue end in shuffle mode).
      _shuffleHistory.add(s.index);
      while (_shuffleHistory.length > shuffleHistorySize) {
        _shuffleHistory.removeAt(0);
      }
      var nextIndex = s.index;
      while (nextIndex == s.index) {
        nextIndex = _random.nextInt(s.queue.length);
      }
      _update(_state.copyWith(index: nextIndex));
      _startCurrent();
      return;
    }
    final nextIndex = s.index + 1;
    if (nextIndex >= 0 && nextIndex < s.queue.length) {
      _update(_state.copyWith(index: nextIndex));
      _startCurrent();
    } else if (s.repeat == RepeatMode.all && s.queue.isNotEmpty) {
      _update(_state.copyWith(index: 0));
      _startCurrent();
    } else if (s.autoplay) {
      // Queue exhausted: continue the station via up-next when possible.
      unawaited(_continueRadio());
    } else {
      _update(_state.copyWith(playing: false));
    }
  }

  /// Goes to the previous track, or restarts when past 3s or at the head.
  void previous() {
    final s = _state;
    if (s.positionMs > previousRestartThresholdMs) {
      seekTo(0);
      return;
    }
    if (s.shuffle) {
      // Shuffled backtrack follows the play history; empty history
      // restarts the track like the queue head does below.
      int? prev;
      if (_shuffleHistory.isNotEmpty) {
        final candidate = _shuffleHistory.removeLast();
        if (candidate >= 0 && candidate < s.queue.length) prev = candidate;
      }
      if (prev != null) {
        _update(_state.copyWith(index: prev));
        _startCurrent();
      } else {
        seekTo(0);
      }
      return;
    }
    if (s.index <= 0) {
      seekTo(0);
    } else {
      _update(_state.copyWith(index: s.index - 1));
      _startCurrent();
    }
  }

  /// Seeks to [ms], clamped to the known duration, and holds the target
  /// until the engine settles.
  void seekTo(int ms) {
    final duration = _state.durationMs;
    var target = ms < 0 ? 0 : ms;
    if (duration > 0 && target > duration) target = duration;
    unawaited(_engine.seekTo(target));
    _pendingSeekTargetMs = target;
    _pendingSeekAt = DateTime.now();
    _update(
      _state.copyWith(positionMs: target, seekEpoch: _state.seekEpoch + 1),
    );
  }

  /// Sets engine and state volume, clamped to 0..100.
  void setVolume(int v) {
    unawaited(_engine.setVolume(v));
    _update(_state.copyWith(volume: v.clamp(0, 100)));
  }

  /// Flips the shuffle flag, forgetting backtrack history.
  void toggleShuffle() {
    _update(_state.copyWith(shuffle: !_state.shuffle));
    _shuffleHistory.clear();
    refreshPrefetch();
  }

  /// Sets the shuffle flag.
  void setShuffle(bool v) {
    _update(_state.copyWith(shuffle: v));
    _shuffleHistory.clear();
    refreshPrefetch();
  }

  /// Merges late-arriving release metadata into the matching queue/current
  /// track (from LRCLIB or InnerTube) so downstream consumers pick it up.
  void updateTrackMetadata(
    String videoId, {
    List<ArtistRef> artists = const [],
    AlbumRef? album,
    List<Thumbnail> thumbnails = const [],
    String? title,
  }) {
    final incomingTitle = title?.trim();
    final hasNoUpdates =
        artists.isEmpty &&
        album == null &&
        thumbnails.isEmpty &&
        (incomingTitle == null || incomingTitle.isEmpty);
    if (hasNoUpdates) return;
    Track fix(Track t) {
      if (t.videoId != videoId) return t;
      final existingKeys = t.artists.map((a) => canonical(a.name)).toSet();
      final incomingAddsArtist = artists.any(
        (a) => !existingKeys.contains(canonical(a.name)),
      );
      final incomingAddsIdentity = artists.any((incoming) {
        final key = canonical(incoming.name);
        return t.artists.any(
          (existing) =>
              canonical(existing.name) == key &&
              (existing.browseId == null || existing.browseId!.isEmpty) &&
              incoming.browseId != null &&
              incoming.browseId!.isNotEmpty,
        );
      });
      final replaceArtist =
          t.artists.isEmpty ||
          t.artistNames().trim().toLowerCase() == 'release' ||
          artists.length > t.artists.length ||
          incomingAddsArtist ||
          incomingAddsIdentity;
      final existingAlbum = t.album;
      final knownArtists = [...t.artists, ...artists];
      final existingAlbumIsUnlinkedArtist =
          existingAlbum != null &&
          (existingAlbum.browseId == null || existingAlbum.browseId!.isEmpty) &&
          existingAlbum.kind == null &&
          knownArtists.any(
            (a) => canonical(a.name) == canonical(existingAlbum.name),
          );
      AlbumRef? mergedAlbum;
      if (album == null && existingAlbumIsUnlinkedArtist) {
        mergedAlbum = null;
      } else if (album == null) {
        mergedAlbum = existingAlbum;
      } else if (existingAlbum == null) {
        mergedAlbum = album;
      } else if (existingAlbum.name.trim().toLowerCase() == 'release') {
        mergedAlbum = album;
      } else if (existingAlbumIsUnlinkedArtist) {
        mergedAlbum = album;
      } else if ((existingAlbum.browseId == null ||
              existingAlbum.browseId!.isEmpty) &&
          album.browseId != null &&
          album.browseId!.isNotEmpty) {
        mergedAlbum = album;
      } else if (existingAlbum.kind == null && album.kind != null) {
        mergedAlbum = AlbumRef(
          album.name.isEmpty ? existingAlbum.name : album.name,
          browseId: album.browseId ?? existingAlbum.browseId,
          kind: album.kind,
          year: existingAlbum.year,
        );
      } else {
        mergedAlbum = existingAlbum;
      }
      // Year arrives later than the rest (extra album-page fetch in
      // enrichTrack): fill it in even when the album ref itself was
      // already resolved and kept above.
      final mergedYear =
          (mergedAlbum != null && mergedAlbum.year.trim().isNotEmpty)
          ? mergedAlbum.year
          : (album != null && album.year.trim().isNotEmpty ? album.year : '');
      final AlbumRef? finalAlbum =
          (mergedAlbum != null &&
              mergedAlbum.year.trim().isEmpty &&
              mergedYear.trim().isNotEmpty)
          ? AlbumRef(
              mergedAlbum.name,
              browseId: mergedAlbum.browseId,
              kind: mergedAlbum.kind,
              year: mergedYear,
            )
          : mergedAlbum;
      final seenUrls = <String>{};
      final mergedThumbnails = <Thumbnail>[];
      for (final th in [...t.thumbnails, ...thumbnails]) {
        if (seenUrls.add(th.url)) mergedThumbnails.add(th);
      }
      return t.copyWith(
        title: (incomingTitle != null && incomingTitle.isNotEmpty)
            ? incomingTitle
            : t.title,
        artists: (replaceArtist && artists.isNotEmpty)
            ? List.of(artists)
            : t.artists,
        album: finalAlbum,
        thumbnails: mergedThumbnails,
      );
    }

    _update(
      _state.copyWith(
        current: () => _state.current == null ? null : fix(_state.current!),
        queue: _state.queue.map(fix).toList(),
      ),
    );
  }

  /// Updates the rating of the track with [videoId] in queue and current.
  void updateTrackRating(String videoId, RatingStatus rating) {
    Track update(Track track) =>
        track.videoId == videoId ? track.copyWith(rating: rating) : track;
    _update(
      _state.copyWith(
        current: () => _state.current == null ? null : update(_state.current!),
        queue: _state.queue.map(update).toList(),
      ),
    );
  }

  /// Restamps every queued (and current) track found in [ratings] with a
  /// single state emission. Returns how many tracks changed; emits
  /// nothing when everything already matches, so batch stamp passes
  /// never churn the player stream.
  int updateTrackRatings(Map<String, RatingStatus> ratings) {
    if (ratings.isEmpty) return 0;
    var changed = 0;
    Track update(Track track) {
      final rating = ratings[track.videoId];
      if (rating == null || rating == track.rating) return track;
      changed++;
      return track.copyWith(rating: rating);
    }

    final current = _state.current;
    final queue = _state.queue.map(update).toList();
    final fixedCurrent = current == null ? null : update(current);
    if (changed == 0) return 0;
    _update(_state.copyWith(current: () => fixedCurrent, queue: queue));
    return changed;
  }

  /// Updates like/dislike counters; -1 values never overwrite known counts.
  void updateTrackStats(String videoId, int likeCount, int dislikeCount) {
    if (likeCount < 0 && dislikeCount < 0) return;
    Track update(Track track) {
      if (track.videoId != videoId) return track;
      return track.copyWith(
        likeCount: likeCount >= 0 ? likeCount : track.likeCount,
        dislikeCount: dislikeCount >= 0 ? dislikeCount : track.dislikeCount,
      );
    }

    _update(
      _state.copyWith(
        current: () => _state.current == null ? null : update(_state.current!),
        queue: _state.queue.map(update).toList(),
      ),
    );
  }

  /// Sets the album name of the track with [videoId]; blank names ignored.
  void updateTrackAlbum(String videoId, String albumName) {
    if (albumName.trim().isEmpty) return;
    updateTrackMetadata(videoId, album: AlbumRef(albumName));
  }

  /// Cycles repeat mode OFF -> ALL -> ONE -> OFF.
  void cycleRepeat() {
    final next = switch (_state.repeat) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    _update(_state.copyWith(repeat: next));
    refreshPrefetch();
  }

  /// Sets the repeat [mode].
  void setRepeat(RepeatMode mode) {
    _update(_state.copyWith(repeat: mode));
    refreshPrefetch();
  }

  /// Flips the autoplay flag for radio continuation.
  void toggleAutoplay() => _update(_state.copyWith(autoplay: !_state.autoplay));

  /// Clears the current error message.
  void clearError() => _update(_state.copyWith(error: () => null));

  /// Resolves the current track's stream URL and starts engine playback
  /// under a fresh token.
  void _startCurrent() {
    final queue = _state.queue;
    final index = _state.index;
    if (index < 0 || index >= queue.length) return;
    final track = queue[index];
    final token = ++_playToken;
    _streamRetries = 0;
    _recycledForEpisode = false;
    _loadedVideoId = null;
    // Consume the prefetched stream when it matches; otherwise drop it.
    // Prefetch only ever skips the resolve step — the engine still
    // opens/buffers the URL, so a stale (expired) URL falls back to a
    // fresh resolve below.
    final reused = track.videoId == _prefetchedVideoId
        ? _prefetchedStream
        : null;
    _prefetchGen++;
    _prefetchedVideoId = null;
    _prefetchedStream = null;
    // A previous track's ticker must not publish its old engine position
    // while the next stream is resolving.
    _ticker?.cancel();
    _ticker = null;
    unawaited(_engine.stop());
    _pendingSeekTargetMs = null;
    _pendingSeekAt = null;
    _update(
      _state.copyWith(
        current: () => track,
        loading: true,
        playing: false,
        stopped: false,
        positionMs: 0,
        durationMs: track.durationSec * 1000,
        error: () => null,
      ),
    );
    saveSession();
    unawaited(_startCurrentAsync(track, token, reused));
  }

  Future<void> _startCurrentAsync(
    Track track,
    int token,
    ResolvedStream? reused,
  ) async {
    ResolvedStream? stream = reused;
    if (stream == null) {
      try {
        stream = await _resolveStream(track.videoId);
      } catch (_) {
        stream = null;
      }
    }
    if (token != _playToken) return;
    if (stream == null) {
      // Dead resolve family: restart the backend stack before giving up.
      if (await _tryBackendRestart(track, token)) return;
      _update(
        _state.copyWith(
          loading: false,
          error: () => 'No playable stream (region/age restriction?)',
        ),
      );
      return;
    }
    var ok = await _playUrl(stream.url);
    // URLs can die server-side before expiry (edge 403 on fresh,
    // IP-correct URLs); retry once under a fresh visitor, whether the
    // dead URL came from prefetch or a direct resolve.
    if (!ok) {
      final fresh = await _resolveFresh(track.videoId);
      if (token != _playToken) return;
      if (fresh != null) {
        stream = fresh;
        ok = await _playUrl(fresh.url);
      }
    }
    if (token != _playToken) return;
    if (!ok) {
      // Dead URL family: restart the backend stack before giving up.
      if (await _tryBackendRestart(track, token)) return;
      _update(
        _state.copyWith(
          loading: false,
          error: () => 'Playback failed to start',
        ),
      );
      return;
    }
    if (token == _playToken) _loadedVideoId = track.videoId;
    _update(_state.copyWith(loading: false, playing: true));
    updateTrackStats(track.videoId, stream.likes, stream.dislikes);
    _startTicker(freshStart: true);
    // Prefetch the next track while this one plays for gapless-ish handoff.
    if (token == _playToken) {
      final cur = _state;
      if (cur.queue.isNotEmpty &&
          cur.index >= 0 &&
          cur.index < cur.queue.length) {
        prefetchNextFor(cur.index, List.of(cur.queue));
      }
    }
  }

  /// Drops any prefetched next-track stream and cancels its resolve.
  void _clearPrefetch() {
    _prefetchGen++;
    _prefetchedVideoId = null;
    _prefetchedStream = null;
  }

  /// Re-resolves the expected next track for the current queue position.
  void refreshPrefetch() {
    final s = _state;
    if (s.current == null || s.stopped) {
      _clearPrefetch();
      return;
    }
    if (s.queue.isEmpty || s.index < 0 || s.index >= s.queue.length) {
      _clearPrefetch();
      return;
    }
    prefetchNextFor(s.index, List.of(s.queue));
  }

  /// Resolves the deterministic next track in the background.
  ///
  /// Skipped for shuffle (next is random) and repeat ONE (next is current).
  /// The result is only kept when the queue/index still point at the same
  /// next videoId, so queue edits safely invalidate it.
  void prefetchNextFor(int currentIndex, List<Track> queueSnapshot) {
    final gen = ++_prefetchGen;
    final s = _state;
    if (s.shuffle || s.repeat == RepeatMode.one) {
      _prefetchedVideoId = null;
      _prefetchedStream = null;
      return;
    }
    final nextIndex = _deterministicNext(currentIndex, queueSnapshot, s.repeat);
    if (nextIndex < 0) {
      _prefetchedVideoId = null;
      _prefetchedStream = null;
      return;
    }
    final nextTrack = (nextIndex >= 0 && nextIndex < queueSnapshot.length)
        ? queueSnapshot[nextIndex]
        : null;
    if (nextTrack == null) return;
    if (nextTrack.videoId == _prefetchedVideoId && _prefetchedStream != null) {
      return;
    }
    _prefetchedVideoId = null;
    _prefetchedStream = null;
    unawaited(_prefetchAsync(gen, currentIndex, nextIndex, nextTrack.videoId));
  }

  int _deterministicNext(
    int currentIndex,
    List<Track> queue,
    RepeatMode repeat,
  ) {
    if (currentIndex + 1 >= 0 && currentIndex + 1 < queue.length) {
      return currentIndex + 1;
    }
    if (repeat == RepeatMode.all && queue.isNotEmpty) return 0;
    return -1;
  }

  Future<void> _prefetchAsync(
    int gen,
    int currentIndex,
    int nextIndex,
    String videoId,
  ) async {
    ResolvedStream? stream;
    try {
      stream = await _resolveStream(videoId);
    } catch (_) {
      return;
    }
    if (gen != _prefetchGen) return;
    final cur = _state;
    final expectedNext = _deterministicNext(
      currentIndex,
      cur.queue,
      cur.repeat,
    );
    final actual = (expectedNext >= 0 && expectedNext < cur.queue.length)
        ? cur.queue[expectedNext]
        : null;
    if (cur.index == currentIndex &&
        expectedNext == nextIndex &&
        actual?.videoId == videoId &&
        stream != null) {
      _prefetchedVideoId = videoId;
      _prefetchedStream = stream;
    }
  }

  /// Advances on natural finish unless explicitly stopped.
  Future<void> _onTrackFinished() async {
    if (_state.stopped) return;
    // Duplicate completed deliveries for one ending arrive back-to-back;
    // without this guard every other song gets skipped. A pending manual
    // seek (e.g. seek-to-end as skip) always counts as a fresh ending.
    final now = DateTime.now();
    if (_pendingSeekTargetMs == null &&
        _lastFinishAt != null &&
        now.difference(_lastFinishAt!) < finishDebounce) {
      return;
    }
    _lastFinishAt = now;
    if (_state.sleepTimerMode == SleepTimerMode.endOfTrack) {
      _clearSleepTimer();
      pause();
      return;
    }
    if (_state.sleepTimerMode == SleepTimerMode.endOfQueue && _isQueueEnd()) {
      _clearSleepTimer();
      pause();
      return;
    }
    next(manual: false);
  }

  /// Appends unseen up-next tracks and starts the first one.
  Future<void> _continueRadio() async {
    final current = _state.current;
    if (current == null) {
      _update(_state.copyWith(playing: false));
      return;
    }
    List<Track> upcoming;
    try {
      upcoming = await _tube.upNext(
        current.videoId,
        playlistId: current.radioPlaylistId,
      );
    } catch (_) {
      upcoming = [];
    }
    final known = _state.queue.map((q) => q.videoId).toSet();
    upcoming = upcoming.where((t) => !known.contains(t.videoId)).toList();
    if (upcoming.isEmpty) {
      _update(_state.copyWith(playing: false));
      return;
    }
    final at = _state.queue.length;
    _update(_state.copyWith(queue: [..._state.queue, ...upcoming], index: at));
    _startCurrent();
  }

  /// Whether a raw engine [pos] read during a fresh-start hold is the
  /// restarted track (clears the hold) rather than the old track's
  /// ghost. True when back near zero, when moving between polls, or
  /// when the hold times out so a wedged engine never pins 0 forever.
  bool _isFreshEnginePosition(int pos) {
    final start = _freshHoldStart;
    final timedOut =
        start != null &&
        DateTime.now().difference(start) >= freshPositionTimeout;
    final restarted =
        pos <= freshPositionThresholdMs ||
        (_lastRawEnginePos != null && pos != _lastRawEnginePos);
    if (timedOut || restarted) {
      _awaitingFreshPosition = false;
      return true;
    }
    return false;
  }

  /// Polls engine position/duration every 500ms, masking slow seeks and
  /// persisting the session. With [freshStart], the first reads are
  /// held at 0 until the engine demonstrably restarts (see
  /// [_awaitingFreshPosition]): right after a new track opens, the
  /// engine briefly keeps reporting the previous track's position.
  void _startTicker({bool freshStart = false}) {
    _ticker?.cancel();
    if (freshStart) {
      _awaitingFreshPosition = true;
      _freshHoldStart = DateTime.now();
      _lastRawEnginePos = null;
    }
    final token = _playToken;
    _ticker = Timer.periodic(tickerInterval, (_) {
      if (token != _playToken) {
        _ticker?.cancel();
        _ticker = null;
        return;
      }
      var rawPos = _engine.positionMs();
      if (rawPos < 0) rawPos = 0;
      final target = _pendingSeekTargetMs;
      int pos;
      if (target != null) {
        final age = _pendingSeekAt == null
            ? Duration.zero
            : DateTime.now().difference(_pendingSeekAt!);
        final arrived = (rawPos - target).abs() <= seekArrivalToleranceMs;
        final expired = age >= seekSettleTimeout;
        // Network-stream seeks routinely take seconds (buffer flush +
        // re-request). Report the target until the engine demonstrably
        // arrives (1s window) or a generous timeout elapses.
        if (!expired && !arrived) {
          pos = target;
        } else {
          _pendingSeekTargetMs = null;
          _pendingSeekAt = null;
          pos = rawPos;
        }
      } else if (_awaitingFreshPosition) {
        // The new track starts at 0; anything large or frozen here is
        // the old track's ghost. Publish 0 until the engine restarts
        // (back near zero, or moving) or the hold times out.
        pos = _isFreshEnginePosition(rawPos) ? rawPos : 0;
      } else {
        pos = rawPos;
      }
      _lastRawEnginePos = rawPos;
      // A held (likely stale) duration is as wrong as a held position:
      // keep the catalog duration until the engine restarts.
      final len = _awaitingFreshPosition ? 0 : _engine.durationMs();
      final playing = _engine.isPlaying();
      if (token != _playToken) return;
      final cur = _state;
      _update(
        cur.copyWith(
          positionMs: pos,
          durationMs: len > 0 ? len : cur.durationMs,
          playing: playing || cur.loading,
        ),
      );
      if (playing &&
          DateTime.now().millisecondsSinceEpoch - _lastSessionSaveMs > 15000) {
        saveSession();
      }
    });
  }
}
