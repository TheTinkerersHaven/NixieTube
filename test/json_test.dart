// Unit tests for decodeJsonResponse: small bodies decode inline,
// large bodies offload to a worker isolate with identical results.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/core/innertube/json.dart';

void main() {
  group('decodeJsonResponse', () {
    test('small payload decodes inline', () async {
      const body = '{"a": 1, "b": [true, "x"]}';
      expect(body.length, lessThan(isolateJsonThreshold));
      final decoded = await decodeJsonResponse(body);
      expect(decoded, {
        'a': 1,
        'b': [true, 'x'],
      });
    });

    test('large payload decodes on isolate identically', () async {
      final items = List.generate(
        4000,
        (i) => {'id': 'v$i', 'title': 'Song number $i' * 4},
      );
      final body = jsonEncode({'items': items});
      expect(body.length, greaterThanOrEqualTo(isolateJsonThreshold));
      final decoded = await decodeJsonResponse(body);
      expect(decoded['items'], hasLength(4000));
      expect(decoded['items'][3999]['id'], 'v3999');
      expect(decoded['items'][0]['title'], contains('Song number 0'));
    });
  });
}
