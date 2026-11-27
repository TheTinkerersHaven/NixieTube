// YouTube's signatureCipher / throttling-`n` challenges, solved with the
// EJS challenge solver (yt-dlp/ejs, Unlicense) running in a JavaScript
// engine.
//
// YouTube's WEB clients return `signatureCipher` instead of a direct URL
// for many tracks (all age-restricted ones), and direct URLs carry an `n`
// parameter that throttles the stream unless it is transformed. Both are
// JavaScript challenges defined by the player script; the solver extracts
// the functions that define them and evaluates those.
//
// The extraction is the AST pass: meriyah parses the whole ~2.6 MB script
// and astring prints the pieces back out. It depends on nothing but the
// player version, and on an engine without a JIT it costs minutes — so the
// app normally answers from the already-passed script the project
// publishes per version (player_presolver.dart, produced by
// tool/ejs_presolve.js) and only parses locally when no such copy exists.
// That artifact is the whole player too, so it is shipped and compiled once
// per version: the phone's WebView keeps the compiled `_result` on `window`,
// and a later solve for the same version carries only the challenges.
//
// The solver is a vendored, generated bundle (assets/js): `yt.solver.lib`
// carries meriyah (ISC) and astring (MIT), and `yt.solver.core` is the
// Unlicense solver. The lib file is not pristine: astring's writer is
// patched to buffer its output and join once, because appending every
// printed token to one string is quadratic on engines without rope strings
// (one player is 1.38 M appends — minutes on QuickJS, 0.8 s once buffered).
// test/ejs_solver_bundle_test.dart guards the patch and lists the four
// edits for whoever regenerates the bundle.
//
// Engines: phones run the bundle in a hidden platform WebView (Chromium on
// Android, WebKit on iOS) through JsSolverHost, desktop in a hidden WebKit
// window through desktop_webview_window. Both are system engines the app
// needs anyway (the phone WebView also mints the BotGuard tokens), so no
// JavaScript runtime is bundled with the app.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import '../../sys/log.dart';
import 'desktop_webview_solver.dart';

/// Diagnostics for the JavaScript challenge solver.
final _log = TaggedLog('jsc');

/// Runs one JavaScript expression in the platform WebView and returns its
/// string result. Installed by the app's hidden WebView host on phones.
typedef WebViewSolveHook = Future<String> Function(String script);

/// Set by `JsSolverHost` on Android/iOS. Null on desktop and in tests.
WebViewSolveHook? webviewSolveHook;

/// A challenge the solver could not answer.
class JsChallengeException implements Exception {
  const JsChallengeException(this.message);

  final String message;

  @override
  String toString() => 'JsChallengeException: $message';
}

/// Solves YouTube's `sig` and `n` challenges for one player script.
abstract class ChallengeSolver {
  /// Prepares any heavyweight engine state ahead of the first solve.
  /// The default is a no-op.
  Future<void> warmUp() async {}

  /// Returns a map from challenge to solved value. Throws
  /// [JsChallengeException] when the solver fails or the script does not
  /// define the requested functions; callers fail closed.
  ///
  /// One of [playerJs] and [preprocessedPlayer] is required:
  ///
  /// - [playerJs] is the raw player script, which the bundle parses with
  ///   meriyah and prints the challenge functions back out with astring.
  ///   That AST pass is what costs minutes on an engine without a JIT.
  /// - [preprocessedPlayer] is the output of that pass, published per
  ///   player version by `tool/ejs_presolve.js` (see
  ///   player_presolver.dart). Answering from it needs no AST pass, so it
  ///   is what the app uses whenever a version is published.
  ///
  /// [playerId] names the player version [preprocessedPlayer] belongs to.
  /// Where the engine outlives a solve — the phone WebView — the compiled
  /// script is kept under that key, so only the first solve for a version
  /// carries the artifact.
  Future<Map<String, String>> solve({
    String? playerId,
    String? playerJs,
    String? preprocessedPlayer,
    List<String> sigChallenges,
    List<String> nChallenges,
  });
}

