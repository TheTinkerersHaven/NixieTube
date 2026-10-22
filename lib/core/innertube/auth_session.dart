// Auth sessions for InnerTube requests, ported from Kotlin `AuthSession`.
//
// Anonymous by default; a cookie session (cookie + derived `SAPISIDHASH`)
// unlocks the library, likes and playlists. Timestamps are fresh per
// derivation — never replayed from storage.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Origin mixed into the `SAPISIDHASH` digest, mirroring the web client.
const sapisidOrigin = 'https://music.youtube.com';

/// Credentials attached to InnerTube requests. All-null is anonymous.
class AuthSession {
  const AuthSession({
    this.cookie,
    this.sapisidHash,
    this.accessToken,
    this.sessionToken,
  });

  /// Anonymous session: no credentials attached.
  const AuthSession.anonymous()
    : cookie = null,
      sapisidHash = null,
      accessToken = null,
      sessionToken = null;

  /// Raw `Cookie` header value for cookie sessions.
  final String? cookie;

  /// Derived `SAPISIDHASH` Authorization value (`"<ts>_<sha1>"`).
  final String? sapisidHash;

  /// Bearer token, if any.
  final String? accessToken;

  /// `XSRF-TOKEN` page token for stats beacons (listening history).
  final String? sessionToken;

  /// True when no credential of any kind is present.
  bool get isAnonymous =>
      (cookie == null || cookie!.isEmpty) &&
      (sapisidHash == null || sapisidHash!.isEmpty) &&
      (accessToken == null || accessToken!.isEmpty);

  /// Current Unix time in seconds (SAPISIDHASH timestamp).
  static int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Derives a cookie session (with fresh `SAPISIDHASH`) from a pasted
  /// Cookie header, so users copy ONE DevTools field. Prefers
  /// `__Secure-3PAPISID` (what YouTube checks over HTTPS), falls back to
  /// plain `SAPISID`. Returns null when no SAPISID value is present.
  static AuthSession? fromCookie(
    String rawCookie, {
    String origin = sapisidOrigin,
  }) {
    // DevTools "pretty" headers view wraps long values; a Cookie header
    // never legitimately contains whitespace.
    final cookie = rawCookie.replaceAll(RegExp(r'\s+'), '');
    final sapisid =
        _cookieValue(cookie, '__Secure-3PAPISID') ??
        _cookieValue(cookie, 'SAPISID');
    final clean = sapisid?.trim().replaceAll('"', '');
    if (clean == null || clean.isEmpty) return null;
    final timestamp = _nowSecs();
    return AuthSession(
      cookie: cookie,
      sapisidHash:
          '${timestamp}_${deriveSapisidHash(timestamp, clean, origin)}',
    );
  }

  /// Extracts one cookie value by name from a `;`-joined header.
  static String? _cookieValue(String cookie, String name) {
    for (final pair in cookie.split(';')) {
      final idx = pair.indexOf('=');
      if (idx < 0) continue;
      if (pair.substring(0, idx).trim() == name) {
        final v = pair.substring(idx + 1).trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// `"<timestamp>_<sha1(timestamp + ' ' + sapisid + ' ' + origin)>"`,
  /// without the timestamp prefix (see [fromCookie]).
  static String deriveSapisidHash(
    int timestamp,
    String sapisid, [
    String origin = sapisidOrigin,
  ]) {
    final digest = sha1.convert(utf8.encode('$timestamp $sapisid $origin'));
    return digest.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is AuthSession &&
      other.cookie == cookie &&
      other.sapisidHash == sapisidHash &&
      other.accessToken == accessToken &&
      other.sessionToken == sessionToken;

  @override
  int get hashCode =>
      Object.hash(cookie, sapisidHash, accessToken, sessionToken);
}

/// Validates pasted cookie text for the login flow, returning a
/// user-facing reason when it cannot yield a session.
String? validateCookie(String rawCookie) {
  if (rawCookie.contains('…') || rawCookie.contains('...')) {
    return 'The pasted cookie looks TRUNCATED (it contains \'…\'). '
        'In DevTools, click \'view source\' next to Request Headers and copy '
        'the full Cookie line, the pretty view cuts long values off.';
  }
  if (AuthSession.fromCookie(rawCookie) == null) {
    final names = <String>[];
    for (final pair in rawCookie.split(';')) {
      final idx = pair.indexOf('=');
      if (idx >= 0) {
        final k = pair.substring(0, idx).trim();
        if (k.isNotEmpty && !names.contains(k)) {
          names.add(k);
          if (names.length >= 12) break;
        }
      }
    }
    if (names.isEmpty) {
      return 'The pasted text contains no cookies at all. '
          'Copy the whole \'Cookie\' header value.';
    }
    return 'Found cookies: ${names.join(', ')}. '
        'None is __Secure-3PAPISID/SAPISID. '
        'Copy the Cookie header of a music.youtube.com request while logged in.';
  }
  return null;
}
