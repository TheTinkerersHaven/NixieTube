// Tests for the Discord + MPRIS reconnect behaviour. Both integrations
// are best-effort: Discord often starts after us (or restarts while we
// run), the session bus can come and go, and another instance can hold
// the MPRIS name until it exits. So each service keeps a periodic retry
// alive while enabled, and re-pushes its state once the link is back.
// Fakes stand in for the native RPC client and the session bus.

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/mpris.dart';

/// Retry cadence used by the tests: fast enough to observe a handful of
/// ticks in a short test.
const _retry = Duration(milliseconds: 20);

/// Two or three retry ticks plus slack.
const _settle = Duration(milliseconds: 120);

class _FakeRpc implements DiscordRpc {
  /// Handshake attempts that fail before one succeeds.
  int connectFailures = 0;

  /// Thrown by [initialize] while set.
  Object? initError;

  bool connected = false;
  var initializes = 0;
  var connects = 0;
  var activities = 0;
  var clears = 0;
  var disconnects = 0;

  @override
  bool get isConnected => connected;

  @override
  Future<void> initialize(String appId) async {
    initializes++;
    final error = initError;
    if (error != null) throw error;
    if (singletonTaken && initializes > 1) {
      // The real client sets its singleton before failing, so every
      // re-initialize after a disconnect reports this.
      throw StateError('RPC client already been initialized');
    }
  }

  /// Emulates the native client keeping its singleton across reconnects.
  bool singletonTaken = false;

  @override
  Future<void> connect() async {
    connects++;
    if (connectAlwaysFails) {
      throw Exception('Discord is not running');
    }
    if (connectFailures > 0) {
      connectFailures--;
      throw Exception('Discord is not running');
    }
    connected = true;
  }

  /// Makes every connect fail, as a native client that never finished
  /// standing up would.
  bool connectAlwaysFails = false;

  @override
  Future<void> setActivity(DiscordActivity activity) async {
    activities++;
  }

  @override
  Future<void> clearActivity() async {
    clears++;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    connected = false;
  }
}

class _FakeBus extends DBusClient {
  _FakeBus(this.reply) : super(DBusAddress('unix:path=/nonexistent'));

  final DBusRequestNameReply reply;
  var requests = 0;
  var pings = 0;
  var closes = 0;

  /// Simulates a session bus that went away: pings never come back.
  bool pingFails = false;

  @override
  Future<void> registerObject(DBusObject object) async {
    object.client = this;
  }

  @override
  Future<DBusRequestNameReply> requestName(
    String name, {
    Set<DBusRequestNameFlag> flags = const {},
  }) async {
    requests++;
    return reply;
  }

  @override
  Future<void> ping([String destination = 'org.freedesktop.DBus']) async {
    pings++;
    if (pingFails) throw DBusClosedException();
  }

  @override
  Future<void> emitSignal({
    String? destination,
    required DBusObjectPath path,
    required String interface,
    required String name,
    Iterable<DBusValue> values = const [],
  }) async {}

  @override
  Future<void> close() async {
    closes++;
  }
}


Track _track(String id) => Track(videoId: id, title: 'T$id', durationSec: 200);

PlayerState _playing() => PlayerState(
  current: _track('a'),
  playing: true,
  positionMs: 30000,
  durationMs: 200000,
  volume: 80,
  queue: [_track('a')],
  index: 0,
);

