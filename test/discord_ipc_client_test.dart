// End-to-end test of the pure-Dart Discord IPC client against a fake
// Discord server: a real unix socket speaking the documented protocol.
// Covers the full lifecycle (handshake -> push -> clear -> close), the
// PING/PONG keepalive, and what happens when the server rejects the
// handshake — none of which needs a live Discord client.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/discord_ipc.dart';

/// A minimal Discord IPC server: handshakes, acks activity updates,
/// answers pings, and records every frame it is sent.
class _FakeDiscordServer {
  _FakeDiscordServer._(this._server, this.path);

  static Future<_FakeDiscordServer> start() async {
    final dir = Directory.systemTemp.createTempSync('nt-discord-ipc');
    final path = '${dir.path}/discord-ipc-0';
    final started = Completer<_FakeDiscordServer>();
    // A socket remembers the zone it was made in, so bind here: the reply
    // to a teardown can hit a client that already hung up, and that EPIPE
    // must not fail the test.
    runZonedGuarded(
      () async {
        final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        final fake = _FakeDiscordServer._(server, path);
        server.listen(fake._onConnection);
        started.complete(fake);
      },
      (Object error, StackTrace stack) {
        if (!started.isCompleted) started.completeError(error, stack);
      },
    );
    return started.future;
  }

  final ServerSocket _server;
  final String path;

  /// Payloads of every FRAME the client sent (op 1).
  final sent = <Map<String, dynamic>>[];

  /// Opcodes the client sent, in order.
  final opcodes = <int>[];

  /// Sends a PING to the client as soon as it connects.
  bool sendPingOnConnect = false;

  /// Answers our CLOSE with an ERROR frame, which is what the live client
  /// does — and what made a retiring session able to poison the next one.
  bool replyToCloseWithError = false;

  Socket? _client;
  final _reader = RpcFrameReader();
  Completer<void>? _handshakeSeen;
  Completer<void>? _activitySeen;
  Completer<void>? _clearSeen;
  Completer<void>? _closeSeen;

  /// Completes once the client has closed the session.
  Future<void> get closeSeen => (_closeSeen ??= Completer<void>()).future;

  /// Handshake payloads the client sent, for asserting their shape.
  final handshakes = <Map<String, dynamic>>[];

  /// CLOSE payloads the client sent, for asserting how it tears down.
  final closes = <String>[];

  /// PONG payloads the client sent in answer to our pings.
  final pongs = <String>[];

  /// Completes once the client has pushed an activity.
  Future<void> get activityPushed =>
      (_activitySeen ??= Completer<void>()).future;

  /// Completes once the client has sent its handshake frame, so the test
  /// can answer it.
  Future<void> get handshakeAnswered =>
      (_handshakeSeen ??= Completer<void>()).future;

  /// Completes once the client has cleared the presence.
  Future<void> get activityCleared => (_clearSeen ??= Completer<void>()).future;

  void _onConnection(Socket socket) {
    _client = socket;
    socket.listen(_onData, onError: (Object _) {});
    if (sendPingOnConnect) {
      // A bare payload: the client must answer PONG with it verbatim.
      socket.add(encodeRpcFrame(3, '"ping-nonce"'));
    }
  }

  void _onData(List<int> chunk) {
    for (final frame in _reader.add(chunk)) {
      opcodes.add(frame.opcode);
      if (frame.opcode == 4) {
        pongs.add(frame.payload);
        continue;
      }
      if (frame.opcode == 0) {
        handshakes.add(jsonDecode(frame.payload) as Map<String, dynamic>);
        if (!(_handshakeSeen?.isCompleted ?? true)) _handshakeSeen!.complete();
        continue;
      }
      if (frame.opcode == 2) {
        closes.add(frame.payload);
        if (!(_closeSeen?.isCompleted ?? true)) _closeSeen!.complete();
        if (replyToCloseWithError) _replyToCloseWithError();
        continue;
      }
      if (frame.opcode != 1) continue;
      final json = jsonDecode(frame.payload) as Map<String, dynamic>;
      if (json['cmd'] != 'SET_ACTIVITY') continue;
      sent.add(json);
      if ((json['args'] as Map)['activity'] != null) {
        if (!(_activitySeen?.isCompleted ?? true)) _activitySeen!.complete();
      } else {
        if (!(_clearSeen?.isCompleted ?? true)) _clearSeen!.complete();
      }
    }
  }

