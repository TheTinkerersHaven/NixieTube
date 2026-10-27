// Discord Rich Presence over the local IPC socket — a pure-Dart client,
// replacing the flutter_rust_bridge-backed `flutter_discord_rpc`.
//
// Protocol reference: https://docs.discord.com/developers/topics/rpc
//   - Transport: a unix socket at `<runtime-dir>/discord-ipc-{0..9}`.
//     The client resolves the directory in this order: `XDG_RUNTIME_DIR`,
//     `TMPDIR`, `TMP`, `TEMP`, then `/tmp`.
//   - Frame: `opcode:uint32LE | length:uint32LE | payload:utf8 JSON`.
//   - Opcodes: 0 HANDSHAKE, 1 FRAME, 2 CLOSE, 3 PING, 4 PONG.
//   - Handshake payload (opcode 0): `{"v":1,"client_id":"<app id>"}`.
//     A READY dispatch answers it; an ERROR event reports rejection.
//   - Commands (opcode 1) look like
//     `{"cmd":"SET_ACTIVITY","nonce":"…","args":{"pid":N,"activity":{…}}}`.
//
// Owning the socket (rather than a native library) means no hidden global
// state: there is no one-shot "already initialized" singleton, changing
// the application id takes effect immediately, and a failed connect can
// never leave a half-built client behind.

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show InternetAddress, InternetAddressType, Platform, Socket, pid;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Trims [text] to [limit] characters; blank becomes null so the field is
/// left out of the payload entirely.
String? _clipText(String? text, int limit) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > limit ? trimmed.substring(0, limit) : trimmed;
}

/// Wire opcodes (RPC over IPC).
const int _opHandshake = 0;
const int _opFrame = 1;
const int _opClose = 2;
const int _opPing = 3;
const int _opPong = 4;

/// How many `discord-ipc-N` sockets to probe (N is 0..9).
const int _maxSocketIndex = 10;

/// Upper bound on one frame's payload. Discord's frames are small; this
/// only guards a corrupt length field from forcing a huge allocation.
const int _maxFrameBytes = 8 << 20;

/// How long the socket open and the handshake may take before the attempt
/// is abandoned (the presence is best-effort; the caller retries).
const Duration _connectTimeout = Duration(seconds: 5);

// ---------- Activity payload ----------

/// Activity types Discord accepts over RPC: playing, listening, watching
/// and competing (streaming and custom are not allowed for `SET_ACTIVITY`).
enum DiscordActivityType {
  playing(0),
  listening(2),
  watching(3),
  competing(5);

  const DiscordActivityType(this.value);

  /// Wire value.
  final int value;
}

/// Unix-second timestamps; both set renders a progress bar.
class DiscordTimestamps {
  const DiscordTimestamps({this.start, this.end});

  final int? start;
  final int? end;

  Map<String, dynamic> toJson() => {
    if (start != null) 'start': start,
    if (end != null) 'end': end,
  };
}

/// Activity images and hover text. [largeImage] accepts either an asset
/// key registered in the developer portal or an external image URL.
class DiscordAssets {
  const DiscordAssets({this.largeImage, this.largeText});

  final String? largeImage;
  final String? largeText;

  bool get isEmpty => largeImage == null && largeText == null;

  Map<String, dynamic> toJson() => {
    if (largeImage != null) 'large_image': largeImage,
    if (largeText != null) 'large_text': largeText,
  };
}

/// A custom button under the presence (max 2; label 1–32, url 1–512).
class DiscordButton {
  DiscordButton({required String label, required String url})
    : label = _clipText(label, _labelLimit) ?? '',
      url = url.length > _urlLimit ? url.substring(0, _urlLimit) : url;

  static const _labelLimit = 32;
  static const _urlLimit = 512;

  final String label;
  final String url;

  Map<String, dynamic> toJson() => {'label': label, 'url': url};
}

const int _textLimit = 128;

/// The presence we push, mirroring the documented activity object. Only
/// the fields NixieTube uses are modelled.
class DiscordActivity {
  DiscordActivity({
    this.name,
    String? details,
    String? state,
    this.timestamps,
    this.assets,
    List<DiscordButton>? buttons,
    this.type = DiscordActivityType.listening,
  }) : details = _clipText(details, _textLimit),
       state = _clipText(state, _textLimit),
       // Discord renders at most two buttons.
       buttons = buttons == null || buttons.isEmpty
           ? const []
           : List<DiscordButton>.unmodifiable(buttons.take(2));