PlayerController _player() {
  final dir = Directory.systemTemp.createTempSync('nt-retry-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final tube = InnerTube();
  addTearDown(tube.close);
  final player = PlayerController(
    engine: FakeEngine(),
    tube: tube,
    configDirPath: dir.path,
  );
  addTearDown(player.dispose);
  return player;
}

ArtworkStore _artwork() {
  final dir = Directory.systemTemp.createTempSync('nt-retry-art');
  addTearDown(() => dir.deleteSync(recursive: true));
  final art = ArtworkStore(cacheDirPath: '${dir.path}/art');
  addTearDown(art.close);
  return art;
}

void main() {
  group('discord presence', () {
    test('retries the handshake until Discord answers', () async {
      final rpc = _FakeRpc()..connectFailures = 2;
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      // Discord is not running: idle (with the cause, so the settings row
      // can explain it), nothing pushed, no key cached.
      expect(discord.status, startsWith('idle'));
      expect(discord.status, contains('Discord is not running'));
      expect(rpc.activities, 0);
      await Future<void>.delayed(_settle);
      // First update plus two failed ticks, third attempt lands.
      expect(rpc.connects, 3);
      expect(rpc.initializes, 1);
      expect(rpc.activities, 1);
      expect(discord.status, 'active');
      // Once up, ticks do nothing (no extra pushes).
      await Future<void>.delayed(_settle);
      expect(rpc.activities, 1);
    });

    test('re-pushes the activity after the link drops', () async {
      final rpc = _FakeRpc();
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      expect(discord.status, 'active');
      expect(rpc.activities, 1);
      // Discord restarted: the link is gone while the player state is
      // unchanged, so only the retry timer can notice.
      rpc.connected = false;
      await Future<void>.delayed(_settle);
      expect(rpc.connects, 2);
      expect(rpc.activities, 2);
      expect(discord.status, 'active');
    });

    test('a half-built client is never mistaken for a working one', () async {
      // The package assigns its Dart singleton before it stands the
      // native client up, so an attempt that fails partway leaves the
      // singleton behind: every retry then answers "already been
      // initialized" while connect can never succeed. Treating that
      // message as success would report a live presence that is not
      // there, so the real cause has to survive.
      final rpc = _FakeRpc()..initError = StateError('no IPC socket');
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      expect(discord.status, 'error: Bad state: no IPC socket');

      // Retries now hit the leftover singleton, and the link stays dead.
      rpc.initError = null;
      rpc.singletonTaken = true;
      rpc.connectAlwaysFails = true;
      await Future<void>.delayed(_settle * 2);
      // The client never came up, so the link is never even attempted:
      // poking a dead client would only add noise.
      expect(rpc.connects, 0);
      expect(discord.status, isNot('active'));
      // The original cause is kept, not masked by the singleton message.
      expect(discord.status, contains('no IPC socket'));
    });

    test('disabling and re-enabling the presence works again', () async {
      final rpc = _FakeRpc()..singletonTaken = true;
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      expect(discord.status, 'active');
      expect(rpc.initializes, 1);

      // Off: the IPC link drops and the status settles synchronously.
      discord.setEnabled(false);
      expect(discord.status, 'disabled');
      await Future<void>.delayed(_settle);
      expect(rpc.disconnects, 1);
      expect(discord.statusText, DiscordStatusText.app);

      // Back on. The cached init future must not be reused: the client
      // has to be initialized again, and the native singleton answers
      // "already been initialized" — which has to count as success or
      // the presence would stay dead until the app restarts.
      discord.setEnabled(true);
      await Future<void>.delayed(_settle);
      expect(rpc.initializes, 2, reason: 'initialize must run again');
      expect(discord.status, 'active');
      expect(rpc.connects, 2);
      expect(rpc.activities, 2);

      // And the status line still applies after the round trip.
      discord.setStatusText(DiscordStatusText.song);
      await Future<void>.delayed(_settle);
      expect(discord.status, 'active');
      expect(rpc.activities, 3);
    });

    test('switching the status line re-pushes the same track', () async {
      final rpc = _FakeRpc();
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      expect(discord.status, 'active');
      expect(rpc.activities, 1);
      expect(discord.statusText, DiscordStatusText.app);

      // The dedup key would otherwise swallow the new mode: nothing about
      // the player changed, so only an explicit clear re-pushes.
      discord.setStatusText(DiscordStatusText.album);
      expect(discord.statusText, DiscordStatusText.album);
      await Future<void>.delayed(_settle);
      expect(rpc.activities, 2);

      // Same mode again is a no-op.
      discord.setStatusText(DiscordStatusText.album);
      await Future<void>.delayed(_settle);
      expect(rpc.activities, 2);
    });

    test('reports a failing initialize and recovers from it', () async {
      final rpc = _FakeRpc()..initError = StateError('no RPC library');
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      expect(discord.status, 'error: Bad state: no RPC library');
      // The library comes back: the next tick initializes and pushes.
      rpc.initError = null;
      await Future<void>.delayed(_settle);
      expect(discord.status, 'active');
      expect(rpc.activities, 1);
    });

    test('a lost link waits out Discord\'s refusal window', () async {
      // Discord refuses a new handshake for roughly half a minute after a
      // session ends (measured against the live client). A retry faster
      // than that window only lands inside it, so the presence would sit
      // there reporting itself connected and never come back — the status
      // line picker then looks like it does nothing. So once a link has
      // been up, the retry floor is the window, not the fast cadence.
      final rpc = _FakeRpc();
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: const Duration(milliseconds: 5),
        reconnectInterval: const Duration(milliseconds: 300),
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      expect(discord.status, 'active');
      expect(rpc.connects, 1);
      // Let the tick that was armed before the link came up run, so the
      // timer is re-armed at the window rather than at the fast cadence.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(rpc.connects, 1, reason: 'a tick on a live link does nothing');

      // The link dies. The fast cadence must not be used any more.
      rpc.connected = false;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rpc.connects, 1, reason: 'no attempt inside the refusal window');

      // Past the window the retry runs and the presence recovers.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rpc.connects, greaterThan(1));
      expect(discord.status, 'active');
      discord.setEnabled(false);
    });

    test('disabling stops the retries and the pushes', () async {
      final rpc = _FakeRpc()..connectFailures = 1000;
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
        reconnectInterval: _retry,
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      await Future<void>.delayed(_settle);
      final attempts = rpc.connects;
      expect(attempts, greaterThan(1));
      discord.setEnabled(false);
      expect(discord.status, 'disabled');
      await Future<void>.delayed(_settle);
      expect(rpc.connects, attempts);
      expect(rpc.activities, 0);
      // Updates while disabled stay inert.
      await discord.update(_playing());
      expect(rpc.connects, attempts);
      expect(rpc.initializes, 1);
    });
  });

  group('mpris service', () {
    test('keeps retrying a name another instance owns', () async {
      final player = _player();
      final buses = <_FakeBus>[];
      final mpris = MprisService(
        controller: player,
        artworkStore: _artwork(),
        clientFactory: () {
          final bus = _FakeBus(
            buses.isEmpty
                ? DBusRequestNameReply.exists
                : DBusRequestNameReply.primaryOwner,
          );
          buses.add(bus);
          return bus;
        },
        retryInterval: _retry,
      );
      addTearDown(mpris.dispose);
      expect(await mpris.start(), isFalse);
      expect(mpris.active, isFalse);
      expect(mpris.lastError, 'another NixieTube instance owns the MPRIS name');
      // The other instance exits: the timer claims the name.
      await Future<void>.delayed(_settle);
      expect(buses, hasLength(2));
      expect(mpris.active, isTrue);
      expect(mpris.lastError, isNull);
      expect(buses.first.closes, 1);
      expect(buses.last.closes, 0);
      await mpris.stop();
      expect(buses.last.closes, 1);
    });

    test('reclaims the name after the connection drops', () async {
      final player = _player();
      final buses = <_FakeBus>[];
      final mpris = MprisService(
        controller: player,
        artworkStore: _artwork(),
        clientFactory: () {
          final bus = _FakeBus(DBusRequestNameReply.primaryOwner);
          buses.add(bus);
          return bus;
        },
        retryInterval: _retry,
      );
      addTearDown(mpris.dispose);
      expect(await mpris.start(), isTrue);
      expect(mpris.active, isTrue);
      expect(buses.single.pings, 0);
      // The session bus went away: pings stop coming back, so the
      // service drops the dead client and claims the name again.
      buses.single.pingFails = true;
      await Future<void>.delayed(_settle);
      expect(buses, hasLength(2));
      expect(buses.first.closes, 1);
      expect(mpris.active, isTrue);
      expect(mpris.lastError, isNull);
      await mpris.stop();
    });

    test(
      'a failed connect does not block the player or leak retries',
      () async {
        final player = _player();
        final buses = <_FakeBus>[];
        final mpris = MprisService(
          controller: player,
          artworkStore: _artwork(),
          clientFactory: () {
            final bus = _FakeBus(DBusRequestNameReply.exists);
            buses.add(bus);
            return bus;
          },
          retryInterval: _retry,
        );
        addTearDown(mpris.dispose);
        expect(await mpris.start(), isFalse);
        await Future<void>.delayed(_settle);
        final attempts = buses.length;
        expect(attempts, greaterThan(1));
        // Disabling the service (as the settings toggle does) ends the
        // loop and lets the app shut down cleanly.
        mpris.setEnabled(false);
        await Future<void>.delayed(_settle);
        expect(buses, hasLength(attempts));
        expect(mpris.active, isFalse);
      },
    );
  });
}
