// Helpers for browser-cookie login: normalize cookie payloads
// ({domain, name, value} entries from any source) into flat entries,
// then reuse the shared YouTube-session builders.
// Pure functions so cookie handling stays unit-testable.

import 'browser_cookies.dart';

/// Flattens raw webview cookie payloads into `{domain, name, value}` maps,
/// tolerating both `{domain: {name: value}}` and `[{name, value,
/// domain}]` shapes (e.g. WebviewCookie lists). Entries without a name
/// are dropped; empty values survive here (the header builder filters them).
List<Map<String, String>> normalizeWebviewCookies(dynamic raw) {
  final out = <Map<String, String>>[];
  void add(Object? domain, Object? name, Object? value) {
    if (domain == null || name == null || value == null) return;
    final d = domain.toString();
    final n = name.toString();
    final v = value.toString();
    if (d.isEmpty || n.isEmpty) return;
    out.add({'domain': d, 'name': n, 'value': v});
  }

  if (raw is Map) {
    raw.forEach((domain, cookies) {
      if (cookies is Map) {
        cookies.forEach((name, value) {
          if (value is Map) {
            add(domain, value['name'] ?? name, value['value']);
          } else {
            add(domain, name, value);
          }
        });
      } else if (cookies is List) {
        for (final c in cookies) {
          if (c is Map) add(domain, c['name'], c['value']);
        }
      }
    });
  } else if (raw is List) {
    for (final c in raw) {
      if (c is Map) add(c['domain'], c['name'], c['value']);
    }
  }
  return out;
}

/// Parses a `document.cookie` string ("name1=val1; name2=val2") into
/// `{domain, name, value}` entries for [youTubeCookieHeader].
/// Pure function so the native window flow stays out of tests.
List<Map<String, String>> parseDocumentCookie(String cookieStr) {
  final out = <Map<String, String>>[];
  for (final part in cookieStr.split('; ')) {
    final eq = part.indexOf('=');
    if (eq > 0) {
      out.add({
        'domain': '.youtube.com',
        'name': part.substring(0, eq),
        'value': part.substring(eq + 1),
      });
    }
  }
  return out;
}

/// Builds the `Cookie` header from webview cookie payloads, or null when no
/// signed-in YouTube session is present.
String? youTubeCookieHeader(dynamic raw) {
  final cookies = normalizeWebviewCookies(raw);
  if (!BrowserCookies.hasSignedInSession(cookies)) return null;
  return BrowserCookies.buildYouTubeHeader(cookies);
}
