// Tests for the MPRIS + Discord pure builders: loop mapping, track
// paths, metadata shape, artwork rules, and presence fields.

import 'package:dbus/dbus.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/models/models.dart';
import 'package:nixietube/core/player/player_state.dart';
import 'package:nixietube/sys/discord.dart';
import 'package:nixietube/sys/mpris.dart';

const _track = Track(
  videoId: 'dQw4w9WgXcQ',
  title: 'Song Title That Is Not Too Long',
  artists: [ArtistRef('Some Artist')],
  album: AlbumRef('Some Album'),
  durationSec: 200,
  thumbnails: [Thumbnail('https://lh3.googleusercontent.com/x=w60-h60-l90-rj')],
);

PlayerState _state({bool playing = true}) => PlayerState(
      current: _track,
      playing: playing,
      positionMs: 30000,
      durationMs: 200000,
      volume: 80,
      queue: const [_track],
      index: 0,
    );

void main() {
  group('loop status', () {
    test('round-trips repeat modes', () {
      expect(loopStatusOf(RepeatMode.off), 'None');
      expect(loopStatusOf(RepeatMode.one), 'Track');
      expect(loopStatusOf(RepeatMode.all), 'Playlist');
      expect(repeatOfLoopStatus('Track'), RepeatMode.one);
      expect(repeatOfLoopStatus('Playlist'), RepeatMode.all);
      expect(repeatOfLoopStatus('None'), RepeatMode.off);
      expect(repeatOfLoopStatus('bogus'), RepeatMode.off);
    });
  });

  group('track paths', () {
    test('hex-encodes the video id', () {
      final path = trackObjectPath('AB');
      expect(path, '/nixietube/track/4142');
      expect(path.startsWith('/nixietube/track/'), isTrue);
    });
  });

  group('metadata', () {
    test('shapes the MPRIS dict', () {
      final meta = mprisMetadata(_track, 200000000, 'file:///x.png');
      expect((meta['mpris:trackid'] as DBusObjectPath).value,
          trackObjectPath('dQw4w9WgXcQ'));
      expect((meta['mpris:length'] as DBusInt64).value, 200000000);
      expect((meta['xesam:title'] as DBusString).value,
          'Song Title That Is Not Too Long');
      expect((meta['xesam:artist'] as DBusArray).children.length, 1);
      expect((meta['xesam:album'] as DBusString).value, 'Some Album');
      expect((meta['mpris:artUrl'] as DBusString).value, 'file:///x.png');
      expect((meta['xesam:url'] as DBusString).value,
          'https://music.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    test('playback status mapping', () {
      expect(playbackStatusOf(_state()), 'Playing');
      expect(playbackStatusOf(_state(playing: false)), 'Paused');
      expect(
          playbackStatusOf(const PlayerState(stopped: true)), 'Stopped');
      expect(playbackStatusOf(const PlayerState()), 'Stopped');
    });
  });

  group('discord artwork', () {
    test('only square googleusercontent upgrades', () {
      expect(
          discordArtwork('https://lh3.googleusercontent.com/a=w60-h60-l90-rj'),
          'https://lh3.googleusercontent.com/a=w540-h540-l90-rj');
      expect(
          discordArtwork(
              'https://lh3.googleusercontent.com/a=w480-h360'),
          isNull);
      expect(discordArtwork('https://i.ytimg.com/vi/x/hqdefault.jpg'),
          isNull);
      expect(discordArtwork(null), isNull);
    });
  });

  group('presence activity', () {
    test('playing presence fields', () {
      final activity = presenceActivity(_state())!;
      expect(activity.details, 'Song Title That Is Not Too Long');
      expect(activity.state, 'Some Artist');
      expect(activity.activityType, ActivityType.listening);
      expect(activity.timestamps!.end! - activity.timestamps!.start!,
          200);
      expect(activity.assets!.largeText, 'Some Album');
      expect(activity.assets!.largeImage,
          'https://lh3.googleusercontent.com/x=w540-h540-l90-rj');
      expect(activity.buttons!.single.label,
          'Listen on YouTube Music');
      expect(activity.buttons!.single.url,
          'https://music.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    test('paused state prefixes the artist', () {
      final activity = presenceActivity(_state(playing: false))!;
      expect(activity.state, '⏸ Some Artist');
      expect(activity.timestamps!.end, isNull);
    });

    test('no track yields no activity', () {
      expect(presenceActivity(const PlayerState()), isNull);
    });

    test('details truncate at 128 chars', () {
      final long = Track(
          videoId: 'v',
          title: 'x' * 200,
          artists: const [ArtistRef('A')]);
      final activity = presenceActivity(
          PlayerState(current: long, playing: true))!;
      expect(activity.details!.length, 128);
    });
  });

  group('status text keys', () {
    test('round-trips', () {
      expect(discordStatusTextFromKey('song'), DiscordStatusText.song);
      expect(
          discordStatusTextFromKey('artists'), DiscordStatusText.artists);
      expect(discordStatusTextFromKey('app'), DiscordStatusText.app);
      expect(discordStatusTextFromKey('bogus'), DiscordStatusText.app);
      expect(discordStatusTextKey(DiscordStatusText.song), 'song');
    });
  });
}
