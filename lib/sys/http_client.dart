// Shared Dio factories for every network client in the app.
//
// [newHttpClient] preserves `package:http` semantics so each call site
// keeps its own status-code checks unchanged:
//   - `validateStatus` accepts every status, so error bodies (401,
//     404, 429, 5xx) land as normal responses instead of throwing
//     `DioException`; only transport failures throw.
//   - `responseType` is plain text, so `response.data` is the body
//     string (`Response.body` parity). Callers needing bytes
//     (artwork downloads) override it per request.
//
// [newResilientClient] keeps those semantics and adds Dio's own
// resilience machinery for the app's read-heavy traffic: a retry
// interceptor for transient failures and a per-host connection cap.
// Retrying lives there — never in [newHttpClient] — so injected test
// clients keep their scripted behaviour and schedule no timers.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// A fresh Dio with the app-wide HTTP semantics.
Dio newHttpClient() => Dio(
  BaseOptions(validateStatus: (_) => true, responseType: ResponseType.plain),
);

/// Retry budget for [newResilientClient]: how many tries a transient
/// failure is worth and how long to wait between them.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.baseDelay = const Duration(milliseconds: 400),
    this.maxDelay = const Duration(seconds: 10),
    this.maxRetryAfter = const Duration(seconds: 20),
  });

  /// Tries per request, the first one included.
  final int maxAttempts;

  /// First backoff step; it doubles every attempt.
  final Duration baseDelay;

  /// Ceiling for a single backoff wait.
  final Duration maxDelay;

  /// Ceiling honoured for a server `Retry-After` hint.
  final Duration maxRetryAfter;
}

/// A Dio for the app's read-heavy traffic (cover downloads, InnerTube
/// posts): [newHttpClient]'s semantics plus Dio's own resilience.
///
///   - A retry interceptor re-fires requests that failed transiently.
///     Transport errors arrive in `onError`; `429`/`5xx` replies arrive
///     in `onResponse`, where they land as ordinary responses because
///     `validateStatus` accepts every status. Any other status (401,
///     403, 404, 400 …) is a verdict and passes through untouched.
///     Backoff is exponential with jitter, and never shorter than a
///     server `Retry-After` hint.
///   - A per-host connection cap keeps a screen full of covers from
///     opening one socket per tile, which is what invites throttling.
Dio newResilientClient({
  RetryPolicy policy = const RetryPolicy(),
  int maxConnectionsPerHost = 8,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration receiveTimeout = const Duration(seconds: 30),
}) {
  final dio = Dio(
    BaseOptions(
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
    ),
  );
  dio.interceptors.add(_RetryInterceptor(dio, policy));
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..maxConnectionsPerHost = maxConnectionsPerHost
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 15),
  );
  return dio;
}

/// Spends up to [RetryPolicy.maxAttempts] tries on transient failures
/// by re-firing the very same [RequestOptions].
class _RetryInterceptor extends Interceptor {
  _RetryInterceptor(this._dio, this._policy);

  final Dio _dio;
  final RetryPolicy _policy;
  final Random _random = Random();

  /// Attempt counter carried on the request across re-fires.
  static const _attemptKey = 'nt_retry_attempt';

  /// Re-fires currently in flight. A `DioException` that carries a
  /// *foreign* `RequestOptions` (some adapters synthesize their own)
  /// would otherwise restart the ladder from zero every time and storm
  /// the network; this caps the nesting no matter what the request
  /// options say, and bounds the work a burst of failures can schedule.
  int _inflight = 0;

  /// `429` (throttled) and `5xx` (server-side) are worth another try;
  /// no other status is.
  static bool _transientStatus(int? status) =>
      status == 429 || (status != null && status >= 500 && status <= 599);

  /// Transport-level failures worth another try. A cancelled request
  /// or a rejected certificate is not a blip.
  static bool _transientError(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.unknown => true,
    _ => false,
  };

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final retried =
        _transientStatus(response.statusCode) &&
        await _resend(
          handler.resolve,
          handler.reject,
          response.requestOptions,
          retryAfter: response.headers.value('retry-after'),
        );
    if (!retried) handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final retried =
        _transientError(err) &&
        await _resend(
          handler.resolve,
          handler.reject,
          err.requestOptions,
          retryAfter: err.response?.headers.value('retry-after'),
        );
    if (!retried) handler.next(err);
  }

  /// Spends one retry on [options] and hands the reply to [resolve] or
  /// [reject]; returns false once the budget is spent, leaving the
  /// caller to forward its own outcome. The re-fire re-enters this
  /// interceptor — the counter rides on [RequestOptions.extra] — so the
  /// recursion stops at [RetryPolicy.maxAttempts].
  Future<bool> _resend(
    void Function(Response<dynamic>) resolve,
    void Function(DioException) reject,
    RequestOptions options, {
    String? retryAfter,
  }) async {
    final attempt = (options.extra[_attemptKey] as int?) ?? 0;
    if (attempt + 1 >= _policy.maxAttempts ||
        _inflight >= _policy.maxAttempts) {
      return false;
    }
    options.extra[_attemptKey] = attempt + 1;
    _inflight++;
    try {
      await Future<void>.delayed(_backoff(attempt, retryAfter));
      resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (e) {
      reject(e);
    } catch (e) {
      reject(DioException(requestOptions: options, error: e));
    } finally {
      _inflight--;
    }
    return true;
  }

  /// Exponential backoff with jitter, never shorter than a server
  /// `Retry-After` hint.
  Duration _backoff(int attempt, String? retryAfter) {
    final step = _policy.baseDelay.inMilliseconds * (1 << attempt);
    final capped = min(step, _policy.maxDelay.inMilliseconds);
    // Half the step is fixed and half jittered: a burst of retries
    // spreads out instead of marching back in lockstep.
    final jittered = capped ~/ 2 + _random.nextInt(capped ~/ 2 + 1);
    final hinted = _retryAfter(retryAfter)?.inMilliseconds;
    return Duration(
      milliseconds: hinted == null ? jittered : max(jittered, hinted),
    );
  }

  /// `Retry-After` in seconds or as an HTTP date, clamped to
  /// [RetryPolicy.maxRetryAfter]; null when absent or unparseable.
  Duration? _retryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(
        seconds: seconds.clamp(0, _policy.maxRetryAfter.inSeconds),
      );
    }
    try {
      final delta = HttpDate.parse(value.trim()).difference(DateTime.now());
      if (delta.isNegative) return Duration.zero;
      return delta.compareTo(_policy.maxRetryAfter) > 0
          ? _policy.maxRetryAfter
          : delta;
    } catch (_) {
      return null;
    }
  }
}
