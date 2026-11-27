// The two Playback sliders: the cache size cap and how many queue rows
// are downloaded ahead. Both are plain settings, so a sandboxed
// SysConfig over a temp directory is enough — no audio, no network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/sys_config.dart';

void main() {
  late Directory dir;
  late SysConfig config;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt-audio-settings');
    config = SysConfig(configPath: '${dir.path}/config.properties');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  group('cache size', () {
    test('defaults to half a gigabyte, a slider step', () {
      expect(config.audioCacheMb, defaultAudioCacheMb);
      expect(audioCacheMbSteps, contains(config.audioCacheMb));
    });

    test('a picked step survives a reload', () {
      config.audioCacheMb = 2048;

      final reloaded = SysConfig(
        configPath: '${dir.path}/config.properties',
      );
      expect(reloaded.audioCacheMb, 2048);
    });

    test('a value between steps snaps to the nearest one', () {
      config.set('audio.cacheMb', '700');

      expect(config.audioCacheMb, 512);
    });

    test('junk falls back to the default', () {
      config.set('audio.cacheMb', 'big');

      expect(config.audioCacheMb, defaultAudioCacheMb);
    });
  });

  group('download ahead', () {
    test('defaults to three rows', () {
      expect(config.audioDownloadAhead, defaultAudioDownloadAhead);
    });

    test('a picked count survives a reload', () {
      config.audioDownloadAhead = 7;

      final reloaded = SysConfig(
        configPath: '${dir.path}/config.properties',
      );
      expect(reloaded.audioDownloadAhead, 7);
    });

    test('is held between one row and the slider ceiling', () {
      config.audioDownloadAhead = 0;
      expect(config.audioDownloadAhead, 1);

      config.audioDownloadAhead = 99;
      expect(config.audioDownloadAhead, maxAudioDownloadAhead);

      config.set('audio.downloadAhead', 'lots');
      expect(config.audioDownloadAhead, defaultAudioDownloadAhead);
    });
  });
}
