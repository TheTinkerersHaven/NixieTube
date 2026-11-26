// Which integrations a build can use. The predicates are pure so the
// desktop/phone split is testable without running on the platform.

import 'package:flutter_test/flutter_test.dart';

import 'package:nixietube/sys/platform_features.dart';

void main() {
  test('desktop sessions have a window, a tray and local sockets', () {
    for (final p in [
      AppPlatform.linux,
      AppPlatform.windows,
      AppPlatform.macOS,
    ]) {
      expect(isDesktop(p), isTrue, reason: '$p');
      expect(supportsTray(p), isTrue, reason: '$p');
      expect(supportsEmbeddedLogin(p), isTrue, reason: '$p');
      expect(supportsDiscordRpc(p), isTrue, reason: '$p');
      expect(supportsBackgroundAudio(p), isFalse, reason: '$p');
    }
  });

  test('phones have no desktop session, tray or Discord socket', () {
    for (final p in [AppPlatform.android, AppPlatform.ios]) {
      expect(isDesktop(p), isFalse, reason: '$p');
      expect(supportsTray(p), isFalse, reason: '$p');
      expect(supportsDiscordRpc(p), isFalse, reason: '$p');
      // ...but they do need the OS media session to keep playing.
      expect(supportsBackgroundAudio(p), isTrue, reason: '$p');
    }
    // The Social SDK ships an AAR for Android; presence goes through the
    // installed Discord app's RPC service there.
    expect(supportsDiscordSocialSdk(AppPlatform.android), isTrue);
    for (final p in [
      AppPlatform.ios,
      AppPlatform.linux,
      AppPlatform.windows,
      AppPlatform.macOS,
      AppPlatform.other,
    ]) {
      expect(supportsDiscordSocialSdk(p), isFalse, reason: '$p');
    }
  });

  test('an in-app sign-in page runs on desktop and Android only', () {
    // iOS has neither a WebKit window nor a cookie store the app can
    // read, so it stays on the cookie paste.
    for (final p in [
      AppPlatform.linux,
      AppPlatform.windows,
      AppPlatform.macOS,
      AppPlatform.android,
    ]) {
      expect(supportsEmbeddedLogin(p), isTrue, reason: '$p');
    }
    expect(supportsEmbeddedLogin(AppPlatform.ios), isFalse);
    expect(supportsEmbeddedLogin(AppPlatform.other), isFalse);
  });

  test('MPRIS is the Linux session bus and nothing else', () {
    expect(supportsMpris(AppPlatform.linux), isTrue);
    for (final p in [
      AppPlatform.windows,
      AppPlatform.macOS,
      AppPlatform.android,
      AppPlatform.ios,
      AppPlatform.other,
    ]) {
      expect(supportsMpris(p), isFalse, reason: '$p');
    }
  });
}
