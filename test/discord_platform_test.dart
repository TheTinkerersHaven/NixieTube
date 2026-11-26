// Discord Rich Presence on a host with no Discord client (phones).
//
// Discord exposes presence over a local IPC socket owned by the desktop
// client. A phone has neither, so the presence must stay inert — no
// handshake attempts, no retry timer — and say why in its status.

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/discord.dart';

class _CountingRpc implements DiscordRpc {
  int initializes = 0;
  int connects = 0;
  int activities = 0;

  @override
  bool isConnected = false;

  @override
  Future<void> initialize(String appId) async => initializes++;

  @override
  Future<void> connect() async => connects++;

  @override
  Future<void> setActivity(DiscordActivity activity) async => activities++;

  @override
  Future<void> clearActivity() async {}

  @override
  Future<void> disconnect() async => isConnected = false;
}

const _playing = PlayerState(current: null, playing: true);

void main() {
  test('an unsupported host never talks to a socket', () async {
    final rpc = _CountingRpc();
    final presence = DiscordPresence(enabled: true, supported: false, rpc: rpc);
    addTearDown(presence.dispose);

    // The requested "enabled" does not stick: there is nothing to enable.
    expect(presence.supported, isFalse);
    expect(presence.enabled, isFalse);
    expect(presence.status, discordUnsupportedStatus);

    await presence.update(_playing);
    expect(rpc.initializes, 0);
    expect(rpc.connects, 0);
    expect(rpc.activities, 0);
  });

  test('the toggle reports the platform instead of pretending', () async {
    final rpc = _CountingRpc();
    final presence = DiscordPresence(supported: false, rpc: rpc);
    addTearDown(presence.dispose);

    // Flipping the switch is a no-op the status line explains; nothing
    // is announced because nothing changed.
    presence.setEnabled(true);
    expect(presence.enabled, isFalse);
    expect(presence.status, discordUnsupportedStatus);
    expect(rpc.connects, 0);

    // A player state arriving later keeps the explanation, rather than
    // overwriting it with a bare "disabled".
    await presence.update(_playing);
    expect(presence.status, discordUnsupportedStatus);
  });

  test('a supported host is unaffected', () async {
    final rpc = _CountingRpc();
    final presence = DiscordPresence(supported: true, rpc: rpc);
    addTearDown(presence.dispose);

    expect(presence.status, 'disabled');
    presence.setEnabled(true);
    expect(presence.enabled, isTrue);
  });
}