/// The script that answers [sigChallenges] and [nChallenges] from a
/// pre-solved player, keeping the compiled script in the engine.
///
/// The artifact is the whole player — 2.4 MB for the current version — and
/// compiling it is the expensive half of a solve, so it is shipped and
/// compiled once per [playerId]: the entry points stay on `window`, and a
/// later solve for the same version carries only the challenge strings.
/// Without [preprocessed] the script compiles nothing and reports `cold`
/// when the engine does not hold the player yet.
///
/// That state lives in the engine on purpose: a document the host reloaded,
/// a WebView the system killed and the desktop solver's fresh page after
/// every retire all start empty, and the next solve compiles again.
@visibleForTesting
String presolvedSolveScript({
  required String playerId,
  String? preprocessed,
  List<String> sigChallenges = const [],
  List<String> nChallenges = const [],
}) {
  final id = jsonEncode(playerId);
  final source = preprocessed == null ? 'null' : jsonEncode(preprocessed);
  final requests = jsonEncode([
    if (sigChallenges.isNotEmpty) {'type': 'sig', 'challenges': sigChallenges},
    if (nChallenges.isNotEmpty) {'type': 'n', 'challenges': nChallenges},
  ]);
  return '''
(() => {
  const held = window.__jscPlayers || (window.__jscPlayers = {id: null, result: null});
  if (held.id !== $id) {
    const source = $source;
    if (source === null) return JSON.stringify({type: 'cold'});
    const result = {n: null, sig: null};
    Function('globalThis', '_result', source)({}, result);
    held.id = $id;
    held.result = result;
  }
  const responses = $requests.map((request) => {
    const solve = held.result && held.result[request.type];
    if (typeof solve !== 'function') {
      return {type: 'error', error: 'Failed to extract ' + request.type + ' function'};
    }
    try {
      const data = {};
      for (const challenge of request.challenges) data[challenge] = solve(challenge);
      return {type: 'result', data};
    } catch (error) {
      return {type: 'error', error: String(error)};
    }
  });
  return JSON.stringify({type: 'result', responses});
})()''';
}

/// Encodes the solver input off the UI isolate.
///
/// The payload is the artifact plus the challenge list: megabytes of text
/// whose encoding took ~0.15 s on a desktop and several hundred on a phone,
/// all of it on the thread that draws the frame — a visible hitch exactly
/// when a track starts. The string is copied to the worker and the result
/// back, which is milliseconds either way.
Future<String> _encodeInput(Map<String, Object?> input) =>
    Isolate.run(() => jsonEncode(input));

/// [ChallengeSolver] backed by the vendored EJS bundle.
class JsChallengeSolver implements ChallengeSolver {
  JsChallengeSolver({this.timeout = const Duration(seconds: 45)});

  /// Upper bound for one solve. A hung solve must not pin the player.
  final Duration timeout;

  String? _lib;
  String? _core;
  Future<void>? _loading;
  DesktopWebViewChallengeSolver? _desktop;

  /// Loads the vendored solver bundle once.
  Future<void> _ensureLoaded() {
    if (_lib != null && _core != null) return Future.value();
    return _loading ??= () async {
      final scripts = await Future.wait([
        rootBundle.loadString('assets/js/yt.solver.lib.js'),
        rootBundle.loadString('assets/js/yt.solver.core.min.js'),
      ]);
      _lib = scripts[0];
      _core = scripts[1];
    }();
  }

  /// The WebView solve hook, waiting briefly for the host to publish it.
  /// The WebView host loads the solver bundle at startup; a play in the
  /// first moments may beat it. Null when it never came up.
  Future<WebViewSolveHook?> _waitForWebViewHook() async {
    var hook = webviewSolveHook;
    for (var i = 0; i < 30 && hook == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      hook = webviewSolveHook;
    }
    return hook;
  }

