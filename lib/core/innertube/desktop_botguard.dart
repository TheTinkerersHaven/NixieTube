// Desktop BotGuard runtime: a hidden WebView parked on a YouTube page.
//
// BotGuard reads the document it runs in, so the VM needs a real
// youtube.com origin — a blank data: document produces a token the edge
// refuses. `robots.txt` is the lightest page on that origin, and it has
// no Trusted Types policy, so the interpreter's `Function(...)` runs on
// every call. Unlike the challenge solver's window this one stays open:
// the minter it builds is reused for every track.

import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';

import '../../sys/log.dart';

final _log = TaggedLog('pot');

/// The page the BotGuard document lives on.
const botGuardOriginUrl = 'https://www.youtube.com/robots.txt';

class DesktopBotGuardRuntime {
  Webview? _web;
  Future<Webview>? _opening;
  Future<String> _tail = Future.value('');

  /// Evaluates [script] in the BotGuard document, serialized with any
  /// other call: the WebView runs one script at a time.
  Future<String> evaluate(String script) {
    final run = _tail.then((_) => _evaluateNow(script));
    _tail = run.then((_) => '', onError: (_) => '');
    return run;
  }

  Future<String> _evaluateNow(String script) async {
    final web = await _ensure();
    final result = await web.evaluateJavaScript(script);
    return result?.toString() ?? '';
  }

  Future<Webview> _ensure() async {
    final existing = _web;
    if (existing != null) return existing;
    final opening = _opening;
    if (opening != null) return opening;
    final future = _open();
    _opening = future;
    try {
      final web = await future;
      _web = web;
      return web;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  Future<Webview> _open() async {
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
    await web.launch(botGuardOriginUrl);
    await _waitUntilLoaded(web);
    _log.d('BotGuard document ready');
    return web;
  }

  Future<void> _waitUntilLoaded(Webview web) async {
    if (!web.navigationState.value.isLoading) return;
    final done = Completer<void>();
    void listener() {
      if (!web.navigationState.value.isLoading && !done.isCompleted) {
        done.complete();
      }
    }

    web.navigationState.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 20));
    } finally {
      web.navigationState.removeListener(listener);
    }
  }

  /// Drops the document; the next evaluate opens a fresh one.
  Future<void> reset() async {
    final web = _web;
    _web = null;
    _opening = null;
    try {
      await web?.close();
    } catch (_) {}
  }

  Future<void> close() => reset();
}
