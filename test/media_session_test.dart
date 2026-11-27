// The OS media session (phones): the player is mirrored into the
// notification, and requests that come back from the OS are forwarded to
// the player. No platform is touched here — the mapping is pure and the
// handler only reads/writes a [PlayerController].

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_controller.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/core/innertube/stream_resolver.dart'
    show ResolvedStream;
import 'package:nixietube/sys/media_session.dart';

import 'fakes.dart';

const _track = Track(
  videoId: 'v1',
  title: 'Song One',
  artists: [ArtistRef('Artist A'), ArtistRef('Artist B')],
  album: AlbumRef('Album One'),
  durationSec: 200,
);

PlayerState _state({
  Track? track = _track,
  bool playing = true,
  bool loading = false,
  bool stopped = false,
  String? error,
  int positionMs = 0,
  int durationMs = 200000,
  List<Track> queue = const [_track],
  int index = 0,
  bool shuffle = false,
  RepeatMode repeat = RepeatMode.off,
  bool autoplay = true,
}) => PlayerState(
  current: track,
  playing: playing,
  loading: loading,
  stopped: stopped,
  error: error,
  positionMs: positionMs,
  durationMs: durationMs,
  queue: queue,
  index: index,
  shuffle: shuffle,
  repeat: repeat,
  autoplay: autoplay,
);