  /// Creates the desktop solver window ahead of the first play, so the
  /// first age-restricted track does not pay for it. Best-effort.
  @override
  Future<void> warmUp() async {
    // Phones are warmed by JsSolverHost, which loads the bundle into its
    // WebView as soon as the host mounts.
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      await _ensureLoaded();
      final desktop = _desktop ??= DesktopWebViewChallengeSolver();
      await desktop.solve(lib: _lib!, core: _core!, script: '1', retire: false);
      _log.d('solver warm');
    } catch (error) {
      _log.w('solver warm-up failed: $error');
    }
  }

  /// Solves [sigChallenges] and [nChallenges] for the player identified by
  /// [playerJs] or [preprocessedPlayer].
  ///
  /// Returns a map from challenge to solved value. Throws
  /// [JsChallengeException] when the solver fails or the script does not
  /// define the requested functions; callers fail closed.
  @override
  Future<Map<String, String>> solve({
    String? playerId,
    String? playerJs,
    String? preprocessedPlayer,
    List<String> sigChallenges = const [],
    List<String> nChallenges = const [],
  }) async {
    if (sigChallenges.isEmpty && nChallenges.isEmpty) {
      return const {};
    }
    // A pre-solved script answers without the AST pass: the bundle only
    // evaluates the code it was handed. The player script is the fallback
    // for a version that is not published.
    final presolved = preprocessedPlayer;
    final raw = playerJs;
    final usePresolved = presolved != null && presolved.isNotEmpty;
    if (!usePresolved && (raw == null || raw.isEmpty)) {
      throw const JsChallengeException('no player script to solve');
    }
    final watch = Stopwatch()..start();
    // A version the engine already holds answers from the compiled script,
    // so only the first solve for it ships the artifact. Only the phone's
    // WebView outlives a solve: the desktop solver retires its document
    // after every script, so there the artifact always travels with the
    // call. Asked without the source and reporting `cold`, a document that
    // did not survive is noticed instead of answered with a broken solve.
    final mobile = Platform.isAndroid || Platform.isIOS;
    final retainId = usePresolved && mobile ? playerId : null;
    String output;
    if (retainId != null && retainId.isNotEmpty) {
      output = await _run(
        presolvedSolveScript(
          playerId: retainId,
          sigChallenges: sigChallenges,
          nChallenges: nChallenges,
        ),
      );
      if (_isCold(_decode(output))) {
        output = await _run(
          presolvedSolveScript(
            playerId: retainId,
            preprocessed: presolved,
            sigChallenges: sigChallenges,
            nChallenges: nChallenges,
          ),
        );
      }
    } else {
      final input = await _encodeInput({
        if (usePresolved) ...{
          'type': 'preprocessed',
          'preprocessed_player': presolved,
        } else ...{
          'type': 'player',
          'player': raw!,
        },
        'requests': [
          if (sigChallenges.isNotEmpty)
            {'type': 'sig', 'challenges': sigChallenges},
          if (nChallenges.isNotEmpty) {'type': 'n', 'challenges': nChallenges},
        ],
      });
      output = await _run(
        'JSON.stringify((window.__jsc || window.jsc)($input))',
      );
    }

    final decoded = _decode(output);
    if (decoded is! Map || decoded['type'] != 'result') {
      throw JsChallengeException('unexpected solver output');
    }
    final responses = decoded['responses'];
    if (responses is! List) {
      throw JsChallengeException('missing responses');
    }
    final solved = <String, String>{};
    for (final response in responses) {
      if (response is! Map || response['type'] != 'result') continue;
      final data = response['data'];
      if (data is! Map) continue;
      data.forEach((key, value) {
        if (key is String && value is String) solved[key] = value;
      });
    }
    if (solved.isEmpty) {
      throw JsChallengeException('no challenge was solved');
    }
    _log.d(
      'solved ${sigChallenges.length} sig / ${nChallenges.length} n '
      'challenge(s) via '
      '${Platform.isAndroid || Platform.isIOS ? 'jsc' : 'desktop-webview'} '
      '(${usePresolved ? 'pre-solved' : 'local AST'}) '
      'in ${watch.elapsedMilliseconds} ms',
    );
    return solved;
  }

  /// Runs [script] in the solver engine and returns what it produced.
  Future<String> _run(String script) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Phones run the solve in the hidden WebView host (JsSolverHost),
      // which also mints the BotGuard PO tokens — one engine, already
      // required, instead of a JavaScript runtime bundled into the app.
      final hook = await _waitForWebViewHook();
      if (hook == null) {
        throw const JsChallengeException('solver WebView is not ready');
      }
      return hook(script).timeout(timeout);
    }
    // The desktop WebView carries the bundle so it can parse a raw player
    // script. A pre-solved one answers without it, but the document is
    // shared with the fallback, so it is loaded either way.
    await _ensureLoaded();
    final desktop = _desktop ??= DesktopWebViewChallengeSolver();
    return desktop
        .solve(lib: _lib!, core: _core!, script: script)
        .timeout(timeout);
  }

  /// What the engine returned, unwrapped: Android's WebView hands back a
  /// JSON-encoded result string, desktop returns the object directly.
  static Object? _decode(String output) {
    final decoded = jsonDecode(output);
    return decoded is String ? jsonDecode(decoded) : decoded;
  }

  /// Whether the engine answered that it does not hold the player yet.
  static bool _isCold(Object? decoded) =>
      decoded is Map && decoded['type'] == 'cold';
}