  /// The activity's headline: the text Discord puts on the status line,
  /// above [details].
  ///
  /// When this is absent Discord fills it in with the *application* name
  /// instead — verified on the live client, which answers a `SET_ACTIVITY`
  /// sent without one with `"name":"NixieTube"`. So a client that lets the
  /// user choose that line has to send it; omit it and the app name shows
  /// no matter what the other fields say.
  final String? name;

  /// What the player is doing (second line).
  final String? details;

  /// Party status / custom status (third line).
  final String? state;

  final DiscordTimestamps? timestamps;
  final DiscordAssets? assets;
  final List<DiscordButton> buttons;
  final DiscordActivityType type;

  Map<String, dynamic> toJson() => {
    'type': type.value,
    if (name != null) 'name': name,
    if (details != null) 'details': details,
    if (state != null) 'state': state,
    if (timestamps != null) 'timestamps': timestamps!.toJson(),
    if (assets != null && !assets!.isEmpty) 'assets': assets!.toJson(),
    if (buttons.isNotEmpty) 'buttons': [for (final b in buttons) b.toJson()],
  };
}

// ---------- Framing ----------

/// Encodes one wire frame: little-endian opcode and payload length,
/// followed by the UTF-8 payload.
Uint8List encodeRpcFrame(int opcode, String payload) {
  final body = utf8.encode(payload);
  final out = Uint8List(8 + body.length);
  ByteData.view(out.buffer).setUint32(0, opcode, Endian.little);
  ByteData.view(out.buffer).setUint32(4, body.length, Endian.little);
  out.setRange(8, out.length, body);
  return out;
}

/// The handshake frame (opcode 0): `{"v":1,"client_id":"…"}`.
Uint8List encodeHandshakeFrame(String clientId) =>
    encodeRpcFrame(_opHandshake, jsonEncode({'v': 1, 'client_id': clientId}));

/// A `SET_ACTIVITY` frame (opcode 1). A null [activity] clears the
/// presence, which is how Discord expects a teardown to be expressed.
Uint8List encodeSetActivityFrame({
  required int processId,
  required DiscordActivity? activity,
  required String nonce,
}) => encodeRpcFrame(
  _opFrame,
  jsonEncode({
    'cmd': 'SET_ACTIVITY',
    'nonce': nonce,
    'args': {'pid': processId, 'activity': activity?.toJson()},
  }),
);

/// Raised when the peer sends a frame we cannot make sense of.
class RpcProtocolException implements Exception {
  const RpcProtocolException(this.message);

  final String message;

  @override
  String toString() => 'RpcProtocolException: $message';
}

/// Reassembles frames from a byte stream: the socket delivers arbitrary
/// chunk boundaries, so frames are buffered until complete.
class RpcFrameReader {
  final List<int> _pending = <int>[];

  /// Appends [chunk] and returns every frame that is now complete.
  ///
  /// Throws [RpcProtocolException] on a frame length that cannot be
  /// legitimate, which means the stream is no longer trustworthy.
  List<({int opcode, String payload})> add(List<int> chunk) {
    _pending.addAll(chunk);
    final frames = <({int opcode, String payload})>[];
    while (_pending.length >= 8) {
      final opcode = _u32(_pending, 0);
      final length = _u32(_pending, 4);
      if (length < 0 || length > _maxFrameBytes) {
        throw RpcProtocolException('implausible frame length $length');
      }
      if (_pending.length < 8 + length) break;
      final body = _pending.sublist(8, 8 + length);
      _pending.removeRange(0, 8 + length);
      frames.add((
        opcode: opcode,
        payload: utf8.decode(body, allowMalformed: true),
      ));
    }
    return frames;
  }

  static int _u32(List<int> bytes, int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);
}

// ---------- Client ----------

/// The RPC operations the presence drives. Injectable so tests exercise
/// the retry loop without a live Discord client.
abstract interface class DiscordRpc {
  /// Whether the IPC link is up. Only meaningful once [initialize] has
  /// succeeded.
  bool get isConnected;

  Future<void> initialize(String appId);
  Future<void> connect();
  Future<void> setActivity(DiscordActivity activity);
  Future<void> clearActivity();
  Future<void> disconnect();
}

/// One IPC session, holding the state that belongs to that socket alone:
/// the frame reassembler, the handshake completer and the subscription
/// that feeds them.
///
/// Scoping that state per connection is what makes a teardown safe.
/// Discord answers a CLOSE with a CLOSE frame of its own, so a retiring
/// socket keeps talking for a moment after we stop listening to it, while
/// the next session has already started. With one shared reader and
/// completer those trailing frames complete — or fail — the *new*
/// handshake, which is how a dead session's error gets reported as a fresh
/// connect failure. A session only ever touches the client while it is
/// still the current one.
class _IpcSession {
  _IpcSession(this.socket);

