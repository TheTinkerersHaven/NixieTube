// Shared Dio factory for every network client in the app.
//
// The options preserve `package:http` semantics so each call site
// keeps its own status-code checks unchanged:
//   - `validateStatus` accepts every status, so error bodies (401,
//     404, 429, 5xx) land as normal responses instead of throwing
//     `DioException`; only transport failures throw.
//   - `responseType` is plain text, so `response.data` is the body
//     string (`Response.body` parity). Callers needing bytes
//     (artwork downloads) override it per request.

import 'package:dio/dio.dart';

/// A fresh Dio with the app-wide HTTP semantics.
Dio newHttpClient() => Dio(
  BaseOptions(
    validateStatus: (_) => true,
    responseType: ResponseType.plain,
  ),
);
