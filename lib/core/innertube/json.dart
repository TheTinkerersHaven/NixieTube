// JSON navigation helpers for InnerTube responses.
//
// Responses are decoded with `jsonDecode` into `Map<String, dynamic>` /
// `List<dynamic>` / primitives; every helper is null-tolerant.

import 'dart:convert';
import 'dart:isolate';

/// Response bodies at or above this size decode on a worker isolate so
/// multi-hundred-KB shelf/browse/track payloads never stall the UI
/// thread (home, search, 5000-track playlists). Smaller bodies decode
/// inline to avoid isolate spawn overhead.
const isolateJsonThreshold = 256 * 1024;

/// Decodes a JSON response body, offloading large payloads to a worker
/// isolate. The decoded maps/lists are plain JSON values either way.
Future<dynamic> decodeJsonResponse(String body) {
  if (body.length < isolateJsonThreshold) {
    return Future.value(jsonDecode(body));
  }
  return Isolate.run(() => jsonDecode(body));
}

/// Walks [node] through [keys] (`String` = object field, `int` = array
/// index), returning null on the first miss.
dynamic nav(dynamic node, List<Object> keys) {
  dynamic cur = node;
  for (final key in keys) {
    if (key is String) {
      if (cur is! Map) return null;
      cur = cur[key];
    } else if (key is int) {
      if (cur is! List) return null;
      final list = cur;
      if (key < 0 || key >= list.length) return null;
      cur = list[key];
    } else {
      return null;
    }
    if (cur == null) return null;
  }
  return cur;
}

/// The node itself when it is a JSON string, else null.
String? str(dynamic node) => node is String ? node : null;

/// Concatenated `text` of a runs array, or empty when absent.
String runsText(dynamic node) {
  if (node is! List) return '';
  final buf = StringBuffer();
  for (final run in node) {
    if (run is Map) {
      final t = str(run['text']);
      if (t != null) buf.write(t);
    }
  }
  return buf.toString();
}

/// Every value stored under [key], depth-first in document order.
List<dynamic> findAll(dynamic node, String key) {
  final out = <dynamic>[];
  void visit(dynamic el) {
    if (el is Map) {
      el.forEach((k, v) {
        if (k == key) out.add(v);
        visit(v);
      });
    } else if (el is List) {
      for (final v in el) {
        visit(v);
      }
    }
  }

  visit(node);
  return out;
}

/// First value stored under [key], depth-first, or null.
dynamic findFirst(dynamic node, String key) {
  final all = findAll(node, key);
  return all.isEmpty ? null : all.first;
}