  /// Answers the handshake with READY.
  void answerHandshake() {
    _client?.add(
      encodeRpcFrame(
        1,
        jsonEncode({
          'cmd': 'DISPATCH',
          'evt': 'READY',
          'data': {
            'v': 1,
            'config': {'cdn_host': 'cdn.discordapp.com'},
            'user': {'id': '1', 'username': 'probe'},
          },
        }),
      ),
    );
  }

  /// Rejects the handshake the way Discord rejects a bad application id.
  void rejectHandshake({
    int code = 4000,
    String message = 'Invalid Client ID',
  }) {
    _client?.add(
      encodeRpcFrame(
        1,
        jsonEncode({
          'cmd': 'HANDSHAKE',
          'evt': 'ERROR',
          'data': {'code': code, 'message': message},
        }),
      ),
    );
  }

  /// The exact frame the live Discord sends back to a nonce-less
  /// `{"cmd":"CLOSE"}` frame, verbatim.
  void _replyToCloseWithError() {
    try {
      _client?.add(
        encodeRpcFrame(
          1,
          jsonEncode({
            'cmd': 'CLOSE',
            'data': {'code': 4000, 'message': 'Payload requires a nonce'},
            'evt': 'ERROR',
            'nonce': null,
          }),
        ),
      );
    } catch (_) {
      // The peer already hung up; nothing to reply to.
    }
  }

  /// Closes the connection without a CLOSE frame (Discord restarting).
  void dropConnection() => _client?.destroy();

  /// Frames the client sent, as opcodes, so CLOSE can be asserted.
  List<int> get clientOpcodes => List.of(opcodes);

  Future<void> dispose() async {
    try {
      await _client?.close();
    } catch (_) {}
    await _server.close();
    try {
      final dir = Directory(path).parent;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Reads one frame back off a raw socket (for the PONG assertion).
({int opcode, String payload}) readOneFrame(List<int> chunk) {
  final view = ByteData.view(Uint8List.fromList(chunk).buffer);
  final opcode = view.getUint32(0, Endian.little);
  final len = view.getUint32(4, Endian.little);
  return (
    opcode: opcode,
    payload: utf8.decode(chunk.sublist(8, 8 + len), allowMalformed: true),
  );
}

void main() {
  late _FakeDiscordServer server;

  setUp(() async => server = await _FakeDiscordServer.start());
  tearDown(() async => server.dispose());

  test('handshakes, pushes an activity, clears it and closes', () async {
    final client = DiscordIpcClient(socketPaths: [server.path]);
    await client.initialize('1552404006498869318');

    // The handshake must be in flight before we answer it.
    final connecting = client.connect();
    await server.handshakeAnswered;

    // Opcode 0 with the documented handshake payload.
    expect(server.clientOpcodes.first, 0);
    expect(server.handshakes.single, {
      'v': 1,
      'client_id': '1552404006498869318',
    });
    server.answerHandshake();
    await connecting;
    expect(client.isConnected, isTrue);

    await client.setActivity(
      DiscordActivity(
        details: 'Song Title',
        state: 'Some Artist',
        timestamps: DiscordTimestamps(start: 10, end: 210),
        assets: DiscordAssets(largeText: 'Some Album'),
        buttons: [
          DiscordButton(
            label: 'Listen on YouTube Music',
            url: 'https://music.youtube.com/watch?v=abc',
          ),
        ],
      ),
    );
    await server.activityPushed;

    final args = server.sent.single['args'] as Map<String, dynamic>;
    final activity = args['activity'] as Map<String, dynamic>;
    expect(server.sent.single['cmd'], 'SET_ACTIVITY');
    expect(server.sent.single['nonce'], isNotEmpty);
    expect(args['pid'], isA<int>());
    expect(activity['details'], 'Song Title');
    expect(activity['state'], 'Some Artist');
    expect(activity['timestamps'], {'start': 10, 'end': 210});
    expect(activity['buttons'], hasLength(1));

    await client.clearActivity();
    await server.activityCleared;
    final cleared = server.sent.last['args'] as Map<String, dynamic>;
    expect(cleared['activity'], isNull);

    await client.disconnect();
    expect(client.isConnected, isFalse);
    await server.closeSeen;
    // The teardown is the CLOSE opcode, not a command frame: every command
    // frame needs a nonce, and Discord answers a nonce-less one with
    // `4000 Payload requires a nonce` (seen on the live client).
    expect(server.clientOpcodes, contains(2));
    expect(server.closes, ['{}']);
    expect(
      server.clientOpcodes.where((op) => op == 1).length,
      server.sent.length,
      reason: 'every opcode-1 frame is a nonce-bearing SET_ACTIVITY',
    );
  });

  test('answers a server PING with PONG carrying the same payload', () async {
    final client = DiscordIpcClient(socketPaths: [server.path]);
    await client.initialize('1');
    server.sendPingOnConnect = true;

    final connecting = client.connect();
    await server.handshakeAnswered;
    server.answerHandshake();
    await connecting;

    for (var i = 0; i < 20 && server.pongs.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(server.pongs, ['"ping-nonce"']);

    await client.disconnect();
  });

  test('a rejected handshake surfaces Discord\'s reason', () async {
    final client = DiscordIpcClient(socketPaths: [server.path]);
    await client.initialize('999');
    final connecting = client.connect();
    await server.handshakeAnswered;
    server.rejectHandshake(message: 'Invalid Client ID');
    await expectLater(
      connecting,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Invalid Client ID'),
        ),
      ),
    );
    // The socket is torn down, so nothing is left half-open.
    expect(client.isConnected, isFalse);
  });

  test('a CLOSE carrying an error surfaces the reason', () async {
    // Verified against the live Discord client: a rejected handshake comes
    // back on opcode 2 (CLOSE) with {"code":4000,"message":"..."}, not as
    // a FRAME/ERROR dispatch.
    final client = DiscordIpcClient(socketPaths: [server.path]);
    await client.initialize('999');
    final connecting = client.connect();
    await server.handshakeAnswered;
    server._client!.add(
      encodeRpcFrame(
        2,
        jsonEncode({'code': 4000, 'message': 'Invalid Client ID'}),
      ),
    );
    await expectLater(
      connecting,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Invalid Client ID',
        ),
      ),
    );
    expect(client.isConnected, isFalse);
  });

