// Dio resilience tests: the retry interceptor spends its budget on
// transient statuses and transport blips, treats verdicts as final,
// and lets a server `Retry-After` hint only lengthen the wait. A
// scripted adapter counts wire attempts, so nothing touches the network.

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/http_client.dart';

/// Adapter that answers each attempt from [reply] and counts attempts.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  final ResponseBody Function(RequestOptions options, int attempt) reply;
  int attempts = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => reply(options, ++attempts);

  @override
  void close({bool force = false}) {}
}

ResponseBody _status(int code, {String body = '', String? retryAfter}) =>
    ResponseBody.fromString(
      body,
      code,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
        if (retryAfter != null) 'retry-after': [retryAfter],
      },
    );

/// Retries with waits shrunk to nothing, so the ladder is exercised
/// without waiting it out.
const _quick = RetryPolicy(
  maxAttempts: 3,
  baseDelay: Duration(milliseconds: 1),
  maxDelay: Duration(milliseconds: 2),
);

Dio _client(HttpClientAdapter adapter, {RetryPolicy policy = _quick}) {
  final dio = newResilientClient(policy: policy);
  dio.httpClientAdapter = adapter;
  addTearDown(dio.close);
  return dio;
}

void main() {
  test('a throttled reply is retried until it succeeds', () async {
    final adapter = _ScriptedAdapter(
      (_, attempt) => attempt < 3 ? _status(429) : _status(200, body: 'ok'),
    );
    final res = await _client(adapter).get<String>('https://x/cover.jpg');
    expect(res.statusCode, 200);
    expect(res.data, 'ok');
    expect(adapter.attempts, 3);
  });

  test('5xx replies are retried, then surface as a response', () async {
    final adapter = _ScriptedAdapter((_, _) => _status(503));
    final res = await _client(
      adapter,
      policy: const RetryPolicy(
        maxAttempts: 2,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    ).get<String>('https://x/cover.jpg');
    // `validateStatus` accepts every status, so a spent budget hands
    // the throttled response to the caller instead of throwing.
    expect(res.statusCode, 503);
    expect(adapter.attempts, 2);
  });

  test('a 404 verdict is never retried', () async {
    final adapter = _ScriptedAdapter((_, _) => _status(404));
    final res = await _client(adapter).get<String>('https://x/missing.jpg');
    expect(res.statusCode, 404);
    expect(adapter.attempts, 1);
  });

  test('transport blips are retried, then surface', () async {
    final adapter = _ScriptedAdapter(
      (options, _) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );
    await expectLater(
      _client(adapter).get<String>('https://x/cover.jpg'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.attempts, 3);
  });

  test('a foreign-options DioException cannot restart the ladder', () async {
    // Some adapters synthesize an exception around their own
    // `RequestOptions`, which carries no attempt counter. The ladder
    // must still terminate instead of storming the network.
    final adapter = _ScriptedAdapter(
      (_, _) => throw DioException(
        requestOptions: RequestOptions(path: 'https://foreign/'),
        type: DioExceptionType.connectionError,
      ),
    );
    await expectLater(
      _client(adapter).get<String>('https://x/cover.jpg'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.attempts, lessThanOrEqualTo(4));
  });

  test('a Retry-After hint can only lengthen the wait', () async {
    final adapter = _ScriptedAdapter(
      (_, attempt) => attempt == 1
          ? _status(429, retryAfter: '1')
          : _status(200, body: 'ok'),
    );
    final watch = Stopwatch()..start();
    final res = await _client(adapter).get<String>('https://x/cover.jpg');
    watch.stop();
    expect(res.statusCode, 200);
    expect(adapter.attempts, 2);
    // The hurry-up backoff (about 0ms here) yields to the server's ask.
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(900));
  });
}
