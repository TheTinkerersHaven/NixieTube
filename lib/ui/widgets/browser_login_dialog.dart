// Browser login through a separate system-WebKit window: the user
// signs into Google normally, then presses "I've signed in" and the
// fresh YouTube session is read once via JavaScript — no DevTools,
// no pasting, no background polling.
//
// Why user-triggered: Google's login flow (consent → YTM sign-in →
// email → password → 2FA → redirect chain → blank page) crashed when
// cookies were polled automatically mid-redirect. A single
// user-timed read avoids every in-flight-navigation native call.
// The vendored webview plugin (see
// packages/desktop_webview_window/VENDORED.md) additionally guards
// the native NULL-derefs behind blank-page navigations and failed
// JS evaluations.

import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../sys/browser_login.dart';

/// Injected into every new document at document-start (login redirects
/// create fresh documents, so per-document injection is what keeps the
/// button present). Shows a floating "I've signed in" button only on
/// music.youtube.com — never on accounts.google.com — and posts to
/// the 'nixietubeLogin' script-message channel when pressed. The Dart
/// side then performs the single native cookie-jar read.
///
/// No `$` interpolation inside: this is a plain (non-raw, no Flutter
/// template) string without Dart placeholders.
const _loginButtonScript = '(function(){'
    'try{'
    'if(!location.hostname||location.hostname.indexOf("music.youtube.com")<0)return;'
    'function addBtn(){'
    'if(document.getElementById("nixietube-login-check"))return;'
    'if(!document.body)return;'
    'var b=document.createElement("button");'
    'b.id="nixietube-login-check";'
    'b.textContent="I\'ve signed in \\u2014 import session";'
    'b.style.cssText="position:fixed;bottom:24px;right:24px;z-index:2147483647;'
    'padding:12px 18px;font-size:14px;font-weight:600;color:#fff;'
    'background-color:#0b57d0;border:none;border-radius:999px;cursor:pointer;'
    'box-shadow:0 2px 8px rgba(0,0,0,.4);";'
    'b.addEventListener("click",function(){'
    'b.disabled=true;b.textContent="Reading session\\u2026";'
    'try{window.webkit.messageHandlers.nixietubeLogin.postMessage("check");}'
    'catch(e){b.disabled=false;b.textContent="I\'ve signed in \\u2014 import session";}'
    '});'
    'document.body.appendChild(b);'
    '}'
    'if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",addBtn);}'
    'else{addBtn();}'
    'setInterval(addBtn,3000);'
    '}catch(e){}'
    '})();';

/// Shows the login window. Returns the YouTube `Cookie` header once the
/// user confirms sign-in and a session reads back, or null on
/// cancel/timeout/failure.
Future<String?> showBrowserLoginDialog(
  BuildContext context, {
  Duration timeout = const Duration(minutes: 5),
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _BrowserLoginWindow(timeout: timeout),
  );
}

class _BrowserLoginWindow extends StatefulWidget {
  const _BrowserLoginWindow({required this.timeout});

  final Duration timeout;

  @override
  State<_BrowserLoginWindow> createState() => _BrowserLoginWindowState();
}

