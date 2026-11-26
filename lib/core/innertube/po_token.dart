// YouTube PO tokens, minted with BotGuard in a JavaScript engine.
//
// A deciphered web-client URL serves only its first megabyte: the edge
// answers 403 for every range past it until the request carries a
// proof-of-origin token. With `pot` attached the same URL serves the
// whole file, open-ended ranges included.
//
// The token comes from YouTube's BotGuard VM, which only runs in a real
// browser context. The flow (the same one MetroList uses):
//
//   1. read the watch page's BotGuard challenge and its paired EVENT_ID,
//   2. download the interpreter the challenge names,
//   3. run the VM in a WebView and snapshot it,
//   4. exchange the snapshot for an integrity token at GenerateIT,
//   5. build a minter from the snapshot and the integrity token,
//   6. mint a token per identifier: the visitor id for the player
//      request, the video id for the stream URL.
//
// The minter lives in the WebView between calls; only the per-video
// token is minted again for the next track.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../sys/http_client.dart';
import '../../sys/log.dart';

final _log = TaggedLog('pot');

/// Runs one JavaScript expression in the engine that hosts BotGuard.
typedef BotGuardEval = Future<String> Function(String script);

/// The two tokens one player request needs.
class PoTokenPair {
  const PoTokenPair({
    required this.playerRequest,
    required this.streamingData,
    required this.expiresAt,
  });

  /// Visitor-bound token for the player request body.
  final String playerRequest;

  /// Video-bound token appended to the stream URL as `pot`.
  final String streamingData;

  final DateTime expiresAt;

  bool get expired => DateTime.now().isAfter(expiresAt);
}

/// A token could not be minted. Callers fall back to the untokenized
/// stream, which still plays its first megabyte.
class PoTokenException implements Exception {
  const PoTokenException(this.message);

  final String message;

  @override
  String toString() => 'PoTokenException: $message';
}

const _requestKey = 'O43z0dpjhgX20SCx4KAo';
const _apiKey = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw';
const _generateIt = 'https://www.youtube.com/api/jnn/v1/GenerateIT';
const _consentCookie = 'SOCS=CAI';
const _expiryMargin = Duration(minutes: 10);
const _watchLimit = 4 * 1024 * 1024;
const _interpreterLimit = 8 * 1024 * 1024;

/// Mints PO tokens for the resolver. One instance keeps one BotGuard
/// session; a new visitor id or cookie rebuilds it.
class PoTokenMinter {
  PoTokenMinter({
    Dio? dio,
    required BotGuardEval evaluate,
    required this.userAgent,
  }) : _dio = dio ?? newHttpClient(),
       _eval = evaluate;

  final Dio _dio;
  final BotGuardEval _eval;

  /// The browser the watch page is read as. BotGuard's snapshot is bound
  /// to it, so the player request must use the same one.
  final String userAgent;

  Future<_Session>? _pending;
  _Session? _session;
  String? _visitor;
  String? _cookie;

  /// Returns both tokens for [videoId], or null when BotGuard could not
  /// be run. Never throws: a missing token must not fail the track.
  Future<PoTokenPair?> mint({
    required String videoId,
    required String visitorData,
    String? cookie,
  }) async {
    if (visitorData.isEmpty) return null;
    try {
      final session = await _ensure(videoId, visitorData, cookie);
      final player = await _generate(session, visitorData);
      final video = await _generate(session, videoId);
      if (player.isEmpty || video.isEmpty) return null;
      _log.d('minted PO tokens for $videoId');
      return PoTokenPair(
        playerRequest: player,
        streamingData: video,
        expiresAt: session.expiresAt,
      );
    } catch (error) {
      _log.w('PO token mint failed for $videoId: $error');
      _session = null;
      _pending = null;
      return null;
    }
  }

  /// Drops the BotGuard session; the next mint builds a new one.
  void invalidate() {
    _session = null;
    _pending = null;
  }

  Future<_Session> _ensure(
    String videoId,
    String visitorData,
    String? cookie,
  ) async {
    final current = _session;
    if (current != null &&
        !current.expired &&
        _visitor == visitorData &&
        _cookie == cookie) {
      return current;
    }
    final pending = _pending;
    if (pending != null && _visitor == visitorData && _cookie == cookie) {
      return pending;
    }
    _visitor = visitorData;
    _cookie = cookie;
    final future = _build(videoId, visitorData, cookie);
    _pending = future;
    try {
      final session = await future;
      _session = session;
      return session;
    } finally {
      if (identical(_pending, future)) _pending = null;
    }
  }

