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
        {'name': 'SAPISID', 'value': 'abc', 'domain': '.youtube.com'},
        {'name': 'PREF', 'value': 'f4=400', 'domain': 'www.youtube.com'},
        {'name': 'SID', 'value': 'zzz', 'domain': 'google.com'},
      ]);
      expect(header, 'SAPISID=abc; PREF=f4=400');
    });

    test('collapses duplicate cookie names to the first value', () {
      final header = BrowserCookies.buildYouTubeHeader([
        {'name': 'SID', 'value': 'first', 'domain': '.youtube.com'},
        {'name': 'SID', 'value': 'second', 'domain': 'music.youtube.com'},
        {'name': 'SAPISID', 'value': 'abc', 'domain': '.youtube.com'},
      ]);
      expect(header, 'SID=first; SAPISID=abc');
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

  group('hasSignedInSession', () {
    Map<String, String> cookie(
      String name,
      String value, [
      String domain = '.youtube.com',
    ]) => {'name': name, 'value': value, 'domain': domain};

    test('true with a SAPISID value on a YouTube domain', () {
      expect(
        BrowserCookies.hasSignedInSession([
          cookie('VISITOR_INFO1_LIVE', 'xyz'),
          cookie('SAPISID', 'abc'),
        ]),
        isTrue,
      );
      expect(
        BrowserCookies.hasSignedInSession([
          cookie('__Secure-3PAPISID', 'abc', '.music.youtube.com'),
        ]),
        isTrue,
      );
    });

    test('false for anonymous, empty or foreign cookies', () {
      expect(BrowserCookies.hasSignedInSession([]), isFalse);
      expect(
        BrowserCookies.hasSignedInSession([
          cookie('VISITOR_INFO1_LIVE', 'xyz'),
          cookie('PREF', 'f4'),
        ]),
        isFalse,
      );
      expect(
        BrowserCookies.hasSignedInSession([
          cookie('SAPISID', '', '.youtube.com'),
        ]),
        isFalse,
      );
      expect(
        BrowserCookies.hasSignedInSession([
          cookie('SAPISID', 'abc', 'google.com'),
        ]),
        isFalse,
      );
      expect(BrowserCookies.hasSignedInSession(['junk']), isFalse);
    });
  });

}
