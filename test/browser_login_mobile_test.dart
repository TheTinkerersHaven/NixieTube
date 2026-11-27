// The phone sign-in flow: a WebView page, and a cookie read that
// includes the HttpOnly session cookies the desktop flow gets from its
// out-of-process window. No platform view is involved — the cookie reader
// is injected, which is exactly how Android hands the header over.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import 'package:nixietube/sys/browser_cookies.dart';
import 'package:nixietube/ui/widgets/browser_login_mobile.dart';

/// What Android's `CookieManager.getCookie(url)` returns for a signed-in
/// YouTube session. `SAPISID` is HttpOnly: it never appears in
/// `document.cookie`, which is why the store has to be read natively.
const _signedInCookie =
    'PREF=hl=en; VISITOR_INFO1_LIVE=abc; SAPISID=secret-sapisid; '
    '__Secure-1PSID=secret-psid; SID=secret-sid';

void main() {
  group('youTubeHeaderFromCookieString', () {
    test('no cookie means no session', () {
      expect(BrowserCookies.youTubeHeaderFromCookieString(null), isNull);
      expect(BrowserCookies.youTubeHeaderFromCookieString('   '), isNull);
    });

    test('visitor cookies alone are not a session', () {
      expect(
        BrowserCookies.youTubeHeaderFromCookieString(
          'PREF=hl=en; VISITOR_INFO1_LIVE=abc',
        ),
        isNull,
      );
    });

    test('keeps the HttpOnly session cookies and drops junk entries', () {
      final header = BrowserCookies.youTubeHeaderFromCookieString(
        _signedInCookie,
      );
      expect(header, isNotNull);
      expect(header, contains('SAPISID=secret-sapisid'));
      expect(header, contains('__Secure-1PSID=secret-psid'));
      // Anonymous cookies ride along: YouTube expects the whole jar.
      expect(header, contains('PREF=hl=en'));
      // The trailing ';' pair produced no name=value entry.
      expect(header, isNot(endsWith(';')));
    });
  });

  group('checkLoginCookie', () {
    test('a signed-in store yields the header', () async {
      final result = await checkLoginCookie(() async => _signedInCookie);
      expect(result.status, isNull);
      expect(result.header, contains('SAPISID=secret-sapisid'));
    });

    test('a store without a session explains itself', () async {
      final result = await checkLoginCookie(() async => 'PREF=hl=en');
      expect(result.header, isNull);
      expect(result.status, contains('No signed-in YouTube session'));
    });

    test('a reader that fails is a status, not a throw', () async {
      final result = await checkLoginCookie(
        () async => throw Exception('no cookie store'),
      );
      expect(result.header, isNull);
      expect(result.status, contains('Could not read'));
    });
  });

  testWidgets('the dialog answers with the header once the user confirms', (
    tester,
  ) async {
    String? answer;
    var answered = false;
    var reads = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await showMobileBrowserLoginDialog(
                  context,
                  // A placeholder page: the platform view has no host
                  // under test.
                  page: const ColoredBox(color: Colors.black),
                  readCookies: () async {
                    reads++;
                    return _signedInCookie;
                  },
                );
                answered = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Log in with Google'), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.text("I've signed in — import session")),
    );
    await tester.pumpAndSettle();

    expect(reads, 1);
    expect(answered, isTrue);
    expect(answer, contains('SAPISID=secret-sapisid'));
    // The dialog closed itself: the flow is done, not waiting on the user.
    expect(find.text('Log in with Google'), findsNothing);
  });

  testWidgets('the checking spinner stays square instead of stretching', (
    tester,
  ) async {
    // A read that never answers: the dialog holds the checking state, so
    // the spinner is on screen to be measured.
    final pending = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMobileBrowserLoginDialog(
                context,
                page: const ColoredBox(color: Colors.black),
                readCookies: () => pending.future,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.text("I've signed in — import session")),
    );
    // Bounded pumps: the spinner never stops animating, so settling here
    // would time out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final indicator = find.byType(M3ELoadingIndicator);
    expect(indicator, findsOneWidget);
    final size = tester.getSize(indicator);
    // The footer column stretches its children; the spinner must not
    // inherit that width or it renders as a full-width bar.
    expect(size.width, size.height);
    expect(size.width, lessThan(100));

    pending.complete(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a store without a session keeps the dialog open', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMobileBrowserLoginDialog(
                context,
                page: const ColoredBox(color: Colors.black),
                readCookies: () async => 'PREF=hl=en',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tapAt(
      tester.getCenter(find.text("I've signed in — import session")),
    );
    await tester.pumpAndSettle();

    // Still there, with the reason in front of the user.
    expect(find.text('Log in with Google'), findsOneWidget);
    expect(find.textContaining('No signed-in YouTube session'), findsOneWidget);

    // Closing the dialog leaves the caller with no session.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Log in with Google'), findsNothing);
  });
}
