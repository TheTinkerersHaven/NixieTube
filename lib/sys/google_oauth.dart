// Google OAuth via the standard browser flow (Desktop-type clients,
// loopback redirect), ported from Kotlin `GoogleOAuth`.
//
// Account data goes through the YouTube Data API; InnerTube rejects
// third-party sessions. Issued tokens persist to
// `~/.config/nixietube/oauth.properties` and refresh automatically when
// within 120s of expiry.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show ContentType, File, HttpRequest, HttpServer;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../core/innertube/auth_session.dart';
import 'http_client.dart';
import 'paths.dart';
import 'sys_config.dart';

/// OAuth scope requested for YouTube access.
const googleOAuthScope = 'https://www.googleapis.com/auth/youtube';

/// Clock skew tolerated when judging a token as still valid.
const tokenExpirySkewSec = 120;

/// Upper bound on waiting for the browser-login callback.
const maxPollDuration = Duration(minutes: 10);

/// Persisted OAuth token set for a Desktop-type client.
class OAuthTokens {
  const OAuthTokens(this.accessToken, this.refreshToken, this.expiresAtSec);

  /// Bearer token sent against InnerTube.
  final String accessToken;

  /// Token used to mint new access tokens; may be blank on partial responses.
  final String refreshToken;

  /// Epoch seconds at which [accessToken] expires.
  final int expiresAtSec;
}