  final Socket socket;
  final RpcFrameReader reader = RpcFrameReader();
  final Completer<void> handshake = Completer<void>();
  // Cancelled by _retire() when the session is torn down, not in the
  // function that creates it — so the rule stays off by design here.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? subscription;
}

/// Pure-Dart Discord IPC client.
///
/// The lifecycle mirrors what a presence needs and nothing more: the
/// socket is opened and handshaked in [connect], and [disconnect] closes
/// it. Reconnection is the caller's business (NixieTube runs a periodic
/// retry), so this class never retries on its own.
class DiscordIpcClient implements DiscordRpc {
  DiscordIpcClient({List<String>? socketPaths})
    : _socketPaths = socketPaths ?? defaultSocketPaths();

  /// Candidate socket paths, in the order the protocol defines.
  final List<String> _socketPaths;

  _IpcSession? _session;
  bool _connected = false;
  Future<void>? _connectInFlight;
  String? _clientId;
  int _nonce = 0;

  @override
  bool get isConnected => _connected && (_session != null);

  /// Records the application id. Nothing else happens here: unlike the
  /// native client there is no global to stand up, so a bad id surfaces
  /// as an ERROR on the handshake instead.
  @override
  Future<void> initialize(String appId) async {
    _clientId = appId.trim();
  }

  /// Opens the first reachable socket and handshakes on it.
  ///
  /// Throws when no socket is reachable (Discord not running) or the
  /// handshake is rejected (unknown application id), so the caller can
  /// report the real cause.
  @override
  Future<void> connect() async {
    if (_clientId == null || _clientId!.isEmpty) {
      throw StateError('no Discord application id configured');
    }
    // Serialize: a second caller while one is in flight awaits the
    // same attempt instead of opening a parallel socket (the
    // superseded session would otherwise leave its handshake
    // completer dangling for the full timeout).
    if (_connectInFlight != null) return _connectInFlight!;
    final future = _doConnect();
    _connectInFlight = future;
    try {
      await future;
    } finally {
      _connectInFlight = null;
    }
  }

  Future<void> _doConnect() async {
    await disconnect();
    final session = _IpcSession(await _openSocket());
    _session = session;
    session.subscription = session.socket.listen(
      (chunk) => _onData(session, chunk),
      onDone: () => _onClosed(session),
      onError: (Object _) => _onClosed(session),
      cancelOnError: true,
    );
    try {
      session.socket.add(encodeHandshakeFrame(_clientId!));
      await session.handshake.future.timeout(
        _connectTimeout,
        onTimeout: () => throw TimeoutException('no READY from Discord'),
      );
      _connected = true;
    } catch (_) {
      await _retire(session);
      rethrow;
    }
  }

  @override
  Future<void> setActivity(DiscordActivity activity) async {
    if (!isConnected) throw StateError('Discord IPC link is not up');
    await _send(
      encodeSetActivityFrame(
        processId: pid,
        activity: activity,
        nonce: _nextNonce(),
      ),
    );
  }

  /// Clears the presence (`SET_ACTIVITY` with a null activity).
  @override
  Future<void> clearActivity() async {
    if (!isConnected) return;
    await _send(
      encodeSetActivityFrame(
        processId: pid,
        activity: null,
        nonce: _nextNonce(),
      ),
    );
  }

  /// Closes the session, telling Discord first when the link is up.
  ///
  /// The teardown is the CLOSE *opcode*, which the RPC docs define as the
  /// way either side ends a session; it answers with a clean
  /// `1000 client disconnect`. A `{"cmd":"CLOSE"}` command frame is not a
  /// substitute: every command frame must carry a nonce, so Discord
  /// rejects that one with `4000 Payload requires a nonce`.
  @override
  Future<void> disconnect() async {
    if (_connected) {
      try {
        await _write(_opClose, '{}');
      } catch (_) {}
    }
    _connected = false;
    final session = _session;
    _session = null;
    if (session != null) await _retire(session);
  }

  String _nextNonce() => '$pid-${_nonce++}';

  Future<void> _send(Uint8List frame) async {
    final session = _session;
    if (session == null) throw StateError('Discord IPC link is not up');
    session.socket.add(frame);
    await session.socket.flush();
  }

