// MPRIS D-Bus media-key integration, ported from Kotlin `Mpris.kt`
// (Linux only). Exposes the player as `org.mpris.MediaPlayer2.nixietube`
// with diffed PropertiesChanged updates and Seeked signals.

import 'dart:async';
import 'dart:io' show File, FileMode;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../core/artwork/artwork_store.dart';
import '../core/models/models.dart';
import '../core/player/player_controller.dart';
import '../core/player/player_state.dart';

const mprisBusName = 'org.mpris.MediaPlayer2.nixietube';
const mprisObjectPath = '/org/mpris/MediaPlayer2';

/// MPRIS loop status for a repeat mode.
String loopStatusOf(RepeatMode repeat) => switch (repeat) {
  RepeatMode.off => 'None',
  RepeatMode.one => 'Track',
  RepeatMode.all => 'Playlist',
};

/// Maps an MPRIS LoopStatus back onto repeat modes; anything
/// unrecognized means off.
RepeatMode repeatOfLoopStatus(String status) => switch (status) {
  'Track' => RepeatMode.one,
  'Playlist' => RepeatMode.all,
  _ => RepeatMode.off,
};

/// Object path identifying a track (`/nixietube/track/<hex video id>`).
String trackObjectPath(String videoId) {
  final hex = videoId.codeUnits
      .map((c) => c.toRadixString(16).padLeft(2, '0'))
      .join();
  return '/nixietube/track/$hex';
}

/// MPRIS metadata dict for [track] (durations in microseconds).
Map<String, DBusValue> mprisMetadata(
  Track track,
  int durationUs,
  String? artUrl,
) {
  return {
    'mpris:trackid': DBusObjectPath(trackObjectPath(track.videoId)),
    'mpris:length': DBusInt64(durationUs),
    'xesam:title': DBusString(track.title),
    'xesam:artist': DBusArray(
      DBusSignature('s'),
      track.artists.map((a) => DBusString(a.name)),
    ),
    'xesam:album': DBusString(track.album?.name ?? ''),
    if (artUrl != null && artUrl.isNotEmpty) 'mpris:artUrl': DBusString(artUrl),
    'xesam:url': DBusString(
      'https://music.youtube.com/watch?v=${track.videoId}',
    ),
  };
}

/// MPRIS PlaybackStatus for a snapshot: no track or an explicit
/// stop reads Stopped, otherwise Playing/Paused.
String playbackStatusOf(PlayerState s) {
  if (s.current == null || s.stopped) return 'Stopped';
  return s.playing ? 'Playing' : 'Paused';
}

class _MprisObject extends DBusObject {
  _MprisObject({
    required PlayerController controller,
    required ArtworkStore artworkStore,
    required void Function() onQuit,
  }) : super(DBusObjectPath(mprisObjectPath)) {
    _controller = controller;
    _art = artworkStore;
    _onQuit = onQuit;
  }

  late final PlayerController _controller;
  late final ArtworkStore _art;
  late final void Function() _onQuit;

  PlayerState get _s => _controller.state;

  /// Local file:// art when already rendered, else the remote URL.
  /// Fallback sync version for compatibility - checks file existence synchronously.
  String? _artUrl(Track track) {
    final remote = track.displayArtwork;
    if (remote == null || remote.isEmpty) return null;
    try {
      final path = _art.tileFilePath(remote);
      final file = File(path);
      if (file.existsSync() && file.lengthSync() > 0) {
        return 'file://$path';
      }
    } catch (_) {}
    return remote;
  }

  Map<String, DBusValue> _rootProps() => {
    'Identity': const DBusString('NixieTube'),
    'DesktopEntry': const DBusString('nixietube'),
    'SupportedUriSchemes': DBusArray(DBusSignature('s'), [
      const DBusString('https'),
    ]),
    'SupportedMimeTypes': DBusArray(DBusSignature('s'), [
      const DBusString('audio/webm'),
      const DBusString('audio/mpeg'),
      const DBusString('audio/mp4'),
    ]),
    'CanQuit': const DBusBoolean(true),
    'CanRaise': const DBusBoolean(false),
    'HasTrackList': const DBusBoolean(false),
    'CanSetFullscreen': const DBusBoolean(false),
  };

