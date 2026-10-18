// Discord IPC wire-format tests: framing, the documented handshake and
// SET_ACTIVITY payloads, socket discovery order, and the field limits the
// activity object enforces. No socket and no Discord client involved.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/discord_ipc.dart';

/// Decodes one frame back into (opcode, payload) for assertions.
({int opcode, String payload}) _decode(List<int> bytes) {
  final view = ByteData.view(Uint8List.fromList(bytes).buffer);
  return (
    opcode: view.getUint32(0, Endian.little),
    payload: utf8.decode(bytes.sublist(8), allowMalformed: true),
  );
}

int _length(List<int> bytes) =>
    ByteData.view(Uint8List.fromList(bytes).buffer).getUint32(4, Endian.little);

void main() {
  group('framing', () {
    test('frame is little-endian opcode and length, then the payload', () {
      const payload = '{"v":1,"client_id":"123456789012345678"}';
      final frame = encodeRpcFrame(0, payload);
      // Opcode 0 as four little-endian zero bytes.
      expect(frame.sublist(0, 4), [0, 0, 0, 0]);
      // Length is the payload's UTF-8 byte count, little-endian.
      expect(_length(frame), utf8.encode(payload).length);
      expect(_decode(frame).payload, payload);
    });

    test('an opcode above 255 still spans four little-endian bytes', () {
      final frame = encodeRpcFrame(0x01020304, 'x');
      expect(frame.sublist(0, 4), [0x04, 0x03, 0x02, 0x01]);
      expect(_decode(frame).opcode, 0x01020304);
    });

    test('multi-byte payloads are measured in bytes, not characters', () {
      final frame = encodeRpcFrame(1, '⏸ ok');
      expect(_length(frame), utf8.encode('⏸ ok').length);
      expect(_decode(frame).payload, '⏸ ok');
    });

    test('reader reassembles a frame split across chunks', () {
      final frame = encodeRpcFrame(1, '{"evt":"READY"}');
      final reader = RpcFrameReader();
      // Nothing is emitted until the last byte lands.
      expect(reader.add(frame.sublist(0, 6)), isEmpty);
      expect(reader.add(frame.sublist(6, 9)), isEmpty);
      final frames = reader.add(frame.sublist(9));
      expect(frames, hasLength(1));
      expect(frames.single.opcode, 1);
      expect(frames.single.payload, '{"evt":"READY"}');
    });

    test('reader returns several frames from one chunk', () {
      final reader = RpcFrameReader();
      final chunk = [
        ...encodeRpcFrame(1, 'a'),
        ...encodeRpcFrame(3, 'b'),
        ...encodeRpcFrame(1, 'c'),
      ];
      expect(reader.add(chunk).map((f) => f.payload), ['a', 'b', 'c']);
    });

    test('reader keeps a partial tail buffered for the next chunk', () {
      final reader = RpcFrameReader();
      final one = encodeRpcFrame(1, 'one');
      final two = encodeRpcFrame(1, 'two');
      final frames = reader.add([...one, ...two.sublist(0, 4)]);
      expect(frames.map((f) => f.payload), ['one']);
      expect(reader.add(two.sublist(4)).map((f) => f.payload), ['two']);
    });

    test('an implausible length is rejected instead of buffering forever', () {
      final reader = RpcFrameReader();
      // 0x7FFFFFFF bytes of payload is not a Discord frame.
      expect(
        () => reader.add([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F]),
        throwsA(isA<RpcProtocolException>()),
      );
    });
  });

  group('handshake payload', () {
    test('matches the documented shape', () {
      final frame = encodeHandshakeFrame('123456789012345678');
      final decoded = _decode(frame);
      // Opcode 0 = HANDSHAKE.
      expect(decoded.opcode, 0);
      expect(jsonDecode(decoded.payload), {
        'v': 1,
        'client_id': '123456789012345678',
      });
    });
  });

  group('SET_ACTIVITY payload', () {
    DiscordActivity activity() => DiscordActivity(
      name: 'PROBE STATUS LINE',
      details: 'Song Title',
      state: 'Some Artist',
      timestamps: DiscordTimestamps(start: 100, end: 300),
      assets: DiscordAssets(
        largeImage: 'https://example.com/art.jpg',
        largeText: 'Some Album',
      ),
      buttons: [
        DiscordButton(
          label: 'Listen on YouTube Music',
          url: 'https://music.youtube.com/watch?v=abc',
        ),
      ],
      type: DiscordActivityType.listening,
    );

    test('carries cmd, nonce, pid and the activity', () {
      final frame = encodeSetActivityFrame(
        processId: 4242,
        activity: activity(),
        nonce: 'n1',
      );
      final decoded = _decode(frame);
      // Opcode 1 = FRAME.
      expect(decoded.opcode, 1);
      final json = jsonDecode(decoded.payload) as Map<String, dynamic>;
      expect(json['cmd'], 'SET_ACTIVITY');
      expect(json['nonce'], 'n1');
      final args = json['args'] as Map<String, dynamic>;
      expect(args['pid'], 4242);
      final act = args['activity'] as Map<String, dynamic>;
      expect(act['type'], 2, reason: 'listening is type 2');
      // `name` is the status line Discord renders. Left out, the live
      // client answers with `"name":"NixieTube"` — the application name —
      // which is what made a user-selectable status line look stuck on
      // the app name. It has to go on the wire.
      expect(act['name'], 'PROBE STATUS LINE');
      expect(act['details'], 'Song Title');
      expect(act['state'], 'Some Artist');
      expect(act['timestamps'], {'start': 100, 'end': 300});
      expect(act['assets'], {
        'large_image': 'https://example.com/art.jpg',
        'large_text': 'Some Album',
      });
      expect(act['buttons'], [
        {
          'label': 'Listen on YouTube Music',
          'url': 'https://music.youtube.com/watch?v=abc',
        },
      ]);
    });

    test('a null activity clears the presence', () {
      final frame = encodeSetActivityFrame(
        processId: 1,
        activity: null,
        nonce: 'n',
      );
      final args = (jsonDecode(_decode(frame).payload) as Map)['args'] as Map;
      expect(args['activity'], isNull);
      expect(args['pid'], 1);
    });

    test('activity types map to the documented wire values', () {
      expect(DiscordActivityType.playing.value, 0);
      expect(DiscordActivityType.listening.value, 2);
      expect(DiscordActivityType.watching.value, 3);
      expect(DiscordActivityType.competing.value, 5);
    });
  });

  group('activity field limits', () {
    test('details and state clip at 128 characters', () {
      final act = DiscordActivity(details: 'd' * 300, state: 's' * 300);
      expect(act.details!.length, 128);
      expect(act.state!.length, 128);
      expect(
        DiscordActivity(details: 'x' * 300).toJson()['details'],
        'x' * 128,
      );
    });

    test('blank text is left out rather than sent empty', () {
      final act = DiscordActivity(details: '   ', state: '');
      expect(act.details, isNull);
      expect(act.state, isNull);
      expect(act.toJson().containsKey('details'), isFalse);
    });

    test('at most two buttons are sent', () {
      final act = DiscordActivity(
        buttons: [
          for (var i = 0; i < 5; i++)
            DiscordButton(label: 'b$i', url: 'https://example.com/$i'),
        ],
      );
      expect(act.buttons, hasLength(2));
      expect(act.toJson()['buttons'], hasLength(2));
    });

    test('button label clips at 32 and url at 512', () {
      final button = DiscordButton(
        label: 'l' * 100,
        url: 'https://example.com/${'u' * 800}',
      );
      expect(button.label.length, 32);
      expect(button.url.length, 512);
    });

    test('an all-empty assets block is omitted', () {
      expect(DiscordActivity().toJson().containsKey('assets'), isFalse);
      expect(
        DiscordActivity(assets: const DiscordAssets())
            .toJson()
            .containsKey('assets'),
        isFalse,
      );
      expect(
        DiscordActivity(assets: const DiscordAssets(largeText: 'x'))
            .toJson()['assets'],
        {'large_text': 'x'},
      );
    });
  });

  group('socket discovery', () {
    test('probes the documented directories, each with indices 0..9', () {
      final paths = DiscordIpcClient.defaultSocketPaths({
        'XDG_RUNTIME_DIR': '/run/user/1000',
        'TMPDIR': '/tmp-custom',
        'TMP': '/tmp-tmp',
        'TEMP': '/tmp-temp',
      });
      expect(paths.first, '/run/user/1000/discord-ipc-0');
      expect(paths[9], '/run/user/1000/discord-ipc-9');
      expect(paths[10], '/tmp-custom/discord-ipc-0');
      // The documented fallback is last.
      expect(paths.last, '/tmp/discord-ipc-9');
      expect(paths, hasLength(5 * 10));
    });

    test('empty and unset directories are skipped', () {
      final paths = DiscordIpcClient.defaultSocketPaths({
        'XDG_RUNTIME_DIR': '',
        'TMPDIR': '/only',
      });
      expect(paths, hasLength(2 * 10));
      expect(paths.first, '/only/discord-ipc-0');
      expect(paths.last, '/tmp/discord-ipc-9');
    });

    test('/tmp is always the final fallback', () {
      expect(
        DiscordIpcClient.defaultSocketPaths({}).last,
        '/tmp/discord-ipc-9',
      );
    });
  });

  group('connect failures', () {
    test('no reachable socket reports Discord is not running', () async {
      final client = DiscordIpcClient(
        socketPaths: ['/nonexistent/discord-ipc-0'],
      );
      await client.initialize('123');
      await expectLater(
        client.connect(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no Discord IPC socket'),
          ),
        ),
      );
      expect(client.isConnected, isFalse);
      await client.disconnect();
    });

    test('connect without an application id fails fast', () async {
      final client = DiscordIpcClient(socketPaths: []);
      await expectLater(client.connect(), throwsA(isA<StateError>()));
    });

    test('pushing without a link is refused', () async {
      final client = DiscordIpcClient(socketPaths: []);
      await client.initialize('123');
      expect(
        () => client.setActivity(DiscordActivity(details: 'x')),
        throwsA(isA<StateError>()),
      );
      // Clearing without a link is a no-op, not a crash.
      await client.clearActivity();
    });
  });
}