  Future<_Session> _build(
    String videoId,
    String visitorData,
    String? cookie,
  ) async {
    final page = await _watchPage(videoId, visitorData, cookie);
    final challenge = extractBotGuardChallenge(page);
    if (challenge == null) {
      throw const PoTokenException('watch page has no BotGuard challenge');
    }
    final eventId = extractEventId(page);
    if (eventId == null) {
      throw const PoTokenException('watch page has no EVENT_ID');
    }
    final interpreterUrl = trustedInterpreterUrl(challenge);
    final interpreter = await _fetch(interpreterUrl);
    if (interpreter.isEmpty || interpreter.length > _interpreterLimit) {
      throw const PoTokenException('BotGuard interpreter is unusable');
    }
    final challengeData = jsonEncode({
      'interpreterJavascript': {
        'privateDoNotAccessOrElseSafeScriptWrappedValue': interpreter,
        'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
            interpreterUrl,
      },
      'interpreterHash': challenge['interpreterHash'],
      'program': challenge['program'],
      'globalName': challenge['globalName'],
    });
    await _eval(botGuardBootstrap);
    final snapshot = await _awaitJs(
      '__ntPoSnapshot',
      'globalThis.__ntPoSnapshot = {state:"running"};'
          'globalThis.yt = {config_:{EVENT_ID:${jsonEncode(eventId)}}};'
          'window.yt = globalThis.yt;'
          'runBotGuard($challengeData).then(function(r){'
          'globalThis.__ntWebPoSignalOutput = r.webPoSignalOutput;'
          'globalThis.__ntPoSnapshot = {state:"ready",value:r.botguardResponse};'
          '}).catch(function(e){'
          'globalThis.__ntPoSnapshot = {state:"error",value:String(e)};});'
          '"started";',
    );
    final integrity = await _integrityToken(snapshot);
    final lifetime = await _awaitJs(
      '__ntPoMinter',
      'globalThis.__ntPoMinter = {state:"running"};'
          'createPoTokenMinter(globalThis.__ntWebPoSignalOutput,'
          '${integrity.tokenJavaScript}).then(function(){'
          'globalThis.__ntPoMinter = {state:"ready",value:"ready"};'
          '}).catch(function(e){'
          'globalThis.__ntPoMinter = {state:"error",value:String(e)};});'
          '"started";',
    );
    if (lifetime != 'ready') {
      throw const PoTokenException('BotGuard minter was not created');
    }
    return _Session(
      expiresAt: DateTime.now().add(
        integrity.lifetime > _expiryMargin
            ? integrity.lifetime - _expiryMargin
            : const Duration(minutes: 1),
      ),
    );
  }

  /// Mints one token. The identifier is the visitor id for the player
  /// request and the video id for the stream URL.
  Future<String> _generate(_Session session, String identifier) async {
    if (session.expired) throw const PoTokenException('BotGuard expired');
    final bytes = utf8.encode(identifier);
    final list = await _awaitJs(
      '__ntPoToken',
      'globalThis.__ntPoToken = {state:"running"};'
          'obtainPoToken(new Uint8Array(${jsonEncode(bytes)}))'
          '.then(function(t){'
          'globalThis.__ntPoToken = {state:"ready",'
          'value:Array.from(t).join(",")};'
          '}).catch(function(e){'
          'globalThis.__ntPoToken = {state:"error",value:String(e)};});'
          '"started";',
    );
    return base64UrlFromBytes(list);
  }

