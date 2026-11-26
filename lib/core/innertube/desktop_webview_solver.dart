// Desktop JavaScript challenge solver: the EJS bundle runs in a hidden
// 1x1 WebView window (WebKitGTK on Linux, WebView2 on Windows, WKWebView
// on macOS). These engines are modern and fast; keeping the solver in a
// platform WebView also avoids loading a second JavaScriptCore next to
// the login window's.

import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';

/// Owns one hidden WebView reused for every solve.
class DesktopWebViewChallengeSolver {
  Webview? _web;
  Future<Webview>? _opening;
  Future<String> _tail = Future.value('');

  Future<Webview> _ensure(String lib, String core) async {
    final existing = _web;
    if (existing != null) return existing;
    final opening = _opening;
    if (opening != null) return opening;
    final future = _open(lib, core);
    _opening = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_opening, future)) _opening = null;
      rethrow;
    }
  }

  Future<Webview> _open(String lib, String core) async {
    final web = await WebviewWindow.create(
      configuration: const CreateConfiguration(
        windowWidth: 1,
        windowHeight: 1,
        openHidden: true,
        title: '',
        titleBar: TitleBarOptions(
          showNavigation: false,
          showReload: false,
          showTitle: false,
          showHost: false,
        ),
      ),
    );
    await web.addScriptToExecuteOnDocumentCreated(
      '$lib\nObject.assign(globalThis, lib);\n$core',
    );
    // A data: URL gives the solver its own blank document without the
    // default composer page's Trusted Types CSP, which rejects the
    // solver's `Function(...)` evaluation on every load after the first.
    await web.launch('data:text/html;charset=utf-8,<html><body></body></html>');
    await _waitUntilLoaded(web);
    _web = web;
    _opening = null;
    return web;
  }

  Future<void> _waitUntilLoaded(Webview web) async {
    if (!_isLoading(web)) return;
    final done = Completer<void>();
    void listener() {
      if (!_isLoading(web) && !done.isCompleted) done.complete();
    }

    web.navigationState.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 10));
    } finally {
      web.navigationState.removeListener(listener);
    }
  }

  bool _isLoading(Webview web) => web.navigationState.value.isLoading;

  /// Evaluates [script] and returns the JSON string it produced.
  ///
  /// Solves are serialized: the WebView runs one script at a time, and
  /// the prefetch fires several resolves together. The page is reloaded
  /// first because the composer's Trusted Types policy rejects the
  /// solver's `Function(...)` evaluation on every document after the
  /// first; a fresh document resets that.
  Future<String> solve({
    required String lib,
    required String core,
    required String script,
    bool retire = true,
  }) {
    final run = _tail.then((_) => _solveNow(lib, core, script, retire: retire));
    _tail = run.then((_) => '', onError: (_) => '');
    return run;
  }

  Future<String> _solveNow(
    String lib,
    String core,
    String script, {
    required bool retire,
  }) async {
    final web = await _ensure(lib, core);
    final result = await web.evaluateJavaScript(script);
    if (retire) {
      // WebKit's composer enforces a Trusted Types policy that rejects
      // the solver's `Function(...)` evaluation after the first script
      // in a document. Retire this document and open a fresh one now,
      // so the next solve (often minutes away) does not pay for it.
      unawaited(_retireAndPrepare(lib, core, web));
    }
    return result?.toString() ?? '';
  }

  Future<void> _retireAndPrepare(String lib, String core, Webview web) async {
    if (identical(_web, web)) _web = null;
    _opening = null;
    try {
      await web.close();
    } catch (_) {}
    try {
      await _ensure(lib, core);
    } catch (_) {}
  }

  /// Closes the hidden window. Safe to call when none was created.
  Future<void> close() async {
    final web = _web;
    _web = null;
    _opening = null;
    await web?.close();
  }
}