class _BrowserLoginWindowState extends State<_BrowserLoginWindow> {
  Webview? _webview;  Timer? _timeoutTimer;
  bool _done = false;
  bool _closed = false;
  bool _checking = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      // Cap native calls so a missing plugin (tests) or broken install
      // can't wedge the app.
      Future<T> capped<T>(Future<T> f) =>
          f.timeout(const Duration(seconds: 10));
      final webview = await capped(WebviewWindow.create(
        configuration: const CreateConfiguration(
          title: 'Log in with Google',
          windowWidth: 1000,
          windowHeight: 700,
          // No Flutter title bar: that spawns a second engine (Impeller)
          // which fights the Skia main app over EGL. System
          // decorations instead (see VENDORED.md).
          titleBarHeight: 0,
        ),
      ));
      if (!mounted || _done) {
        _safeClose(webview);
        return;
      }
      _webview = webview;
      setState(() {});
      // In-page "I've signed in" button: injected into every new
      // document (login redirects create fresh documents), shown only
      // on music.youtube.com. Clicking posts to the 'nixietubeLogin'
      // channel, which triggers the single cookie read below.
      webview.registerJavaScriptMessageHandler(
        'nixietubeLogin',
        (name, body) => _checkNow(),
      );
      webview.addScriptToExecuteOnDocumentCreated(_loginButtonScript);
      webview.launch('https://music.youtube.com');
      // User closing the window counts as cancel. Mark closed so
      // dispose() never issues a second native close.
      webview.onClose.then((_) {
        _closed = true;
        if (!_done) _finish(null);
      }, onError: (_) {});
      _timeoutTimer = Timer(widget.timeout, () => _finish(null));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not open the login window.');
    }
  }

  /// Single user-triggered cookie read, via the native cookie jar so
  /// HttpOnly session cookies (LOGIN_INFO and friends, invisible to
  /// `document.cookie` — which is why YouTube kept rejecting the
  /// header) are included. Safe to call now: the vendored plugin
  /// NULL-guards every cookie getter (see
  /// packages/desktop_webview_window/VENDORED.md).
  Future<void> _checkNow() async {
    final webview = _webview;
    if (_done || _closed || _checking || webview == null) return;
    setState(() {
      _checking = true;
      _status = null;
    });
    try {
      if (webview.isNavigating.value) {
        setState(
          () => _status = 'Page still loading — wait a moment and try again.',
        );
        return;
      }
      final all = await webview
          .getAllCookies()
          .timeout(const Duration(seconds: 10));
      // Webview may have closed while awaiting.
      if (_done || _closed || !mounted) return;
      final header = youTubeCookieHeader(
        all
            .map((c) => {'domain': c.domain, 'name': c.name, 'value': c.value})
            .toList(),
      );
      if (header != null && header.isNotEmpty) {
        await _finish(header);
      } else if (mounted) {
        setState(
          () => _status =
              'No signed-in YouTube session found yet — complete the '
              'Google login in the other window, then press again.',
        );
      }
    } catch (_) {
      if (!mounted || _done) return;
      setState(
        () => _status = 'Could not read the session — try again.',
      );
    } finally {
      if (mounted && !_done) setState(() => _checking = false);
    }
  }

  /// Pops the dialog. The webview is closed from dispose() only, so a
  /// close can never race an in-flight evaluateJavaScript callback.
  Future<void> _finish(String? header) async {
    if (_done) return;
    _done = true;
    _timeoutTimer?.cancel();
    if (mounted) Navigator.of(context).pop(header);
  }

  /// GTK-level close (never clearAll: it spawns a temp webview which is
  /// unsafe on corrupted WebKit contexts after Google's redirects).
  void _safeClose(Webview? webview) {
    if (webview == null || _closed) return;
    _closed = true;
    Timer(const Duration(milliseconds: 500), () {
      try {
        webview.close();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    final webview = _webview;
    _webview = null;
    if (webview != null) _safeClose(webview);
    _done = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = _webview != null && _error == null;
    return AlertDialog(
      title: const Text('Log in with Google'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: scheme.error),
            )
          else if (!ready) ...[
            const M3ELoadingIndicator(),
            const SizedBox(height: 12),
            Text(
              'Opening the login window…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ] else ...[
            Text(
              'Complete all steps in the login window:\n'
              '1. Accept (or refuse) tracking cookies\n'
              '2. Click "SIGN IN" on the YTM home page\n'
              '3. Log into Google (email, password, 2FA)\n\n'
              'When you are back on YouTube Music and signed in, '
              'press the floating button inside that window — or '
              'the button below. The session is read exactly once.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            if (_checking) ...[
              const SizedBox(height: 12),
              const M3ELoadingIndicator(),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(
                _status!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ],
      ),
      actions: [
        M3ETextButton(
          onPressed: _checking ? null : () => _finish(null),
          child: const Text('Cancel'),
        ),
        if (ready)
          M3EFilledButton(
            onPressed: _checking ? null : _checkNow,
            child: Text(_checking ? 'Checking…' : "I've signed in — check"),
          ),
      ],
    );
  }
}
