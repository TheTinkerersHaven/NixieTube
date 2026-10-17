// Tests for the Discord + MPRIS reconnect behaviour. Both integrations
// are best-effort: Discord often starts after us (or restarts while we
// run), the session bus can come and go, and another instance can hold
// the MPRIS name until it exits. So each service keeps a periodic retry
// alive while enabled, and re-pushes its state once the link is back.
// Fakes stand in for the native RPC client and the session bus.

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/artwork/artwork_store.dart';
import 'package:nixietube/core/innertube/inner_tube.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_engine.dart';
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
  }

  @override
  Future<void> connect() async {
    connects++;
    if (connectFailures > 0) {
      connectFailures--;
      throw Exception('Discord is not running');
    }
    connected = true;
  }

  @override
  Future<void> setActivity(RPCActivity activity) async {
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

class _FakeEngine implements PlayerEngine {
  @override
  Future<bool> play(String url) async => true;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seekTo(int ms) async {}
  @override
  Future<void> setVolume(int volume) async {}
  @override
  int positionMs() => 0;
  @override
  int durationMs() => 0;
  @override
  bool isPlaying() => false;
  @override
  Future<void> release() async {}
  @override
  void addListener(PlayerEngineListener listener) {}
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
    engine: _FakeEngine(),
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
      );
      addTearDown(discord.dispose);
      await discord.update(_playing());
      // Discord is not running: idle, nothing pushed, no key cached.
      expect(discord.status, 'idle');
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

    test('reports a failing initialize and recovers from it', () async {
      final rpc = _FakeRpc()..initError = StateError('no RPC library');
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
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

    test('disabling stops the retries and the pushes', () async {
      final rpc = _FakeRpc()..connectFailures = 1000;
      final discord = DiscordPresence(
        enabled: true,
        rpc: rpc,
        retryInterval: _retry,
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
