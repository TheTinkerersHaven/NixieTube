import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/browser_cookies.dart';

void main() {
  group('isYouTubeDomain', () {
    test('matches YouTube session domains', () {
      for (final d in [
        'youtube.com',
        '.youtube.com',
        'www.youtube.com',
        'music.youtube.com',
        '.music.youtube.com',
      ]) {
        expect(isYouTubeDomain(d), isTrue, reason: d);
      }
    });

    test('rejects other domains', () {
      for (final d in [
        '',
        'google.com',
        'youtu.be',
        'youtube.com.evil.com',
        'notyoutube.com',
      ]) {
        expect(isYouTubeDomain(d), isFalse, reason: d);
      }
    });
  });

  group('buildYouTubeHeader', () {
    test('keeps only YouTube cookies, joined as a Cookie header', () {
      final header = BrowserCookies.buildYouTubeHeader([
        {
          'name': 'SAPISID',
          'value': 'abc',
          'domain': '.youtube.com',
        },
        {
          'name': 'PREF',
          'value': 'f4=400',
          'domain': 'www.youtube.com',
        },
        {
          'name': 'SID',
          'value': 'zzz',
          'domain': 'google.com',
        },
      ]);
      expect(header, 'SAPISID=abc; PREF=f4=400');
    });

    test('null when nothing YouTube-shaped survives', () {
      expect(BrowserCookies.buildYouTubeHeader([]), isNull);
      expect(
        BrowserCookies.buildYouTubeHeader([
          {'name': 'SID', 'value': 'x', 'domain': 'google.com'},
        ]),
        isNull,
      );
      // Empty values and malformed entries are dropped.
      expect(
        BrowserCookies.buildYouTubeHeader([
          {'name': 'SAPISID', 'value': '', 'domain': '.youtube.com'},
          {'name': '', 'value': 'x', 'domain': '.youtube.com'},
          'not-a-map',
        ]),
        isNull,
      );
    });
  });

  group('detectProfiles', () {
    test('finds installed browsers with a Cookies store', () {
      final root = Directory.systemTemp.createTempSync('nt-prof');
      addTearDown(() => root.deleteSync(recursive: true));
      final binDir = Directory('${root.path}/bin')..createSync();
      final chromeHome = Directory('${root.path}/home')..createSync();
      File('${binDir.path}/google-chrome')
          .writeAsStringSync('#!/bin/sh\n');
      final cookies =
          '${chromeHome.path}/.config/google-chrome/Default/Cookies';
      File(cookies)
        ..createSync(recursive: true)
        ..writeAsStringSync('store');

      final profiles = BrowserCookies.detectProfiles(
        home: chromeHome.path,
        pathDirs: [binDir.path],
      );
      expect(profiles, hasLength(1));
      expect(profiles.first.label, 'Chrome');
      expect(profiles.first.cookiesDb, cookies);
      expect(File(profiles.first.binary).existsSync(), isTrue);
    });

    test('empty without a browser binary or store', () {
      final root = Directory.systemTemp.createTempSync('nt-prof2');
      addTearDown(() => root.deleteSync(recursive: true));
      // Binary present but no Cookies store.
      final binDir = Directory('${root.path}/bin')..createSync();
      File('${binDir.path}/google-chrome').writeAsStringSync('');
      final emptyHome = Directory('${root.path}/empty-home')
        ..createSync();
      expect(
        BrowserCookies.detectProfiles(
          home: emptyHome.path,
          pathDirs: [binDir.path],
        ),
        isEmpty,
      );
      // Store present but no binary.
      final home = Directory('${root.path}/home')..createSync();
      File('${home.path}/.config/google-chrome/Default/Cookies')
          .createSync(recursive: true);
      expect(
        BrowserCookies.detectProfiles(
          home: home.path,
          pathDirs: ['${root.path}/nowhere'],
        ),
        isEmpty,
      );
    });
  });

  group('importYouTubeCookie', () {
    test('degrades to null when the store is missing', () async {
      final root = Directory.systemTemp.createTempSync('nt-imp');
      addTearDown(() => root.deleteSync(recursive: true));
      final binDir = Directory('${root.path}/bin')..createSync();
      final binary = '${binDir.path}/google-chrome';
      File(binary).writeAsStringSync('');
      final profile = BrowserProfile(
        label: 'Chrome',
        binary: binary,
        cookiesDb: '${root.path}/missing/Cookies',
      );
      await expectLater(
        BrowserCookies.importYouTubeCookie(profile),
        completion(isNull),
      );
    });
  });
}