/// Generates a PKCE code verifier (unreserved chars, 64 random bytes).
String newCodeVerifier([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(64, (_) => rng.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Derives a PKCE S256 code challenge from [verifier].
String codeChallenge(String verifier) {
  final digest = sha256.convert(utf8.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Generates an opaque OAuth state token for CSRF protection.
String newOAuthState([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

class GoogleOAuth {
  GoogleOAuth({SysConfig? config, Dio? dio, String? storePath})
    : _config = config ?? SysConfig(),
      _dio = dio ?? newHttpClient(),
      _storePath = storePath ?? '${configDir().path}/oauth.properties';

  final SysConfig _config;
  final Dio _dio;
  final String _storePath;

  void close() => _dio.close();

  /// Returns the stored OAuth client id/secret pair, or null when either
  /// is blank.
  (String, String)? savedClient() {
    final id = _config.googleClientId;
    final secret = _config.googleClientSecret;
    if (id.trim().isEmpty || secret.trim().isEmpty) return null;
    return (id, secret);
  }

  /// Runs the standard browser login for Desktop-type OAuth clients.
  ///
  /// Starts a loopback HTTP server, asks the caller to open the consent
  /// page via [onBrowse], waits for the authorization-code callback, then
  /// exchanges it (PKCE S256 + client secret) and saves the tokens.
  Future<bool> loginBrowser(
    String clientId,
    String clientSecret,
    FutureOr<void> Function(String url) onBrowse, {
    bool Function() cancelled = _neverCancelled,
  }) async {
    final verifier = newCodeVerifier();
    final challenge = codeChallenge(verifier);
    final state = newOAuthState();
    HttpServer? server;
    try {
      server = await HttpServer.bind('127.0.0.1', 0);
    } catch (_) {
      return false;
    }
    final redirectUri = 'http://127.0.0.1:${server.port}/callback';
    try {
      final params = {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': googleOAuthScope,
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      };
      final authUrl =
          'https://accounts.google.com/o/oauth2/v2/auth?${Uri(queryParameters: params).query}';
      await onBrowse(authUrl);
      final code = await _awaitLoopbackCode(server, state, cancelled);
      if (code == null || cancelled()) return false;
      final tokens = await _exchangeCode(
        clientId,
        clientSecret,
        code,
        redirectUri,
        verifier,
      );
      if (tokens == null) return false;
      _saveTokens(clientId, tokens);
      return true;
    } finally {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  /// Returns a session with a valid Bearer token, refreshing first if
  /// within 120s of expiry. Used as the InnerTube auth provider.
  Future<AuthSession?> validSession() async {
    final loaded = _loadTokens();
    if (loaded == null) return null;
    final (clientId, tokens) = loaded;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (tokens.expiresAtSec - now > tokenExpirySkewSec) {
      return AuthSession(accessToken: tokens.accessToken);
    }
    final refreshed = await refresh(clientId, tokens);
    if (refreshed == null) return null;
    return AuthSession(accessToken: refreshed.accessToken);
  }

  /// Deletes the persisted token file, signing the user out.
  void logout() {
    try {
      File(_storePath).deleteSync();
    } catch (_) {}
  }

  /// True when a Google sign-in token is stored — the user
  /// has completed the OAuth flow (the token may still need a
  /// refresh, but sign-in itself is done).
  bool get hasStoredToken => _loadTokens() != null;

  /// Returns the current valid access token, refreshing first if needed.
  Future<String?> accessToken() async => (await validSession())?.accessToken;

  /// Authorization-code exchange used by the browser flow.
  Future<OAuthTokens?> _exchangeCode(
    String clientId,
    String secret,
    String code,
    String redirectUri,
    String? codeVerifier,
  ) async {
    try {
      final body = {
        'code': code,
        'client_id': clientId,
        'client_secret': secret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        if (codeVerifier != null && codeVerifier.trim().isNotEmpty)
          'code_verifier': codeVerifier,
      };
      final res = await _dio
          .postUri<String>(
            Uri.parse('https://oauth2.googleapis.com/token'),
            data: body,
            options: Options(contentType: Headers.formUrlEncodedContentType),
          )
          .timeout(const Duration(seconds: 30));
      return parseTokens(res.data ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Waits for the loopback authorization-code callback; null on
  /// deny/timeout/cancel.
  Future<String?> _awaitLoopbackCode(
    HttpServer server,
    String expectedState,
    bool Function() cancelled,
  ) async {
    final deadline = DateTime.now().add(maxPollDuration);
    // The server stream can only be listened to once, so keep a
    // single subscription and buffer requests in a queue. The old
    // poll used `server.first.timeout(...)` per iteration, but the
    // 1s timeout left that subscription dangling, so the second
    // poll threw "Stream was already listened to", the loop gave
    // up and closed the server about a second in — and Google's
    // redirect then failed to connect to the callback server.
    final queue = <HttpRequest>[];
    var wake = Completer<void>.sync();
    var closed = false;
    final sub = server.listen(
      (r) {
        queue.add(r);
        if (!wake.isCompleted) wake.complete();
      },
      onError: (_) {},
      onDone: () {
        closed = true;
        if (!wake.isCompleted) wake.complete();
      },
    );
    try {
      while (DateTime.now().isBefore(deadline) && !cancelled() && !closed) {
        if (queue.isEmpty) {
          // Wait up to a second for a request, so the deadline and
          // cancellation are re-checked regularly.
          final timer = Timer(const Duration(seconds: 1), () {
            if (!wake.isCompleted) wake.complete();
          });
          await wake.future;
          timer.cancel();
          if (queue.isEmpty) {
            // Woken by the timer (or the server closing) with no
            // request: reset the signal and re-check the guards.
            wake = Completer<void>.sync();
            continue;
          }
        }
        final request = queue.removeAt(0);
        // Reset the wake signal so the next wait blocks until a
        // fresh request arrives (a queued one skips the wait).
        if (queue.isEmpty) {
          wake = Completer<void>.sync();
        }
        try {
          final uri = request.uri;
          if (uri.path != '/callback') {
            await _respond(request, 404, 'Not found.');
            continue;
          }
          final params = uri.queryParameters;
          if (params['error'] != null) {
            await _respond(
              request,
              200,
              'Sign-in denied. You can close this tab and return to '
              'NixieTube.',
            );
            return null;
          }
          if (params['state'] != expectedState) {
            await _respond(request, 400, 'State mismatch; ignoring.');
            continue;
          }
          final code = params['code'];
          if (code == null || code.trim().isEmpty) {
            await _respond(request, 400, 'Missing code.');
            continue;
          }
          await _respond(
            request,
            200,
            'Signed in! You can close this tab and return to NixieTube.',
          );
          return code;
        } catch (_) {
          // Fall through; keep waiting unless timed out.
        }
      }
    } finally {
      await sub.cancel();
    }
    return null;
  }

  /// Sends a minimal HTML response to one loopback connection.
  Future<void> _respond(HttpRequest request, int status, String message) async {
    final body =
        '<html><body style="font-family:sans-serif">$message</body></html>';
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.html;
    request.response.write(body);
    await request.response.close();
  }

  /// Refreshes the access token, preserving the old refresh token when the
  /// response omits one.
  Future<OAuthTokens?> refresh(String clientId, OAuthTokens tokens) async {
    final secret = _config.googleClientSecret;
    if (secret.trim().isEmpty) return null;
    try {
      final res = await _dio
          .postUri<String>(
            Uri.parse('https://oauth2.googleapis.com/token'),
            data: {
              'refresh_token': tokens.refreshToken,
              'client_id': clientId,
              'client_secret': secret,
              'grant_type': 'refresh_token',
            },
            options: Options(contentType: Headers.formUrlEncodedContentType),
          )
          .timeout(const Duration(seconds: 30));
      final fresh = parseTokens(res.data ?? '');
      if (fresh == null) return null;
      final merged = fresh.refreshToken.trim().isEmpty
          ? OAuthTokens(
              fresh.accessToken,
              tokens.refreshToken,
              fresh.expiresAtSec,
            )
          : fresh;
      _saveTokens(clientId, merged);
      return merged;
    } catch (_) {
      return null;
    }
  }

  /// Parses an OAuth token JSON response into [OAuthTokens].
  OAuthTokens? parseTokens(String text) {
    try {
      final obj = jsonDecode(text);
      if (obj is! Map) return null;
      final access = obj['access_token'];
      if (access is! String || access.isEmpty) return null;
      final refresh = obj['refresh_token'] is String
          ? obj['refresh_token'] as String
          : '';
      var expiresIn = 3600;
      final rawExpiry = obj['expires_in'];
      if (rawExpiry is num) {
        expiresIn = rawExpiry.toInt();
      } else if (rawExpiry is String) {
        expiresIn = int.tryParse(rawExpiry) ?? 3600;
      }
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return OAuthTokens(access, refresh, now + expiresIn);
    } catch (_) {
      return null;
    }
  }

  /// Writes tokens to the properties-backed token store.
  void _saveTokens(String clientId, OAuthTokens tokens) {
    writeProperties(File(_storePath), {
      'client_id': clientId,
      'access_token': tokens.accessToken,
      'refresh_token': tokens.refreshToken,
      'expires_at': '${tokens.expiresAtSec}',
    });
  }

  /// Reads the stored client id and tokens, or null when absent.
  (String, OAuthTokens)? _loadTokens() {
    final file = File(_storePath);
    if (!file.existsSync()) return null;
    try {
      final p = readProperties(file);
      final clientId = p['client_id'] ?? '';
      final access = p['access_token'] ?? '';
      final refresh = p['refresh_token'] ?? '';
      final expires = int.tryParse(p['expires_at'] ?? '') ?? 0;
      if (clientId.trim().isEmpty || access.trim().isEmpty) return null;
      return (clientId, OAuthTokens(access, refresh, expires));
    } catch (_) {
      return null;
    }
  }
}

bool _neverCancelled() => false;