  Future<void> _write(int opcode, String payload) =>
      _send(encodeRpcFrame(opcode, payload));

  void _onData(_IpcSession session, List<int> chunk) {
    // A socket that has been superseded must not touch live state, even
    // if the OS still has bytes queued for it.
    if (!identical(_session, session)) return;
    List<({int opcode, String payload})> frames;
    try {
      frames = session.reader.add(chunk);
    } on RpcProtocolException {
      _onClosed(session);
      return;
    }
    for (final frame in frames) {
      switch (frame.opcode) {
        case _opFrame:
          _onPayload(session, frame.payload);
        case _opPing:
          // The server checks we are alive; echo the nonce back.
          unawaited(_write(_opPong, frame.payload).catchError((_) {}));
        case _opClose:
          _onRemoteClose(session, frame.payload);
        default:
          break;
      }
    }
  }

  /// Handles the server closing the link. Discord answers a *rejected*
  /// handshake this way — the reason arrives in the CLOSE payload as
  /// `{"code":4000,"message":"…"}` (verified against the live client),
  /// so it is read from here rather than letting the attempt run out its
  /// connect timeout with no explanation.
  void _onRemoteClose(_IpcSession session, String payload) {
    if (!identical(_session, session)) return;
    final handshake = session.handshake;
    if (!handshake.isCompleted) {
      String? reason;
      try {
        final json = jsonDecode(payload);
        if (json is Map) reason = json['message']?.toString();
      } catch (_) {}
      handshake.completeError(
        StateError(reason ?? 'Discord closed the IPC connection'),
      );
    }
    _onClosed(session);
  }

  /// Handles one FRAME payload: READY completes the handshake, ERROR
  /// fails it (and is otherwise ignored — we subscribe to no events).
  void _onPayload(_IpcSession session, String payload) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      json = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final evt = json['evt'];
    final handshake = session.handshake;
    if (evt == 'READY') {
      if (!handshake.isCompleted) handshake.complete();
      return;
    }
    if (evt == 'ERROR') {
      final data = json['data'];
      final message = data is Map
          ? (data['message'] ?? 'error ${data['code']}')
          : 'handshake rejected';
      if (!handshake.isCompleted) {
        handshake.completeError(StateError('$message'));
      }
    }
  }

  void _onClosed(_IpcSession session) {
    if (!identical(_session, session)) return;
    final wasConnected = _connected;
    _connected = false;
    _session = null;
    if (!wasConnected) {
      // The socket died before READY: fail whoever is waiting so the
      // connect attempt ends instead of hitting its timeout.
      final handshake = session.handshake;
      if (!handshake.isCompleted) {
        handshake.completeError(
          StateError('Discord closed the IPC connection'),
        );
      }
    }
    unawaited(_retire(session));
  }

  /// Tears a session down for good: stop listening first, so nothing it
  /// still has queued can be mistaken for the next session's traffic.
  Future<void> _retire(_IpcSession session) async {
    final handshake = session.handshake;
    if (!handshake.isCompleted) {
      handshake.completeError(StateError('Discord IPC link closed'));
    }
    try {
      await session.subscription?.cancel();
    } catch (_) {}
    session.subscription = null;
    try {
      await session.socket.close();
    } catch (_) {}
    try {
      await session.socket.done;
    } catch (_) {}
  }

  /// Connects to the first socket that accepts us.
  Future<Socket> _openSocket() async {
    Object? last;
    for (final path in _socketPaths) {
      try {
        return await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
          timeout: _connectTimeout,
        );
      } catch (e) {
        last = e;
      }
    }
    throw StateError(
      last == null
          ? 'no Discord IPC socket found (is Discord running?)'
          : 'no Discord IPC socket reachable: $last',
    );
  }

  /// The `discord-ipc-{0..9}` paths in the order the protocol documents:
  /// `XDG_RUNTIME_DIR`, `TMPDIR`, `TMP`, `TEMP`, then `/tmp`, each probed
  /// for every index before moving on to the next directory.
  @visibleForTesting
  static List<String> defaultSocketPaths([Map<String, String>? env]) {
    final environment = env ?? Platform.environment;
    final dirs = <String>[
      for (final key in const ['XDG_RUNTIME_DIR', 'TMPDIR', 'TMP', 'TEMP'])
        if (environment[key] case final dir? when dir.isNotEmpty) dir,
      '/tmp',
    ];
    return [
      for (final dir in dirs)
        for (var i = 0; i < _maxSocketIndex; i++) '$dir/discord-ipc-$i',
    ];
  }
}
