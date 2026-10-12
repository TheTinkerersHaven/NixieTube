// Regression test for the OAuth loopback callback.
//
// The user approves on Google and is redirected to the
// loopback server a moment later — well after the ~1s
// within which the old poll (`server.first.timeout(...)`)
// closed the server. That made Google's redirect fail to
// connect ("connection failed to the callback server").
// The consent redirect must be received even when it is
// delayed, and the exchanged token must be persisted.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/google_oauth.dart';

import 'mock_dio.dart';

void main() {
  test('loginBrowser keeps the callback server open for a delayed redirect',
      () async {
    final dir = Directory.systemTemp.createTempSync('nixietube-oauth-');
    final storePath = '${dir.path}/oauth.properties';
    // Longer than the ~1s after which the old poll gave up.
    const redirectDelay = Duration(milliseconds: 1500);
    Future<void>? redirect;
    try {
      // Fake token endpoint: any POST returns a valid token set,
      // so no real network call is made during the exchange.
      final client = mockDio((options) async => (
            200,
            jsonEncode({
              'access_token': 'test-access-token',
              'refresh_token': 'test-refresh-token',
              'expires_in': 3600,
            }),
          ));
      final oauth = GoogleOAuth(dio: client, storePath: storePath);

      final ok = await oauth.loginBrowser(
        'test-client-id',
        'test-client-secret',
        (url) async {
          final auth = Uri.parse(url);
          final redirectUri = Uri.parse(auth.queryParameters['redirect_uri']!);
          final state = auth.queryParameters['state']!;
          // The consent page is opened; the redirect arrives in
          // the background, independently of this call returning.
          redirect = () async {
            await Future<void>.delayed(redirectDelay);
            try {
              final browser = HttpClient();
              try {
                final target = redirectUri.replace(queryParameters: {
                  'code': 'auth-code',
                  'state': state,
                });
                final req = await browser.getUrl(target);
                final resp = await req.close();
                await resp.transform(utf8.decoder).join();
              } finally {
                browser.close();
              }
            } catch (_) {
              // Under the bug the server is already closed and the
              // connection is refused; ignore it here.
            }
          }();
        },
      );

      expect(
        ok,
        isTrue,
        reason:
            'a redirect arriving after ${redirectDelay.inMilliseconds}ms must be received',
      );
      expect(
        File(storePath).existsSync(),
        isTrue,
        reason: 'the exchanged token must be persisted',
      );
      expect(
        File(storePath).readAsStringSync().contains(
              'access_token=test-access-token',
            ),
        isTrue,
      );
    } finally {
      // Drain the background redirect so no timer is left pending
      // (it is still waiting when the login fails under the bug).
      final pending = redirect;
      if (pending != null) await pending;
      dir.deleteSync(recursive: true);
    }
  });
}
