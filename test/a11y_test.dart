// Accessibility settings: config persistence and the
// high-contrast theme divergence.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/theme.dart';
import 'package:nixietube/ui/widgets/palette_backdrop.dart';

void main() {
  group('SysConfig a11y', () {
    test(
      'high contrast and reduced motion default off and round-trip',
      () async {
        final dir = await Directory.systemTemp.createTemp('nt-a11y-cfg');
        addTearDown(() => dir.delete(recursive: true));
        final config = SysConfig(configPath: '${dir.path}/config.properties');
        expect(config.highContrast, isFalse);
        expect(config.reducedMotion, isFalse);
        config.highContrast = true;
        config.reducedMotion = true;
        final again = SysConfig(configPath: '${dir.path}/config.properties');
        expect(again.highContrast, isTrue);
        expect(again.reducedMotion, isTrue);
      },
    );
  });

  group('high contrast theme', () {
    test('brightens text and borders, separates surface tiers', () {
      final base = buildTheme().colorScheme;
      final hc = buildTheme(highContrast: true).colorScheme;
      // Text and border colors gain luminance.
      expect(luminance(hc.onSurface), greaterThan(luminance(base.onSurface)));
      expect(
        luminance(hc.onSurfaceVariant),
        greaterThan(luminance(base.onSurfaceVariant)),
      );
      expect(luminance(hc.outline), greaterThan(luminance(base.outline)));
      expect(
        luminance(hc.outlineVariant),
        greaterThan(luminance(base.outlineVariant)),
      );
      // Surface tiers become more distinct (each step lighter).
      expect(hc.surfaceContainerHigh, isNot(base.surfaceContainerHigh));
      expect(hc.surfaceContainerHighest, isNot(base.surfaceContainerHighest));
      expect(
        luminance(hc.surfaceContainerHighest),
        greaterThan(luminance(hc.surfaceContainer)),
      );
      // The base surface is unchanged — only foreground and steps move.
      expect(hc.surface, base.surface);
    });
  });
}
