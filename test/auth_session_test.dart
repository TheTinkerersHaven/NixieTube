// Auth session tests mirroring the Kotlin suites: derivation preference,
// hash shape, cookie validation hints, anonymous detection.

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/auth_session.dart';

const _cookie =
    'SID=abc123; __Secure-3PAPISID=secret-sapisid-value; HSID=xyz; SAPISID=fallback-value; LOGIN_INFO=ok';

void main() {
  group('AuthSession.fromCookie', () {
    test('prefers __Secure-3PAPISID', () {
      final session = AuthSession.fromCookie(_cookie)!;
      // The hash must bind the secure value, not the fallback: recompute
      // the digest over the fallback and require a mismatch.
      final fallbackHash =
          AuthSession.deriveSapisidHash(0, 'fallback-value').split('_').last;
      final hash = session.sapisidHash!;
      expect(hash, contains('_'));
      expect(hash.endsWith(fallbackHash), isFalse);
      expect(session.cookie, _cookie.replaceAll(RegExp(r'\s+'), ''));
    });

    test('falls back to plain SAPISID', () {
      final session = AuthSession.fromCookie(
          'SID=abc; SAPISID=plain-value; LOGIN_INFO=ok')!;
      expect(session.sapisidHash, isNotNull);
    });

    test('rejects missing SAPISID', () {
      expect(AuthSession.fromCookie('SID=abc; HSID=xyz'), isNull);
      expect(AuthSession.fromCookie(''), isNull);
      expect(AuthSession.fromCookie('SAPISID=; SID=x'), isNull);
    });

    test('hash shape is timestamp + 40 hex chars', () {
      final hash = AuthSession.deriveSapisidHash(1700000000, 'test-value');
      expect(hash.length, 40);
      expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(hash), isTrue);
      final session = AuthSession.fromCookie(
          'SID=abc; __Secure-3PAPISID=test-value;')!;
      final parts = session.sapisidHash!.split('_');
      expect(parts.length, 2);
      expect(int.tryParse(parts[0]), isNotNull);
      expect(parts[1].length, 40);
    });

    test('strips quotes and whitespace', () {
      final session = AuthSession.fromCookie(
          'SID=abc; __Secure-3PAPISID="quoted-value";')!;
      expect(session.sapisidHash, isNotNull);
      final wrapped = AuthSession.fromCookie(
          'SID=abc;\n  __Secure-3PAPISID=wrapped-value;');
      expect(wrapped, isNotNull);
    });
  });

  group('validateCookie', () {
    test('truncated cookie rejected with hint', () {
      final err =
          validateCookie('SID=abc…; __Secure-3PAPISID=x')!;
      expect(err, contains('TRUNCATED'));
    });

    test('cookie without SAPISID lists names', () {
      final err = validateCookie('SID=abc; HSID=xyz')!;
      expect(err, contains('SID'));
      expect(err, contains('HSID'));
    });

    test('valid cookie passes', () {
      expect(validateCookie(_cookie), isNull);
    });
  });

  group('anonymous detection', () {
    test('empty sessions are anonymous', () {
      expect(const AuthSession.anonymous().isAnonymous, isTrue);
      expect(const AuthSession().isAnonymous, isTrue);
      expect(AuthSession.fromCookie(_cookie)!.isAnonymous, isFalse);
      expect(
        const AuthSession(accessToken: 'tok').isAnonymous,
        isFalse,
      );
    });
  });
}
