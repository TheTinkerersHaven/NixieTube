// SysConfig tests: properties round-trip and escape handling.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/sys_config.dart';

void main() {
  group('SysConfig', () {
    test('round-trips values with defaults', () async {
      final dir = await Directory.systemTemp.createTemp('nt-sysconfig-test');
      addTearDown(() => dir.delete(recursive: true));
      final config = SysConfig(configPath: '${dir.path}/config.properties');
      expect(config.mprisEnabled, isTrue);
      expect(config.discordEnabled, isFalse);
      expect(config.discordAppIdOrDefault, defaultDiscordAppId);
      expect(config.reportPlayback, isFalse);
      expect(config.lyricsSource, 'lrclib');
      config.lyricsSource = 'ytmusic';
      config.set('discord.appId', '123');
      config.setBool('mpris.enabled', false);
      final again = SysConfig(configPath: '${dir.path}/config.properties');
      expect(again.discordAppIdOrDefault, '123');
      expect(again.mprisEnabled, isFalse);
      expect(again.lyricsSource, 'ytmusic');
    });

    test('a11y underline + remembered system color round-trip', () async {
      final dir = await Directory.systemTemp.createTemp('nt-sysconfig-a11y');
      addTearDown(() => dir.delete(recursive: true));
      final config = SysConfig(configPath: '${dir.path}/config.properties');
      expect(config.underlineLinks, isFalse);
      expect(config.themeSystemPrimary, isNull);
      config.underlineLinks = true;
      config.themeSystemPrimary = 0xff2196f3;
      final again = SysConfig(configPath: '${dir.path}/config.properties');
      expect(again.underlineLinks, isTrue);
      expect(again.themeSystemPrimary, 0xff2196f3);
      again.themeSystemPrimary = null;
      expect(
        SysConfig(configPath: '${dir.path}/config.properties')
            .themeSystemPrimary,
        isNull,
      );
    });

    test('readProperties decodes \\uXXXX Java escapes', () async {
      final dir = await Directory.systemTemp.createTemp('nt-props-unicode');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/auth.properties');
      // Java Properties escapes = as \u003d.
      await file.writeAsString(
        'cookie=LOGIN_INFO=abc\\u003d123;sid=x\n'
        'sapisidHash=1_abc\n'
        'sessionToken=QUZZT1\\u003dtoken\\u003dmore\n',
      );
      final props = readProperties(file);
      expect(props['cookie'], 'LOGIN_INFO=abc=123;sid=x');
      expect(props['sapisidHash'], '1_abc');
      expect(props['sessionToken'], 'QUZZT1=token=more');
    });

    test('readProperties repairs double-escaped \\uXXXX corruption', () async {
      final dir = await Directory.systemTemp.createTemp('nt-props-corrupt');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/auth.properties');
      // Earlier versions re-escaped the backslash in \u003d on
      // save, producing \\u003d in the file. The repair collapses
      // it back so the token decodes to the original = padding.
      await file.writeAsString(
        'sessionToken=QUZZT1\\\\u003dtoken\\\\u003dmore\n',
      );
      final props = readProperties(file);
      expect(props['sessionToken'], 'QUZZT1=token=more');
    });

    test('readProperties handles backslash escapes', () async {
      final dir = await Directory.systemTemp.createTemp('nt-props-esc');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/test.properties');
      await file.writeAsString('a=hello\\nworld\\t!\\\\done\\u003dend');
      final props = readProperties(file);
      expect(props['a'], 'hello\nworld\t!\\done=end');
    });
  });
}
