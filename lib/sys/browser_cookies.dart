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

/// One YouTube-session cookie as `name=value`.
typedef _CookiePair = ({String name, String value});

/// The YouTube-session cookies in [cookies] as trimmed pairs. Entries
/// that are not cookie maps, are on another domain, or carry no name or
/// value are skipped.
Iterable<_CookiePair> _youTubeCookies(List<dynamic> cookies) sync* {
  for (final c in cookies) {
    if (c is! Map) continue;
    final domain = c['domain'];
    final rawName = c['name'];
    final rawValue = c['value'];
    if (domain is! String ||
        rawName is! String ||
        rawValue is! String ||
        !isYouTubeDomain(domain)) {
      continue;
    }
    final name = rawName.trim();
    final value = rawValue.trim();
    if (name.isEmpty || value.isEmpty) continue;
    yield (name: name, value: value);
  }
}

/// Helpers for assembling and validating a YouTube cookie payload.
class BrowserCookies {
  BrowserCookies._();

  /// True when [cookies] carry a signed-in YouTube session (a SAPISID
  /// value), as opposed to anonymous visitor cookies. Pure.
  static bool hasSignedInSession(List<dynamic> cookies) {
    for (final c in _youTubeCookies(cookies)) {
      if ((c.name == 'SAPISID' || c.name == '__Secure-3PAPISID') &&
          c.value.isNotEmpty) {
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
    for (final c in _youTubeCookies(cookies)) {
      byName.putIfAbsent(c.name, () => c.value);
    }
    if (byName.isEmpty) return null;
    return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Builds the `Cookie` header from a cookie header *string*
  /// (`name=value; name2=value2`), or null when it carries no signed-in
  /// session.
  ///
  /// Android's `CookieManager.getCookie(url)` returns every cookie set
  /// for that URL in exactly this format — and, unlike `document.cookie`,
  /// it reads the store itself, so the HttpOnly session cookies
  /// (`SAPISID`, `__Secure-1PSID`, …) that YouTube authenticates with are
  /// included. All entries are attributed to `.youtube.com`, which is
  /// where the session cookies live.
  static String? youTubeHeaderFromCookieString(String? cookie) {
    if (cookie == null || cookie.trim().isEmpty) return null;
    final cookies = <Map<String, String>>[];
    for (final part in cookie.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      if (name.isEmpty) continue;
      cookies.add({
        'domain': '.youtube.com',
        'name': name,
        'value': part.substring(eq + 1).trim(),
      });
    }
    if (!hasSignedInSession(cookies)) return null;
    return buildYouTubeHeader(cookies);
  }
}
