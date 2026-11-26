// Discord Rich Presence on Android through the official Social SDK AAR:
// the presence frames ride a method channel to the Kotlin plugin, which
// binds the Discord app's AIDL RPC service. The channel is mocked here;
// what is asserted is the frame protocol and the presence logic.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/discord_sdk_mobile.dart';

const _appId = '1552404006498869318';

const _track = Track(
  videoId: 'v1',
  title: 'Song One',
  artists: [ArtistRef('Artist A')],
  album: AlbumRef('Album One'),
  durationSec: 200,
);

PlayerState _playing({bool playing = true}) => PlayerState(
  current: _track,
  playing: playing,
  positionMs: 30000,
  durationMs: 200000,
  queue: const [_track],
  index: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String, List<Map<String, dynamic>>>{};
  for (final k in const ['isInstalled', 'connect', 'sendFrame', 'disconnect']) {
    calls[k] = <Map<String, dynamic>>[];
  }

  setUp(() {
    for (final e in calls.entries) {
      e.value.clear();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('nixietube/discord_sdk'),
          (call) async {
            final args = call.arguments;
            calls[call.method]?.add(
              args is Map
                  ? Map<String, dynamic>.from(args)
                  : <String, dynamic>{},
            );
            switch (call.method) {
              case 'isInstalled':
                return true;
              case 'connect':
                return true;
              default:
                return null;
            }
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('nixietube/discord_sdk'),
          null,
        );
  });

  test('the SET_ACTIVITY frame mirrors the desktop RPC payload', () {
    final activity = presenceActivity(_playing())!;
    final frame = jsonDecode(
      setActivityFrameJson(processId: 42, activity: activity, nonce: 'n1'),
    );
    expect(frame['cmd'], 'SET_ACTIVITY');
    expect(frame['nonce'], 'n1');
    expect(frame['args']['pid'], 42);
    expect(frame['args']['activity']['details'], 'Song One');
    expect(frame['args']['activity']['type'], 2);
    // A null activity clears presence.
    final clear = jsonDecode(
      setActivityFrameJson(processId: 42, activity: null, nonce: 'n2'),
    );
    expect(clear['args']['activity'], isNull);
  });

  test('start connects with the app id and pushes the current track', () async {
    final presence = DiscordSdkPresence(appId: _appId, enabled: true);
    addTearDown(presence.dispose);
    await presence.start();
    expect(calls['isInstalled']!.length, 1);
    expect(calls['connect']!.single['appId'], _appId);
    expect(presence.status, 'connected');

    await presence.update(_playing());
    final frames = calls['sendFrame']!;
    expect(frames, hasLength(1));
    final frame = jsonDecode(frames.single['json'] as String);
    expect(frame['cmd'], 'SET_ACTIVITY');
    expect(frame['args']['activity']['details'], 'Song One');
  });

  test('no track clears the presence; pause-hide withdraws it', () async {
    final presence = DiscordSdkPresence(appId: _appId, enabled: true);
    presence.pauseHideAfter = const Duration(milliseconds: 1);
    addTearDown(presence.dispose);
    await presence.start();

    await presence.update(
      PlayerState(current: null, playing: false, queue: const [], index: -1),
    );
    var frame = jsonDecode(calls['sendFrame']!.last['json'] as String);
    expect(frame['args']['activity'], isNull);

    await presence.update(_playing(playing: false));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await presence.update(_playing(playing: false));
    frame = jsonDecode(calls['sendFrame']!.last['json'] as String);
    expect(frame['args']['activity'], isNull);
  });

  test('disabled presence sends nothing and disconnects', () async {
    final presence = DiscordSdkPresence(appId: _appId, enabled: false);
    addTearDown(presence.dispose);
    await presence.start();
    await presence.update(_playing());
    expect(calls['sendFrame'], isEmpty);
    expect(calls['connect'], isEmpty);
    expect(presence.status, 'disabled');

    presence.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls['connect'], hasLength(1));

    presence.setEnabled(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls['disconnect'], isNotEmpty);
  });

  test('a missing Discord app reports and retries, never throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('nixietube/discord_sdk'),
          (call) async {
            if (call.method == 'isInstalled') return false;
            return null;
          },
        );
    final presence = DiscordSdkPresence(
      appId: _appId,
      enabled: true,
      retryInterval: const Duration(milliseconds: 50),
    );
    addTearDown(presence.dispose);
    await presence.start();
    expect(presence.status, 'Discord app not installed');
    await presence.update(_playing());
    expect(calls['sendFrame'], isEmpty);
  });
}
