// Sleep inhibition while playing (Linux): holds a systemd sleep
// lock for the playing span so suspend/hibernate waits instead of
// cutting playback. The lock lives in a short-lived
// `systemd-inhibit` child (not in-process): if the app crashes, the
// child notices the dead parent and exits, releasing the lock
// instead of blocking sleep forever. Linux-only no-op elsewhere;
// every step is best-effort so a missing systemd-inhibit can never
// break playback.

import 'dart:async';
import 'dart:io' show Platform, Process, pid;

import '../core/player/player_controller.dart';
import '../core/player/player_state.dart';

/// Async factory for the lock holder, injectable for tests.
typedef SleepInhibitRunner = Future<SleepInhibitHandle> Function();

/// One held sleep lock.
abstract interface class SleepInhibitHandle {
  Future<void> release();
}

/// `systemd-inhibit` child wrapper: killing it releases the lock.
class _SystemdHandle implements SleepInhibitHandle {
  _SystemdHandle(this._proc);

  final Process _proc;

  @override
  Future<void> release() async {
    try {
      _proc.kill();
    } catch (_) {}
    try {
      await _proc.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

/// Blocks OS sleep while the player is playing, releasing on
/// pause/stop. Listens to player states like MPRIS; construct, then
/// [start]; [dispose] tears down (also releases any held lock, so
/// quitting never leaves sleep blocked).
class SleepInhibitService {
  SleepInhibitService({
    required PlayerController controller,
    SleepInhibitRunner? runner,
  }) {
    _controller = controller;
    _runner = runner ?? _systemdRunner;
  }

  late final PlayerController _controller;
  late final SleepInhibitRunner _runner;

  StreamSubscription<PlayerState>? _sub;
  SleepInhibitHandle? _lock;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (!Platform.isLinux) return;
    _sub = _controller.states.listen(_onState);
    await _onState(_controller.state);
  }

  Future<void> _onState(PlayerState s) async {
    if (s.playing) {
      if (_lock != null) return;
      try {
        _lock = await _runner();
      } catch (_) {
        _lock = null;
      }
    } else {
      final lock = _lock;
      _lock = null;
      if (lock != null) {
        try {
          await lock.release();
        } catch (_) {}
      }
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    final lock = _lock;
    _lock = null;
    if (lock != null) {
      try {
        await lock.release();
      } catch (_) {}
    }
  }

  /// Spawns `systemd-inhibit` holding a sleep lock for as long as the
  /// child lives. The child watches our pid and exits on its own when
  /// we die, so a crash can't block sleep indefinitely.
  static Future<SleepInhibitHandle> _systemdRunner() async {
    final proc = await Process.start('systemd-inhibit', [
      '--what=sleep',
      '--who=NixieTube',
      '--why=Playback active',
      '--mode=block',
      'sh',
      '-c',
      'while kill -0 "\$1" 2>/dev/null; do sleep 10; done',
      'sh',
      pid.toString(),
    ]);
    // Reap (and observe) the child; release() kills it first.
    unawaited(proc.exitCode.then((_) {}));
    return _SystemdHandle(proc);
  }
}
