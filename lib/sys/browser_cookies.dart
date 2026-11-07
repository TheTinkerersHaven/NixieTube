// Pure helpers for handling YouTube cookies: domain filtering, session
// detection and Cookie-header assembly. Used by the integrated browser
// login and the manual cookie-paste flow.
//
// No browser launching or cookie-store reading happens here.

/// Domains whose cookies make up a YouTube session.
bool isYouTubeDomain(String domain) {
  var d = domain.trim().toLowerCase();
  if (d.startsWith('.')) d = d.substring(1);
  if (d.isEmpty) return false;
  const bases = ['youtube.com', 'music.youtube.com'];
  for (final base in bases) {
    if (d == base || d.endsWith('.$base')) return true;
  }
  return false;
}

/// Helpers for assembling and validating a YouTube cookie payload.
class BrowserCookies {
  BrowserCookies._();

  /// True when [cookies] carry a signed-in YouTube session (a SAPISID
  /// value), as opposed to anonymous visitor cookies. Pure.
  static bool hasSignedInSession(List<dynamic> cookies) {
    for (final c in cookies) {
      if (c is! Map) continue;
      final domain = c['domain'];
      final name = c['name'];
      final value = c['value'];
      if (domain is! String ||
          name is! String ||
          value is! String ||
          !isYouTubeDomain(domain)) {
        continue;
      }
      final n = name.trim();
      if ((n == 'SAPISID' || n == '__Secure-3PAPISID') &&
          value.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Assembles a `Cookie` header from cookie objects, keeping only
  /// YouTube-session domains. Duplicate names are collapsed to the first
  /// value seen so the header never carries two values for one cookie.
  /// Null when none are present.
  static String? buildYouTubeHeader(List<dynamic> cookies) {
    final byName = <String, String>{};
    for (final c in cookies) {
      if (c is! Map) continue;
      final domain = c['domain'];
      final name = c['name'];
      final value = c['value'];
      if (domain is! String ||
          name is! String ||
          value is! String ||
          !isYouTubeDomain(domain)) {
        continue;
      }
      final n = name.trim();
      final v = value.trim();
      if (n.isEmpty || v.isEmpty || byName.containsKey(n)) continue;
      byName[n] = v;
    }
    if (byName.isEmpty) return null;
    return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}