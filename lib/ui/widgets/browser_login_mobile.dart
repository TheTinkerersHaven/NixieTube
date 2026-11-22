// In-app Google sign-in for Android.
//
// Phones have no desktop WebKit window to borrow, but Android ships a
// system WebView with a cookie store of its own. This dialog shows
// music.youtube.com in that WebView, and when the user says they are done
// it reads the store through a small platform channel — which, unlike
// `document.cookie`, includes the HttpOnly session cookies (`SAPISID`,
// `__Secure-1PSID`, …) that InnerTube authenticates with.
//
// Desktop keeps its own out-of-process window (`browser_login_dialog.dart`);
// the two share `showBrowserLoginDialog` so callers do not care which one
// runs.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../sys/browser_cookies.dart';

/// The page the user signs in on.
const loginPageUrl = 'https://music.youtube.com';

/// Channel that exposes the platform cookie store (`MainActivity.kt`).
const _cookieChannel = MethodChannel('nixietube/cookies');

/// Reads every cookie the WebView set for [url] as one header string, or
/// null when the platform has no such store (iOS, desktop, tests).
///
/// HttpOnly cookies are included: the platform reads the store directly
/// rather than going through JavaScript.
Future<String?> readSystemCookies(Uri url) async {
  try {
    return await _cookieChannel.invokeMethod<String>('getCookies', {
      'url': url.toString(),
    });
  } on MissingPluginException {
    // Not Android (or no platform view host): the caller falls back to
    // the manual paste. A real Android failure should surface as one.
    return null;
  }
}

/// The outcome of reading the cookie store behind the sign-in page.
class LoginCheck {
  const LoginCheck(this.header, this.status);

  /// The `Cookie` header when a signed-in session is present.
  final String? header;

  /// Why there is none, when [header] is null.
  final String? status;
}

/// Reads the session behind the sign-in page and turns it into a
/// `Cookie` header.
///
/// Injectable reader so the flow is testable without a WebView: failures
/// and "not signed in yet" both come back as a status instead of throwing,
/// because both are things the user fixes by finishing the login and
/// pressing the button again.
Future<LoginCheck> checkLoginCookie(
  Future<String?> Function() readCookies,
) async {
  String? raw;
  try {
    raw = await readCookies().timeout(const Duration(seconds: 10));
  } catch (_) {
    return const LoginCheck(null, 'Could not read the session — try again.');
  }
  final header = BrowserCookies.youTubeHeaderFromCookieString(raw);
  if (header != null && header.isNotEmpty) return LoginCheck(header, null);
  return const LoginCheck(
    null,
    'No signed-in YouTube session yet — finish the Google login in the '
    'page above, then press the button again.',
  );
}

/// Shows the in-app sign-in page. Returns the YouTube `Cookie` header
/// once the user confirms a session, or null on cancel/timeout.
Future<String?> showMobileBrowserLoginDialog(
  BuildContext context, {
  Future<String?> Function()? readCookies,
  Widget? page,
  Duration timeout = const Duration(minutes: 5),
}) {
  final reader =
      readCookies ?? (() => readSystemCookies(Uri.parse(loginPageUrl)));
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    // The dialog is a full-screen page: it owns its own SafeArea so the
    // WebView can draw behind the bars without the route insetting it twice.
    useSafeArea: false,
    builder: (context) => _MobileBrowserLoginDialog(
      readCookies: reader,
      page: page,
      timeout: timeout,
    ),
  );
}

class _MobileBrowserLoginDialog extends StatefulWidget {
  const _MobileBrowserLoginDialog({
    required this.readCookies,
    required this.timeout,
    this.page,
  });

  final Future<String?> Function() readCookies;
  final Duration timeout;

  /// Replaces the WebView (tests: the platform view has no host there).
  final Widget? page;

  @override
  State<_MobileBrowserLoginDialog> createState() =>
      _MobileBrowserLoginDialogState();
}

class _MobileBrowserLoginDialogState extends State<_MobileBrowserLoginDialog> {
  Timer? _timeout;
  bool _done = false;
  bool _checking = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(widget.timeout, () => _finish(null));
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _done = true;
    super.dispose();
  }

  /// Closes the dialog, answering [header] (null when the user gave up).
  Future<void> _finish(String? header) async {
    if (_done) return;
    _done = true;
    _timeout?.cancel();
    if (mounted) Navigator.of(context).pop(header);
  }

  Future<void> _check() async {
    if (_done || _checking) return;
    setState(() {
      _checking = true;
      _status = null;
    });
    final result = await checkLoginCookie(widget.readCookies);
    if (!mounted || _done) return;
    final header = result.header;
    if (header != null) {
      await _finish(header);
      return;
    }
    setState(() {
      _checking = false;
      _status = result.status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Cancel',
                  onPressed: () => unawaited(_finish(null)),
                ),
                Expanded(
                  child: Text(
                    'Log in with Google',
                    textAlign: TextAlign.center,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: widget.page ?? const _LoginWebView(url: loginPageUrl),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _status ??
                        'Sign in with your Google account, then import the '
                            'session below. It is read once, when you press '
                            'the button.',
                    style: text.bodySmall?.copyWith(
                      color: _status == null
                          ? scheme.onSurfaceVariant
                          : scheme.error,
                    ),
                  ),
                  if (_checking) ...[
                    const SizedBox(height: 12),
                    const M3ELoadingIndicator(),
                  ],
                  const SizedBox(height: 12),
                  M3EFilledButton.icon(
                    onPressed: _checking ? null : _check,
                    icon: const Icon(Icons.login_rounded),
                    label: Text(
                      _checking
                          ? 'Checking…'
                          : "I've signed in — import session",
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Google refuses to sign in from some embedded browsers.
                  // The paste flow in Settings → Account still works, so
                  // say so rather than leaving the user stuck here.
                  Text(
                    'Google may refuse to sign in from an embedded page. If '
                    'it does, sign in on a computer and paste the cookie in '
                    'Settings → Account instead.',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sign-in page itself, in the platform WebView.
class _LoginWebView extends StatefulWidget {
  const _LoginWebView({required this.url});

  final String url;

  @override
  State<_LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<_LoginWebView> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        // Google's flow hands off through intent:// and market:// links
        // when a native app claims them; inside a login page those just
        // leave the user stranded, so only http(s) navigates.
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ),
    )
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