  /// Starts an async script and polls its result object. The engines
  /// return a value synchronously, so a promise cannot be awaited
  /// directly.
  Future<String> _awaitJs(String globalName, String script) async {
    await _eval(script);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final raw = await _eval('JSON.stringify(globalThis.$globalName || null)');
      final decoded = _decodeResult(raw);
      if (decoded is Map) {
        final state = decoded['state'];
        if (state == 'ready') return decoded['value']?.toString() ?? '';
        if (state == 'error') {
          throw PoTokenException(
            decoded['value']?.toString() ?? 'BotGuard failed',
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw const PoTokenException('BotGuard timed out');
  }

  /// Android's WebView returns a JSON-encoded string; desktop returns
  /// the object. Unwrap one extra layer when needed.
  static dynamic _decodeResult(String raw) {
    if (raw.isEmpty) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return null;
      }
    }
    return decoded;
  }

  Future<String> _watchPage(
    String videoId,
    String visitorData,
    String? cookie,
  ) async {
    final cookies = [
      if (cookie != null && cookie.isNotEmpty) cookie,
      _consentCookie,
    ].join('; ');
    final res = await _dio
        .getUri<String>(
          Uri.parse('https://www.youtube.com/watch?v=$videoId&app=desktop'),
          options: Options(
            headers: {
              'User-Agent': userAgent,
              'Accept': 'text/html',
              'X-Goog-Visitor-Id': visitorData,
              'Cookie': cookies,
            },
          ),
        )
        .timeout(const Duration(seconds: 30));
    final data = res.data ?? '';
    if (data.length > _watchLimit) {
      throw const PoTokenException('watch page is too large');
    }
    return data;
  }

  Future<String> _fetch(String url) async {
    final res = await _dio
        .getUri<String>(
          Uri.parse(url),
          options: Options(headers: {'User-Agent': userAgent}),
        )
        .timeout(const Duration(seconds: 30));
    return res.data ?? '';
  }

  Future<_IntegrityToken> _integrityToken(String botguardResponse) async {
    final res = await _dio
        .postUri<String>(
          Uri.parse(_generateIt),
          data: jsonEncode([_requestKey, botguardResponse]),
          options: Options(
            headers: {
              'Content-Type': 'application/json+protobuf',
              'Accept': 'application/json',
              'User-Agent': userAgent,
              'x-goog-api-key': _apiKey,
              'x-user-agent': 'grpc-web-javascript/0.1',
            },
          ),
        )
        .timeout(const Duration(seconds: 30));
    final decoded = jsonDecode(res.data ?? '');
    if (decoded is! List || decoded.length < 2) {
      throw const PoTokenException('invalid integrity response');
    }
    final bytes = _decodeBase64(decoded[0].toString());
    final seconds = decoded[1] is int
        ? decoded[1] as int
        : int.tryParse(decoded[1].toString()) ?? 0;
    return _IntegrityToken(
      tokenJavaScript: 'new Uint8Array(${jsonEncode(bytes)})',
      lifetime: Duration(seconds: seconds),
    );
  }

  void close() => _dio.close();
}

class _Session {
  const _Session({required this.expiresAt});

  final DateTime expiresAt;

  bool get expired => DateTime.now().isAfter(expiresAt);
}

class _IntegrityToken {
  const _IntegrityToken({
    required this.tokenJavaScript,
    required this.lifetime,
  });

  final String tokenJavaScript;
  final Duration lifetime;
}

/// The BotGuard driver, evaluated once before the first snapshot. It is
/// the same VM handshake MetroList's page-bound minter performs.
const botGuardBootstrap = r'''
var __ntBgFunctions = null;
var __ntPoTokenMinter = null;
function __ntLoadBotGuard(challengeData) {
  var bgVm = window[challengeData.globalName];
  __ntBgFunctions = null;
  if (!bgVm || !bgVm.a) throw new Error("BotGuard VM is unavailable");
  var vmLoad = bgVm.a(challengeData.program, function(asyncSnapshot, shutdown, passEvent, checkCamera) {
    __ntBgFunctions = {asyncSnapshotFunction: asyncSnapshot};
  }, true, undefined, function() {}, [[], []], undefined, false,
    [function() {}, function() {}, function() {}, function() {}, function() {}]);
  return Promise.resolve(vmLoad).then(function() {
    return new Promise(function(resolve, reject) {
      var attempts = 0;
      var interval = setInterval(function() {
        if (__ntBgFunctions && __ntBgFunctions.asyncSnapshotFunction) {
          clearInterval(interval); resolve(__ntBgFunctions);
        } else if (++attempts >= 10000) {
          clearInterval(interval); reject(new Error("BotGuard snapshot timed out"));
        }
      }, 1);
    });
  });
}
function runBotGuard(challengeData) {
  var interpreter = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!interpreter) throw new Error("BotGuard interpreter is unavailable");
  new Function(interpreter)();
  var webPoSignalOutput = [];
  return __ntLoadBotGuard({globalName: challengeData.globalName, program: challengeData.program})
    .then(function(fns) {
      return new Promise(function(resolve, reject) {
        try {
          fns.asyncSnapshotFunction(function(response) { resolve(response); },
            [undefined, undefined, webPoSignalOutput, undefined]);
        } catch (error) { reject(error); }
      });
    })
    .then(function(response) {
      return {webPoSignalOutput: webPoSignalOutput, botguardResponse: response};
    });
}
async function createPoTokenMinter(webPoSignalOutput, integrityToken) {
  var getMinter = webPoSignalOutput[0];
  if (typeof getMinter !== "function") throw new Error("BotGuard minter factory is unavailable");
  __ntPoTokenMinter = await getMinter(integrityToken);
  if (typeof __ntPoTokenMinter !== "function") throw new Error("BotGuard minter is unavailable");
}
async function obtainPoToken(identifier) {
  if (!__ntPoTokenMinter) throw new Error("BotGuard minter has not been initialized");
  var result = await __ntPoTokenMinter(identifier);
  if (!(result instanceof Uint8Array)) throw new Error("BotGuard returned an invalid token");
  return result;
}
"ready";
''';

/// Reads the `bgChallenge` object from a watch page, or null.
///
/// The page carries several `window.ytAtN` calls — the first is only the
/// promise shim — so every one is scanned until a challenge parses.
Map<String, dynamic>? extractBotGuardChallenge(String page) {
  final call = RegExp(r'window\s*\.\s*ytAtN');
  for (final match in call.allMatches(page)) {
    final open = page.indexOf('(', match.end);
    if (open < 0) break;
    final brace = _firstBrace(page, open + 1);
    if (brace < 0) continue;
    final wrapper = _scanObject(page, brace);
    if (wrapper == null) continue;
    final key = RegExp('(?:["\']R["\']|\\bR)\\s*:').firstMatch(wrapper);
    if (key == null) continue;
    var start = key.end;
    while (start < wrapper.length && _isSpace(wrapper[start])) {
      start++;
    }
    if (start >= wrapper.length) continue;
    final raw = wrapper[start] == '{'
        ? _scanObject(wrapper, start)
        : _decodeJsString(wrapper, start);
    if (raw == null) continue;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['bgChallenge'] is Map) {
        return Map<String, dynamic>.from(decoded['bgChallenge'] as Map);
      }
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// The page's `EVENT_ID`, which must be paired with its challenge.
String? extractEventId(String page) {
  final match = RegExp(r'"EVENT_ID"\s*:\s*"([^"]{1,1024})"').firstMatch(page);
  return match?.group(1);
}

/// The interpreter URL the challenge names, restricted to the hosts that
/// serve BotGuard. Anything else is refused rather than evaluated.
String trustedInterpreterUrl(Map<String, dynamic> challenge) {
  final wrapped = challenge['interpreterUrl'];
  final value = wrapped is Map
      ? wrapped['privateDoNotAccessOrElseTrustedResourceUrlWrappedValue']
      : null;
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw const PoTokenException('challenge has no interpreter URL');
  }
  final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
  const hosts = {'www.google.com', 'www.gstatic.com'};
  final path = uri?.path ?? '';
  final trustedPath =
      path == '/botguard.js' ||
      (uri?.host == 'www.google.com' &&
          RegExp(r'^/js/th/[A-Za-z0-9_-]{20,256}\.js$').hasMatch(path));
  if (uri == null ||
      uri.scheme != 'https' ||
      !hosts.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      !trustedPath) {
    throw const PoTokenException('untrusted BotGuard interpreter URL');
  }
  return uri.toString();
}

/// Base64url-encodes the comma-separated byte list the VM returns.
String base64UrlFromBytes(String list) {
  if (list.isEmpty) return '';
  final parts = list.split(',');
  final bytes = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part.trim());
    if (value == null || value < 0 || value > 255) {
      throw const PoTokenException('invalid BotGuard token byte');
    }
    bytes.add(value);
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}

