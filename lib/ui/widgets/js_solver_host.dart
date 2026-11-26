// Hidden WebView host for the JavaScript challenge solver on phones.
//
// Android's and iOS's WebView engines are modern (Chromium / JavaScriptCore)
// and fast, and the app needs one anyway to mint the BotGuard PO tokens, so
// the challenge solve runs here instead of in a JavaScript runtime bundled
// with the app. This host keeps a 1x1 WebView alive in the app's tree and
// exposes a hook the core solver calls; the document carries a youtube.com
// origin because the PO-token VM reads the document it runs in. Desktop
// uses its own hidden windows instead (see js_challenge_solver.dart and
// desktop_botguard.dart).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/innertube/js_challenge_solver.dart';
import '../../core/innertube/stream_resolver.dart' show webRemixUserAgent;
import '../../sys/log.dart';

final _log = TaggedLog('jsc');

/// Wraps [child] with the hidden solver WebView on Android/iOS.
class JsSolverHost extends StatefulWidget {
  const JsSolverHost({super.key, required this.child});

  final Widget child;

  @override
  State<JsSolverHost> createState() => _JsSolverHostState();
}

class _JsSolverHostState extends State<JsSolverHost> {
  WebViewController? _controller;
  final Completer<void> _ready = Completer<void>();
  WebViewSolveHook? _hook;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(_boot());
    }
  }

  Future<void> _boot() async {
    try {
      final scripts = await Future.wait([
        rootBundle.loadString('assets/js/yt.solver.lib.js'),
        rootBundle.loadString('assets/js/yt.solver.core.min.js'),
      ]);
      final controller = WebViewController();
      unawaited(controller.setJavaScriptMode(JavaScriptMode.unrestricted));
      // BotGuard's snapshot describes the browser it runs in, and the
      // player request presents the same one.
      unawaited(controller.setUserAgent(webRemixUserAgent));
      unawaited(
        controller.setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!_ready.isCompleted) _ready.complete();
            },
          ),
        ),
      );
      // A YouTube base URL gives the document that origin: the PO-token
      // VM reads the document it runs in and a blank one yields a token
      // the edge refuses.
      unawaited(
        controller.loadHtmlString(
          _html(scripts[0], scripts[1]),
          baseUrl: 'https://www.youtube.com',
        ),
      );
      _controller = controller;
      _hook = (script) async {
        await _ready.future;
        final result = await controller.runJavaScriptReturningResult(script);
        return result.toString();
      };
      webviewSolveHook = _hook;
      if (mounted) setState(() {});
    } catch (error) {
      // The core solver falls back to its own engine; a failed WebView
      // must not take the app down.
      _log.w('WebView solver host failed: $error');
    }
  }

  @override
  void dispose() {
    if (identical(webviewSolveHook, _hook)) webviewSolveHook = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: IgnorePointer(child: WebViewWidget(controller: controller)),
        ),
      ],
    );
  }
}

String _html(String lib, String core) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<script>$lib</script>
<script>Object.assign(globalThis, lib);</script>
<script>$core</script>
</body></html>
''';