  Map<String, DBusValue> _playerProps() {
    final s = _s;
    final track = s.current;
    return {
      'PlaybackStatus': DBusString(playbackStatusOf(s)),
      'LoopStatus': DBusString(loopStatusOf(s.repeat)),
      'Rate': const DBusDouble(1.0),
      'Shuffle': DBusBoolean(s.shuffle),
      'Metadata': DBusDict.stringVariant(
        track == null
            ? <String, DBusValue>{}
            : mprisMetadata(track, s.durationMs * 1000, _artUrl(track)),
      ),
      'Volume': DBusDouble(s.volume / 100.0),
      'Position': DBusInt64(s.positionMs * 1000),
      'MinimumRate': const DBusDouble(1.0),
      'MaximumRate': const DBusDouble(1.0),
      'CanGoNext': DBusBoolean(
        track != null &&
            ((s.index + 1 >= 0 && s.index + 1 < s.queue.length) || s.autoplay),
      ),
      'CanGoPrevious': DBusBoolean(track != null),
      'CanPlay': const DBusBoolean(true),
      'CanPause': const DBusBoolean(true),
      'CanSeek': const DBusBoolean(true),
      'CanControl': const DBusBoolean(true),
    };
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    try {
      if (call.interface == 'org.mpris.MediaPlayer2') {
        switch (call.name) {
          case 'Raise':
            return DBusMethodSuccessResponse();
          case 'Quit':
            _onQuit();
            return DBusMethodSuccessResponse();
        }
      }
      if (call.interface == 'org.mpris.MediaPlayer2.Player') {
        final s = _s;
        switch (call.name) {
          case 'Next':
            _controller.next();
            return DBusMethodSuccessResponse();
          case 'Previous':
            _controller.previous();
            return DBusMethodSuccessResponse();
          case 'Pause':
            if (s.playing) _controller.togglePlayPause();
            return DBusMethodSuccessResponse();
          case 'PlayPause':
            _controller.togglePlayPause();
            return DBusMethodSuccessResponse();
          case 'Play':
            _controller.play();
            return DBusMethodSuccessResponse();
          case 'Stop':
            _controller.stop();
            return DBusMethodSuccessResponse();
          case 'Seek':
            final offsetUs = call.values.isNotEmpty
                ? call.values[0].asInt64()
                : 0;
            final targetMs = s.positionMs + (offsetUs ~/ 1000);
            if (s.durationMs > 0 && targetMs >= s.durationMs) {
              _controller.next();
            } else {
              _controller.seekTo(targetMs.clamp(0, 1 << 62));
            }
            return DBusMethodSuccessResponse();
          case 'SetPosition':
            if (call.values.length >= 2) {
              final path = call.values[0].asString();
              final posUs = call.values[1].asInt64();
              final track = s.current;
              if (track != null &&
                  path == trackObjectPath(track.videoId) &&
                  posUs >= 0 &&
                  (s.durationMs <= 0 || posUs <= s.durationMs * 1000)) {
                _controller.seekTo(posUs ~/ 1000);
              }
            }
            return DBusMethodSuccessResponse();
          case 'OpenUri':
            return DBusMethodSuccessResponse();
        }
      }
      return await super.handleMethodCall(call);
    } catch (_) {
      return DBusMethodErrorResponse.failed();
    }
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final props = interface == 'org.mpris.MediaPlayer2'
        ? _rootProps()
        : interface == 'org.mpris.MediaPlayer2.Player'
        ? _playerProps()
        : null;
    final value = props?[name];
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusMethodSuccessResponse([DBusVariant(value)]);
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    try {
      if (interface == 'org.mpris.MediaPlayer2.Player') {
        switch (name) {
          case 'Volume':
            _controller.setVolume((value.asDouble() * 100).round());
            return DBusMethodSuccessResponse();
          case 'LoopStatus':
            _controller.setRepeat(repeatOfLoopStatus(value.asString()));
            return DBusMethodSuccessResponse();
          case 'Shuffle':
            _controller.setShuffle(value.asBoolean());
            return DBusMethodSuccessResponse();
        }
      }
      return DBusMethodErrorResponse.unknownProperty();
    } catch (_) {
      return DBusMethodErrorResponse.failed();
    }
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == 'org.mpris.MediaPlayer2') {
      return DBusMethodSuccessResponse([DBusDict.stringVariant(_rootProps())]);
    }
    if (interface == 'org.mpris.MediaPlayer2.Player') {
      return DBusMethodSuccessResponse([
        DBusDict.stringVariant(_playerProps()),
      ]);
    }
    return super.getAllProperties(interface);
  }

  @override
  List<DBusIntrospectInterface> introspect() {
    DBusIntrospectMethod method(
      String name, [
      List<String> inSig = const [],
      List<String> outSig = const [],
    ]) => DBusIntrospectMethod(
      name,
      args: [
        for (final s in inSig)
          DBusIntrospectArgument(DBusSignature(s), DBusArgumentDirection.in_),
        for (final s in outSig)
          DBusIntrospectArgument(DBusSignature(s), DBusArgumentDirection.out),
      ],
      annotations: const [],
    );
    DBusIntrospectProperty prop(
      String name,
      String type, [
      DBusPropertyAccess access = DBusPropertyAccess.read,
    ]) => DBusIntrospectProperty(name, DBusSignature(type), access: access);
    return [
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2',
        methods: [method('Raise'), method('Quit')],
        signals: const [],
        properties: [
          prop('Identity', 's'),
          prop('DesktopEntry', 's'),
          prop('SupportedUriSchemes', 'as'),
          prop('SupportedMimeTypes', 'as'),
          prop('CanQuit', 'b'),
          prop('CanRaise', 'b'),
          prop('HasTrackList', 'b'),
          prop('CanSetFullscreen', 'b'),
        ],
      ),
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2.Player',
        methods: [
          method('Next'),
          method('Previous'),
          method('Pause'),
          method('PlayPause'),
          method('Play'),
          method('Stop'),
          method('Seek', ['x']),
          method('SetPosition', ['o', 'x']),
          method('OpenUri', ['s']),
        ],
        signals: [
          DBusIntrospectSignal(
            'Seeked',
            args: [
              DBusIntrospectArgument(
                DBusSignature('x'),
                DBusArgumentDirection.out,
              ),
            ],
            annotations: const [],
          ),
        ],
        properties: [
          prop('PlaybackStatus', 's'),
          prop('LoopStatus', 's', DBusPropertyAccess.readwrite),
          prop('Rate', 'd'),
          prop('Shuffle', 'b', DBusPropertyAccess.readwrite),
          prop('Metadata', 'a{sv}'),
          prop('Volume', 'd', DBusPropertyAccess.readwrite),
          prop('Position', 'x'),
          prop('MinimumRate', 'd'),
          prop('MaximumRate', 'd'),
          prop('CanGoNext', 'b'),
          prop('CanGoPrevious', 'b'),
          prop('CanPlay', 'b'),
          prop('CanPause', 'b'),
          prop('CanSeek', 'b'),
          prop('CanControl', 'b'),
        ],
      ),
    ];
  }
}