  test('a server that hangs up mid-handshake ends the attempt', () async {
    final client = DiscordIpcClient(socketPaths: [server.path]);
    await client.initialize('1');
    final connecting = client.connect();
    await server.handshakeAnswered;
    server.dropConnection();
    await expectLater(connecting, throwsA(isA<StateError>()));
    expect(client.isConnected, isFalse);
  });

  test('reconnecting after a disconnect works and re-handshakes', () async {
    final client = DiscordIpcClient(socketPaths: [server.path]);
    await client.initialize('1');

    final first = client.connect();
    await server.handshakeAnswered;
    server.answerHandshake();
    await first;
    expect(client.isConnected, isTrue);
    await client.disconnect();
    expect(client.isConnected, isFalse);

    // A second connect opens a fresh socket and handshakes again.
    final second = client.connect();
    for (var i = 0; i < 20 && server.handshakes.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(server.handshakes, hasLength(2), reason: 're-handshakes');
    expect(client.isConnected, isFalse, reason: 'not answered yet');
    server.answerHandshake();
    await second;
    expect(client.isConnected, isTrue);
    await client.disconnect();
  });

  test(
    'a late reply to the old session cannot fail the new handshake',
    () async {
      // Discord answers a CLOSE with a frame of its own, so a retiring socket
      // is still talking while the next session is handshaking. Those trailing
      // frames must not reach the new handshake — otherwise a lost link is
      // reported as the *next* connect failing with the old session's error,
      // and the presence can never come back.
      final client = DiscordIpcClient(socketPaths: [server.path]);
      await client.initialize('1');
      server.replyToCloseWithError = true;

      final first = client.connect();
      await server.handshakeAnswered;
      server.answerHandshake();
      await first;

      // Deliberately not awaited: the reconnect overlaps the teardown, which
      // is when a shared reader and completer would cross over.
      unawaited(client.disconnect());
      final second = client.connect();
      for (var i = 0; i < 40 && server.handshakes.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(server.handshakes, hasLength(2), reason: 're-handshakes');
      server.answerHandshake();

      await expectLater(second, completes);
      expect(client.isConnected, isTrue);

      await client.setActivity(DiscordActivity(details: 'after reconnect'));
      await server.activityPushed;
      expect(client.isConnected, isTrue);
      await client.disconnect();
    },
  );
}