List<int> _decodeBase64(String value) {
  var normalized = value
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('.', '=');
  normalized += '=' * ((4 - normalized.length % 4) % 4);
  return base64Url.decode(normalized);
}

bool _isSpace(String char) =>
    char == ' ' || char == '\n' || char == '\r' || char == '\t';

/// The first `{` outside a string, or -1 when the call closes first.
int _firstBrace(String source, int start) {
  String? quote;
  var escaped = false;
  for (var i = start; i < source.length; i++) {
    final char = source[i];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '{') {
      return i;
    } else if (char == ')') {
      return -1;
    }
  }
  return -1;
}

/// The balanced `{...}` literal starting at [start], or null.
String? _scanObject(String source, int start) {
  var i = start;
  while (i < source.length && _isSpace(source[i])) {
    i++;
  }
  if (i >= source.length || source[i] != '{') return null;
  final objectStart = i;
  var depth = 0;
  String? quote;
  var escaped = false;
  for (; i < source.length; i++) {
    final char = source[i];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) return source.substring(objectStart, i + 1);
    }
  }
  return null;
}

/// Decodes a JavaScript string literal, including the `\xNN` escapes the
/// watch page wraps its challenge in.
String? _decodeJsString(String source, int start) {
  if (start >= source.length) return null;
  final quote = source[start];
  if (quote != '"' && quote != "'") return null;
  final out = StringBuffer();
  var i = start + 1;
  while (i < source.length) {
    final char = source[i++];
    if (char == quote) return out.toString();
    if (char != r'\') {
      out.write(char);
      continue;
    }
    if (i >= source.length) return null;
    final escaped = source[i++];
    switch (escaped) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 't':
        out.write('\t');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'u':
      case 'x':
        final digits = escaped == 'u' ? 4 : 2;
        if (i + digits > source.length) return null;
        final code = int.tryParse(source.substring(i, i + digits), radix: 16);
        if (code == null) return null;
        out.writeCharCode(code);
        i += digits;
      case '\n':
        break;
      default:
        out.write(escaped);
    }
  }
  return null;
}