void _mprisLog(String line) {
  try {
    final file = File('/tmp/nixietube-mpris.log');
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $line\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// Builds the session-bus client for one connect attempt. Injectable so
/// tests exercise the retry loop without touching a live session bus.
typedef MprisClientFactory = DBusClient Function();

/// How often the service re-attempts a connect that failed, and pings a
/// connection it owns. It never gives up on its own: the session bus can
/// come up late, and another instance can release the name at any time.
const mprisRetryInterval = Duration(seconds: 10);

/// Liveness ping budget. A session bus that went away leaves our client
/// dead without telling us, so a ping that does not come back in time
/// counts as a lost connection.
const _mprisPingTimeout = Duration(seconds: 5);

/// MPRIS D-Bus service: exports the player, diffs property updates and
/// emits Seeked signals. Linux only.
class MprisService extends ChangeNotifier {
  MprisService({
    required PlayerController controller,
    ArtworkStore? artworkStore,
    MprisClientFactory? clientFactory,
    this.retryInterval = mprisRetryInterval,
  }) {
    _controller = controller;
    _artworkStore = artworkStore;
    _newClient = clientFactory ?? DBusClient.session;
    _sub = _controller.states.listen(_onState);
  }

  late final PlayerController _controller;
  ArtworkStore? _artworkStore;
  late final MprisClientFactory _newClient;
  late final StreamSubscription<PlayerState> _sub;

  /// How often a failed connect is re-attempted and an owned connection
  /// is pinged, while the service is enabled.
  final Duration retryInterval;

  DBusClient? _client;
  _MprisObject? _object;

  /// Artwork store created on demand when none was injected; kept for the
  /// service's lifetime so a series of failed connects doesn't leak one
  /// Dio per attempt.
  ArtworkStore? _inlineArt;
  bool _enabled = true;
  bool _active = false;
  String? _lastError;
  Timer? _retryTimer;
  bool _busy = false;
  int _lastSeekEpoch = -1;
  int _lastPositionEmitMs = 0;
  Map<String, String> _lastProps = {};
  int _connectGen = 0;

  bool get enabled => _enabled;
  bool get active => _active;
  String? get lastError => _lastError;

  /// Toggles the service, stopping first when switched off.
  void setEnabled(bool value) {
    _enabled = value;
    if (!value) {
      unawaited(stop());
    }
    notifyListeners();
  }

  /// Artwork source for MPRIS track art URLs, settable after
  /// construction.
  void setArtworkStore(ArtworkStore art) {
    _artworkStore = art;
  }

  /// Starts the service: claims the bus name now, then keeps retrying on
  /// a timer while enabled — a connect that fails (no session bus yet, or
  /// another instance still owning the name) is re-attempted, and a
  /// connection that drops later is claimed again. Returns whether the
  /// name is ours at this moment.
  Future<bool> start() async {
    final gen = ++_connectGen;
    final active = await _connect(gen);
    if (_enabled && gen == _connectGen) _armRetry();
    return active;
  }

  /// Stops the service, releasing the bus name and ending the retries.
  Future<void> stop() async {
    _connectGen++;
    _cancelRetry();
    _active = false;
    notifyListeners();
    try {
      await _client?.close();
    } catch (_) {}
    _client = null;
    _object = null;
    try {
      _inlineArt?.close();
    } catch (_) {}
    _inlineArt = null;
  }

  /// Keeps the service reachable while enabled.
  void _armRetry() {
    _retryTimer ??= Timer.periodic(
      retryInterval,
      (_) => unawaited(_retryTick()),
    );
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _retryTick() async {
    if (!_enabled) {
      _cancelRetry();
      return;
    }
    if (_busy) return;
    final client = _client;
    if (client == null) {
      await _connect(_connectGen);
      return;
    }
    _busy = true;
    var alive = true;
    try {
      await client.ping().timeout(_mprisPingTimeout);
    } catch (e) {
      alive = false;
      _mprisLog('liveness ping failed: $e');
    } finally {
      _busy = false;
    }
    if (!alive) {
      await _dropConnection();
      await _connect(_connectGen);
    }
  }

  /// One connect attempt: exports the player object and requests the
  /// MPRIS name. Returns whether the name is now ours; failures surface
  /// through [lastError] for the next retry tick to pick up.
  Future<bool> _connect(int gen) async {
    if (_busy) return false;
    _busy = true;
    DBusClient? client;
    try {
      if (gen != _connectGen || !_enabled) return false;
      client = _newClient();
      final artStore = _artworkStore ?? (_inlineArt ??= ArtworkStore());
      final object = _MprisObject(
        controller: _controller,
        artworkStore: artStore,
        onQuit: _quitRequested,
      );
      await client.registerObject(object);
      // doNotQueue turns a name already held by another instance into an
      // immediate `exists` reply instead of queueing, so the retry timer
      // stays in charge of when to try again.
      final reply = await client.requestName(
        mprisBusName,
        flags: const {DBusRequestNameFlag.doNotQueue},
      );
      if (reply == DBusRequestNameReply.primaryOwner ||
          reply == DBusRequestNameReply.alreadyOwner) {
        if (gen != _connectGen || !_enabled) {
          await client.close();
          return false;
        }
        _client = client;
        _object = object;
        _active = true;
        _lastError = null;
        _lastProps = {};
        notifyListeners();
        unawaited(_pushFullState());
        return true;
      }
      await client.close();
      client = null;
      // Another live connection owns the MPRIS name. This cannot succeed
      // until it exits, so report why and let the timer look again rather
      // than hammering the bus.
      if (reply == DBusRequestNameReply.exists ||
          reply == DBusRequestNameReply.inQueue) {
        _fail('another NixieTube instance owns the MPRIS name');
        return false;
      }
      throw StateError('name not acquired: $reply');
    } catch (e) {
      try {
        await client?.close();
      } catch (_) {}
      _mprisLog('connect failed: $e');
      _fail('$e');
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Records a failed connect, notifying only when the reason actually
  /// changes: the retry timer would otherwise rebuild the UI every tick.
  void _fail(String reason) {
    final changed = _active || _lastError != reason;
    _active = false;
    _lastError = reason;
    if (changed) notifyListeners();
  }

  /// Marks the owned connection dead, so the retry timer claims the name
  /// again on its next tick.
  Future<void> _dropConnection() async {
    final client = _client;
    _client = null;
    _object = null;
    _active = false;
    _lastProps = {};
    _lastError = 'session bus connection lost';
    notifyListeners();
    try {
      await client?.close();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(stop());
    _sub.cancel();
    super.dispose();
  }

  void _quitRequested() {
    // Closed by the app shell via onQuit callback wiring.
    _quitController?.call();
  }

  void Function()? _quitController;

  /// Sets the Quit handler (window close).
  set onQuit(void Function() value) => _quitController = value;

  void _onState(PlayerState s) {
    if (!_active) return;
    final epoch = s.seekEpoch;
    if (epoch != _lastSeekEpoch) {
      _lastSeekEpoch = epoch;
      final object = _object;
      if (object != null) {
        unawaited(
          object.emitSignal('org.mpris.MediaPlayer2.Player', 'Seeked', [
            DBusInt64(s.positionMs * 1000),
          ]),
        );
      }
    }
    unawaited(_pushDiff(s));
  }

  Future<void> _pushFullState() async {
    final object = _object;
    if (object == null) return;
    final props = _snapshot();
    _lastProps = props;
    try {
      await object.emitPropertiesChanged(
        'org.mpris.MediaPlayer2.Player',
        changedProperties: _decodeProps(props),
      );
    } catch (e) {
      _mprisLog('full push failed: $e');
    }
  }

  Future<void> _pushDiff(PlayerState s) async {
    final object = _object;
    if (object == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final playing = s.playing;
    final snapshot = _snapshot();
    final changed = <String, DBusValue>{};
    for (final entry in _decodeProps(snapshot).entries) {
      if (_lastProps[entry.key] != _encode(entry.value)) {
        if (entry.key == 'Position' &&
            playing &&
            now - _lastPositionEmitMs < 2000) {
          continue;
        }
        changed[entry.key] = entry.value;
      }
    }
    if (changed.isEmpty) return;
    if (changed.containsKey('Position')) _lastPositionEmitMs = now;
    for (final entry in changed.entries) {
      _lastProps[entry.key] = _encode(entry.value);
    }
    try {
      await object.emitPropertiesChanged(
        'org.mpris.MediaPlayer2.Player',
        changedProperties: changed,
      );
    } catch (e) {
      _mprisLog('diff push failed: $e');
    }
  }

  Map<String, String> _snapshot() {
    final s = _controller.state;
    final track = s.current;
    return {
      'PlaybackStatus': playbackStatusOf(s),
      'LoopStatus': loopStatusOf(s.repeat),
      'Shuffle': '${s.shuffle}',
      'Volume': (s.volume / 100.0).toStringAsFixed(3),
      'Position': '${s.positionMs * 1000}',
      'Metadata': track == null
          ? ''
          : '${track.videoId}:${track.title}:${track.artistNames()}:${track.album?.name ?? ''}:${s.durationMs}',
      'CanGoNext':
          '${track != null && ((s.index + 1 >= 0 && s.index + 1 < s.queue.length) || s.autoplay)}',
      'CanGoPrevious': '${track != null}',
    };
  }

  Map<String, DBusValue> _decodeProps(Map<String, String> snapshot) {
    final s = _controller.state;
    final track = s.current;
    return {
      'PlaybackStatus': DBusString(snapshot['PlaybackStatus']!),
      'LoopStatus': DBusString(snapshot['LoopStatus']!),
      'Shuffle': DBusBoolean(snapshot['Shuffle'] == 'true'),
      'Volume': DBusDouble(double.tryParse(snapshot['Volume']!) ?? 1.0),
      'Position': DBusInt64(int.tryParse(snapshot['Position']!) ?? 0),
      'Metadata': DBusDict.stringVariant(
        track == null
            ? <String, DBusValue>{}
            : mprisMetadata(
                track,
                s.durationMs * 1000,
                _object?._artUrl(track),
              ),
      ),
      'CanGoNext': DBusBoolean(snapshot['CanGoNext'] == 'true'),
      'CanGoPrevious': DBusBoolean(snapshot['CanGoPrevious'] == 'true'),
    };
  }

  String _encode(DBusValue value) {
    if (value is DBusString) return 's:${value.value}';
    if (value is DBusBoolean) return 'b:${value.value}';
    if (value is DBusDouble) return 'd:${value.value}';
    if (value is DBusInt64) return 'x:${value.value}';
    if (value is DBusDict) {
      final parts = <String>[];
      value.children.forEach((k, v) {
        parts.add('${(k as DBusString).value}=${_encode(v)}');
      });
      return 'm:${parts.join(',')}';
    }
    return value.toString();
  }
}
