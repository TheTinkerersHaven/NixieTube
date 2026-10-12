// Tests for the embedded-login cookie helpers: webview cookie payloads
// come in several shapes and only a signed-in session may proceed.
// Pure functions — the native window flow stays out of tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/browser_login.dart';

void main() {
  group('normalizeWebviewCookies', () {
    test('flattens domain-grouped maps', () {
      expect(
        normalizeWebviewCookies({
          '.youtube.com': {'SAPISID': 'abc', 'PREF': 'f4'},
          '.music.youtube.com': {'LOGIN_INFO': 'xyz'},
        }),
        [
          {'domain': '.youtube.com', 'name': 'SAPISID', 'value': 'abc'},
          {'domain': '.youtube.com', 'name': 'PREF', 'value': 'f4'},
          {
            'domain': '.music.youtube.com',
            'name': 'LOGIN_INFO',
            'value': 'xyz',
          },
        ],
      );
    });

    test('flattens cookie-object lists', () {
      expect(
        normalizeWebviewCookies([
          {'domain': '.youtube.com', 'name': 'SAPISID', 'value': 'abc'},
          {'domain': 'google.com', 'name': 'SID', 'value': 'z'},
        ]),
        [
          {'domain': '.youtube.com', 'name': 'SAPISID', 'value': 'abc'},
          {'domain': 'google.com', 'name': 'SID', 'value': 'z'},
        ],
      );
    });

    test('drops nameless entries, keeps empty values for the header', () {
      expect(
        normalizeWebviewCookies({
          '.youtube.com': {'': 'x', 'SAPISID': ''},
        }),
        [
          {'domain': '.youtube.com', 'name': 'SAPISID', 'value': ''},
        ],
      );
      expect(normalizeWebviewCookies(null), isEmpty);
      expect(normalizeWebviewCookies('junk'), isEmpty);
    });
  });

  group('youTubeCookieHeader', () {
    test('builds a header for signed-in sessions', () {
      expect(
        youTubeCookieHeader({
          '.youtube.com': {'SAPISID': 'abc', 'PREF': 'f4'},
        }),
        'SAPISID=abc; PREF=f4',
      );
    });

    test('null without a session, even with cookies present', () {
      expect(
        youTubeCookieHeader({
          '.youtube.com': {'PREF': 'f4', 'VISITOR_INFO1_LIVE': 'x'},
        }),
        isNull,
      );
      expect(youTubeCookieHeader({}), isNull);
    });
  });

  group('parseDocumentCookie', () {
    test('splits document.cookie pairs', () {
      expect(parseDocumentCookie('SAPISID=abc; PREF=f4; LOGIN_INFO=xyz'), [
        {'domain': '.youtube.com', 'name': 'SAPISID', 'value': 'abc'},
        {'domain': '.youtube.com', 'name': 'PREF', 'value': 'f4'},
        {'domain': '.youtube.com', 'name': 'LOGIN_INFO', 'value': 'xyz'},
      ]);
    });

    test('drops malformed segments, empty is empty', () {
      expect(parseDocumentCookie(''), isEmpty);
      expect(parseDocumentCookie('nosplit'), isEmpty);
    });

    test('feeds youTubeCookieHeader for a signed-in session', () {
      expect(
        youTubeCookieHeader(parseDocumentCookie('SAPISID=abc; PREF=f4')),
        'SAPISID=abc; PREF=f4',
      );
      expect(youTubeCookieHeader(parseDocumentCookie('PREF=f4')), isNull);
    });
  });
}