void main() {
  group('mediaItemFor', () {
    test('carries the identity the notification and Auto show', () {
      final item = mediaItemFor(_track, 0);
      expect(item.id, 'v1');
      expect(item.title, 'Song One');
      expect(item.artist, 'Artist A, Artist B');
      expect(item.album, 'Album One');
      // No length known yet: the seek bar is hidden rather than wrong.
      expect(item.duration, isNull);
    });

    test('prefers the player-reported duration', () {
      expect(
        mediaItemFor(_track, 200000).duration,
        const Duration(seconds: 200),
      );
    });

    test('only sends http(s) covers, and the square one when present', () {
      final noArt = mediaItemFor(const Track(videoId: 'v2', title: 'Plain'), 0);
      expect(noArt.artUri, isNull);

      final withArt = mediaItemFor(
        const Track(
          videoId: 'v3',
          title: 'Covered',
          thumbnails: [
            Thumbnail('https://img.example/max.jpg', width: 1280, height: 720),
          ],
        ),
        0,
      );
      expect(withArt.artUri?.scheme, 'https');
    });
  });

  group('processingStateOf', () {
    test('no track or an explicit stop reads idle', () {
      expect(processingStateOf(_state(track: null)), AudioProcessingState.idle);
      expect(
        processingStateOf(_state(stopped: true)),
        AudioProcessingState.idle,
      );
    });

    test('resolving the stream reads buffering, a failure error', () {
      expect(
        processingStateOf(_state(loading: true)),
        AudioProcessingState.buffering,
      );
      expect(
        processingStateOf(_state(error: 'no stream')),
        AudioProcessingState.error,
      );
    });

    test('playing and paused both read ready', () {
      expect(processingStateOf(_state()), AudioProcessingState.ready);
      expect(
        processingStateOf(_state(playing: false)),
        AudioProcessingState.ready,
      );
    });
  });

  group('canMoveBy', () {
    test('the head of the queue has no previous', () {
      final s = _state(index: 0);
      expect(canMoveBy(s, -1), isFalse);
      expect(canMoveBy(s, 1), isTrue);
    });

    test('the tail has no next unless something can follow', () {
      final single = _state();
      expect(canMoveBy(single, 1), isTrue); // autoplay
      expect(canMoveBy(_state(autoplay: false), 1), isFalse);
      expect(
        canMoveBy(_state(autoplay: false, repeat: RepeatMode.all), 1),
        isTrue,
      );
    });

    test('nothing to move in an empty queue', () {
      final s = _state(track: null, queue: const [], index: -1);
      expect(canMoveBy(s, -1), isFalse);
      expect(canMoveBy(s, 1), isFalse);
    });
  });

  group('mediaControlsFor', () {
    test('play/pause flips with the player, and there is no stop button', () {
      // One queued track: no previous, and next only because autoplay
      // can continue past the queue.
      expect(mediaControlsFor(_state()), [
        MediaControl.pause,
        MediaControl.skipToNext,
      ]);
      expect(mediaControlsFor(_state(playing: false)), [
        MediaControl.play,
        MediaControl.skipToNext,
      ]);
    });

    test('a single-track queue has no transport arrows', () {
      expect(mediaControlsFor(_state(autoplay: false)), [MediaControl.pause]);
    });

    test('a connected rating adds a like button, hidden when anonymous', () {
      final anonymous = mediaControlsFor(_state());
      expect(anonymous.any((c) => c.action == MediaAction.custom), isFalse);

      final liked = mediaControlsFor(_state(), canRate: true);
      final like = liked.firstWhere((c) => c.action == MediaAction.custom);
      expect(like.customAction?.name, likeActionName);
      expect(like.label, 'Like');

      final alreadyLiked = mediaControlsFor(
        _state(track: _track.copyWith(rating: RatingStatus.like)),
        canRate: true,
      );
      final unlike = alreadyLiked.firstWhere(
        (c) => c.action == MediaAction.custom,
      );
      expect(unlike.label, 'Unlike');
    });
  });

  group('playbackStateFor', () {
    test('advertises a seek bar only when the length is known', () {
      final known = playbackStateFor(_state());
      expect(known.systemActions, contains(MediaAction.seek));
      expect(known.queueIndex, 0);

      final unknown = playbackStateFor(_state(durationMs: 0));
      expect(unknown.systemActions, isNot(contains(MediaAction.seekForward)));
    });

    test('the compact view shows at most three actions', () {
      final controls = mediaControlsFor(_state(), canRate: true);
      final compact = playbackStateFor(
        _state(),
        canRate: true,
      ).androidCompactActionIndices!;
      expect(compact.length, lessThanOrEqualTo(3));
      for (final i in compact) {
        expect(i, lessThan(controls.length));
      }
    });

    test('always reports the player position', () {
      final state = playbackStateFor(_state(positionMs: 30000));
      expect(state.updatePosition, const Duration(seconds: 30));
      // A caller can pin it, but the default is the real position: zero
      // would make the platform project the seek bar from the start.
      final pinned = playbackStateFor(
        _state(positionMs: 30000),
        positionOverride: const Duration(seconds: 5),
      );
      expect(pinned.updatePosition, const Duration(seconds: 5));
    });

    test('repeat and shuffle reach the session', () {
      final s = _state(repeat: RepeatMode.one, shuffle: true);
      final state = playbackStateFor(s);
      expect(state.repeatMode, AudioServiceRepeatMode.one);
      expect(state.shuffleMode, AudioServiceShuffleMode.all);
      expect(
        playbackStateFor(_state()).repeatMode,
        AudioServiceRepeatMode.none,
      );
    });
  });

  group('repeatModeOf', () {
    test('maps every session mode onto the player', () {
      expect(repeatModeOf(AudioServiceRepeatMode.none), RepeatMode.off);
      expect(repeatModeOf(AudioServiceRepeatMode.one), RepeatMode.one);
      expect(repeatModeOf(AudioServiceRepeatMode.all), RepeatMode.all);
      expect(repeatModeOf(AudioServiceRepeatMode.group), RepeatMode.all);
    });
  });

  group('positionDrifted', () {
    test('a tick that advances as the OS already projected is not drift', () {
      expect(
        positionDrifted(
          sent: const Duration(seconds: 30),
          elapsed: const Duration(milliseconds: 500),
          live: const Duration(milliseconds: 30500),
          playing: true,
        ),
        isFalse,
      );
    });

    test('a seek is drift, whichever way it goes', () {
      expect(
        positionDrifted(
          sent: const Duration(seconds: 30),
          elapsed: const Duration(milliseconds: 500),
          live: const Duration(seconds: 10),
          playing: true,
        ),
        isTrue,
      );
      expect(
        positionDrifted(
          sent: const Duration(seconds: 10),
          elapsed: const Duration(milliseconds: 500),
          live: const Duration(seconds: 120),
          playing: true,
        ),
        isTrue,
      );
    });

    test('a paused session projects nothing, so any move is drift', () {
      expect(
        positionDrifted(
          sent: const Duration(seconds: 30),
          elapsed: const Duration(seconds: 5),
          live: const Duration(seconds: 30),
          playing: false,
        ),
        isFalse,
      );
      expect(
        positionDrifted(
          sent: const Duration(seconds: 30),
          elapsed: const Duration(seconds: 5),
          live: const Duration(seconds: 5),
          playing: false,
        ),
        isTrue,
      );
    });
  });

  group('PlaybackAudioHandler', () {
    late Directory dir;
    late PlayerController player;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('nt-media-test');
      player = PlayerController(
        engine: FakeEngine(),
        tube: FakeTube(),
        resolveStream: (id) async =>
            ResolvedStream(url: 'https://x/$id', bitrate: 1),
        configDirPath: dir.path,
      );
    });

    tearDown(() async {
      player.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('mirrors the player into the session', () async {
      final handler = PlaybackAudioHandler(player);
      addTearDown(handler.disconnect);
      handler.connect();

      player.playTracks(const [
        _track,
        Track(videoId: 'v2', title: 'Song Two', durationSec: 100),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(handler.mediaItem.value?.title, 'Song One');
      expect(handler.queue.value.map((i) => i.title), ['Song One', 'Song Two']);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.queueIndex, 0);

      player.pause();
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);
    });

    test('a seek re-sends the position the notification projects', () async {
      final handler = PlaybackAudioHandler(player);
      addTearDown(handler.disconnect);
      handler.connect();

      player.playTracks(const [_track]);
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.updatePosition, Duration.zero);

      // Nothing in the state signature changes on a seek, so an emission
      // here only happens because the position left the window the last
      // one implies. Without it the OS keeps projecting the old
      // position and the notification's bar never goes back.
      player.seekTo(90000);
      await Future<void>.delayed(Duration.zero);
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 90),
      );

      // Settle the state the first poll reports, then watch a window
      // covering one more poll: a tick that only advances the way the OS
      // already assumes must not reach the session.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final emissions = <PlaybackState>[];
      final sub = handler.playbackState.skip(1).listen(emissions.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(emissions, isEmpty);
    });

    test('a request from the OS drives the player', () async {
      final handler = PlaybackAudioHandler(player);
      addTearDown(handler.disconnect);
      handler.connect();

      player.playTracks(const [
        _track,
        Track(videoId: 'v2', title: 'Song Two', durationSec: 100),
      ]);
      await Future<void>.delayed(Duration.zero);

      await handler.skipToNext();
      await Future<void>.delayed(Duration.zero);
      expect(player.state.current?.videoId, 'v2');
      expect(handler.mediaItem.value?.id, 'v2');

      await handler.pause();
      expect(player.state.playing, isFalse);

      await handler.play();
      expect(player.state.playing, isTrue);

      await handler.seek(const Duration(seconds: 42));
      expect(player.state.positionMs, 42000);

      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(player.state.repeat, RepeatMode.all);

      await handler.stop();
      expect(player.state.stopped, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    });

    test(
      'closeForGood stops playback and takes the notification down',
      () async {
        final handler = PlaybackAudioHandler(player);
        addTearDown(handler.disconnect);
        handler.connect();

        player.playTracks(const [_track]);
        await Future<void>.delayed(Duration.zero);
        expect(handler.playbackState.value.playing, isTrue);

        // The app was closed: the notification must end like a fully
        // closed app's — gone, with playback stopped.
        await handler.closeForGood();
        await Future<void>.delayed(Duration.zero);
        expect(player.state.stopped, isTrue);
        expect(handler.mediaItem.value, isNull);
        expect(handler.queue.value, isEmpty);
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.idle,
        );
      },
    );

    test('onTaskRemoved closes the app for good', () async {
      final handler = PlaybackAudioHandler(player);
      addTearDown(handler.disconnect);
      handler.connect();

      player.playTracks(const [_track]);
      await Future<void>.delayed(Duration.zero);

      await handler.onTaskRemoved();
      await Future<void>.delayed(Duration.zero);
      expect(player.state.stopped, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    });

    test('closeBackgroundAudioForGood drives the live handler', () async {
      final handler = PlaybackAudioHandler(player);
      backgroundAudio = handler;
      addTearDown(() {
        backgroundAudio = null;
        return handler.disconnect();
      });
      handler.connect();

      player.playTracks(const [_track]);
      await Future<void>.delayed(Duration.zero);

      await closeBackgroundAudioForGood();
      await Future<void>.delayed(Duration.zero);
      expect(player.state.stopped, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    });

    test('the notification like button rates the current track', () async {
      final handler = PlaybackAudioHandler(player);
      addTearDown(handler.disconnect);
      final calls = <(String, RatingStatus)>[];
      handler.connectRatings(
        canRate: () => true,
        onLike: (id, rating) async => calls.add((id, rating)),
      );
      handler.connect();

      player.playTracks(const [
        _track,
        Track(videoId: 'v2', title: 'Song Two', durationSec: 100),
      ]);
      await Future<void>.delayed(Duration.zero);

      await handler.customAction(likeActionName);
      expect(calls, [('v1', RatingStatus.like)]);

      // The button is a toggle: tapping it again on a liked track
      // clears the like.
      player.updateTrackRating('v1', RatingStatus.like);
      await Future<void>.delayed(Duration.zero);
      await handler.customAction(likeActionName);
      expect(calls.last, ('v1', RatingStatus.indifferent));
    });
  });
}
