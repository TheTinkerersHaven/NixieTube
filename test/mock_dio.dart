// Scripted Dio for tests: answers every request through [onRequest]
// without touching the network, delivering the returned
// `(statusCode, data)` as the response. Mirrors
// `package:http/testing.dart`'s MockClient for Dio.
//
// The Dio keeps the app-wide options (`validateStatus` accepts
// every status), so error statuses land as normal responses.
// [RequestOptions] exposes the outgoing request: `uri`, `method`
// (`GET`/`POST`/`PUT`/`DELETE`), `headers`, and `data` (the JSON
// string for JSON posts, the field map for form posts).

import 'package:dio/dio.dart';

import 'package:nixietube/sys/http_client.dart';

/// A Dio whose requests are answered by [onRequest].
Dio mockDio(Future<(int, Object)> Function(RequestOptions options) onRequest) {
  final dio = newHttpClient();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final (status, data) = await onRequest(options);
        handler.resolve(
          Response(requestOptions: options, statusCode: status, data: data),
        );
      },
    ),
  );
  return dio;
}
