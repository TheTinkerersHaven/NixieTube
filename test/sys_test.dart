// SysConfig + GoogleOAuth tests: properties round-trip, PKCE vectors
// (RFC 7636), token refresh flow with scripted HTTP.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/google_oauth.dart';
import 'package:nixietube/sys/sys_config.dart';

import 'mock_dio.dart';

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

    test('readProperties decodes \\uXXXX Java escapes', () async {
      final dir = await Directory.systemTemp.createTemp('nt-props-unicode');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/auth.properties');
      // Java Properties escapes = as \u003d, exactly as Kotlin writes it.
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

  group('PKCE', () {
    test('RFC 7636 challenge vector', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        codeChallenge(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('verifier and state are url-safe', () {
      final v = newCodeVerifier();
      final s = newOAuthState();
      expect(v.length, greaterThan(40));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v), isTrue);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s), isTrue);
    });
  });

  group('GoogleOAuth tokens', () {
    test('valid session without refresh when fresh', () async {
      final dir = await Directory.systemTemp.createTemp('nt-oauth-test');
      addTearDown(() => dir.delete(recursive: true));
      var calls = 0;
      final client = mockDio((options) async {
        calls++;
        return (200, '{}');
      });
      final config = SysConfig(configPath: '${dir.path}/config.properties');
      config.set('google.clientId', 'id');
      config.set('google.clientSecret', 'secret');
      final oauth = GoogleOAuth(
        config: config,
        dio: client,
        storePath: '${dir.path}/oauth.properties',
      );
      addTearDown(oauth.close);
      expect(oauth.savedClient(), ('id', 'secret'));
      // Seed fresh tokens directly through the file format.
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      await File('${dir.path}/oauth.properties').writeAsString(
        'client_id=id\naccess_token=AAA\nrefresh_token=RRR\n'
        'expires_at=$future\n',
      );
      final session = await oauth.validSession();
      expect(session?.accessToken, 'AAA');
      expect(calls, 0);
      expect(await oauth.accessToken(), 'AAA');
    });

    test('expired token refreshes and preserves refresh token', () async {
      final dir = await Directory.systemTemp.createTemp('nt-oauth-refresh');
      addTearDown(() => dir.delete(recursive: true));
      final client = mockDio((options) async {
        return (200, jsonEncode({'access_token': 'NEW', 'expires_in': 3600}));
      });
      final config = SysConfig(configPath: '${dir.path}/config.properties');
      config.set('google.clientId', 'id');
      config.set('google.clientSecret', 'secret');
      final oauth = GoogleOAuth(
        config: config,
        dio: client,
        storePath: '${dir.path}/oauth.properties',
      );
      addTearDown(oauth.close);
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 10;
      await File('${dir.path}/oauth.properties').writeAsString(
        'client_id=id\naccess_token=OLD\nrefresh_token=RRR\n'
        'expires_at=$past\n',
      );
      final session = await oauth.validSession();
      expect(session?.accessToken, 'NEW');
      // Refresh token preserved and persisted.
      final again = await oauth.validSession();
      expect(again?.accessToken, 'NEW');
    });

    test('logout deletes the store', () async {
      final dir = await Directory.systemTemp.createTemp('nt-oauth-logout');
      addTearDown(() => dir.delete(recursive: true));
      final config = SysConfig(configPath: '${dir.path}/config.properties');
      final oauth = GoogleOAuth(
        config: config,
        storePath: '${dir.path}/oauth.properties',
      );
      addTearDown(oauth.close);
      await File('${dir.path}/oauth.properties')
          .writeAsString('client_id=id\naccess_token=AAA\n');
      oauth.logout();
      expect(File('${dir.path}/oauth.properties').existsSync(), isFalse);
      expect(await oauth.validSession(), isNull);
    });
  });
}
