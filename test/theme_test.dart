// Theme resolution tests: the default settings keep the
// hand-tuned built-in scheme exactly (resolveColorScheme
// returns null), while system/seed/override combinations
// build the expected scheme; config keys round-trip on disk.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nixietube/sys/sys_config.dart';
import 'package:nixietube/ui/theme.dart';

void main() {
  group('resolveColorScheme', () {
    test('defaults resolve to null (built-in scheme kept)', () {
      expect(
        resolveColorScheme(
          source: ThemeSource.custom,
          seedColor: defaultSeedColor,
        ),
        isNull,
      );
      expect(
        resolveColorScheme(
          source: ThemeSource.system,
          seedColor: defaultSeedColor,
        ),
        isNull,
      );
    });

    test('custom non-default seed builds a dark seed scheme', () {
      final scheme = resolveColorScheme(
        source: ThemeSource.custom,
        seedColor: 0xff2196f3,
      );
      expect(scheme, isNotNull);
      expect(scheme!.brightness, Brightness.dark);
      expect(scheme.primary, isNot(const Color(0xffffb3b3)));
    });

    test('system source without platform colors keeps built-in', () {
      expect(
        resolveColorScheme(
          source: ThemeSource.system,
          seedColor: 0xff2196f3,
          systemDark: null,
        ),
        isNull,
      );
    });

    test('system source with platform colors uses them as-is', () {
      const systemScheme = ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xff9e9e9e),
        onPrimary: Color(0xff000000),
        primaryContainer: Color(0xff111111),
        onPrimaryContainer: Color(0xffffffff),
        secondary: Color(0xff8e8e8e),
        onSecondary: Color(0xff000000),
        tertiary: Color(0xff7e7e7e),
        onTertiary: Color(0xff000000),
        error: Color(0xffff0000),
        onError: Color(0xff000000),
        surface: Color(0xff101010),
        onSurface: Color(0xffffffff),
        surfaceContainerHighest: Color(0xff202020),
        surfaceContainerHigh: Color(0xff1a1a1a),
        surfaceContainer: Color(0xff141414),
        onSurfaceVariant: Color(0xffeeeeee),
        outline: Color(0xff555555),
        outlineVariant: Color(0xff333333),
      );
      expect(
        resolveColorScheme(
          source: ThemeSource.system,
          seedColor: defaultSeedColor,
          systemDark: systemScheme,
        ),
        same(systemScheme),
      );
    });

    test('overrides apply on top of the built-in base', () {
      final scheme = resolveColorScheme(
        source: ThemeSource.custom,
        seedColor: defaultSeedColor,
        primaryOverride: 0xff2196f3,
      );
      expect(scheme, isNotNull);
      expect(scheme!.primary, const Color(0xff2196f3));
      // Untouched roles keep the hand-tuned values.
      expect(scheme.surface, const Color(0xff131314));
      expect(scheme.secondary, const Color(0xffe7bdb7));
    });

    test('overrides apply on top of system and seed schemes', () {
      const seededSystem = ColorScheme.dark(primary: Color(0xff9e9e9e));
      final onDynamic = resolveColorScheme(
        source: ThemeSource.system,
        seedColor: defaultSeedColor,
        systemDark: seededSystem,
        surfaceOverride: 0xff000000,
      );
      expect(onDynamic, isNotNull);
      expect(onDynamic!.surface, const Color(0xff000000));
      expect(onDynamic.primary, seededSystem.primary);

      final onSeed = resolveColorScheme(
        source: ThemeSource.custom,
        seedColor: 0xff4caf50,
        tertiaryOverride: 0xffe91e63,
      );
      expect(onSeed, isNotNull);
      expect(onSeed!.tertiary, const Color(0xffe91e63));
    });

    test('unknown source keys fall back to custom', () {
      expect(ThemeSource.fromKey('system'), ThemeSource.system);
      expect(ThemeSource.fromKey('custom'), ThemeSource.custom);
      expect(ThemeSource.fromKey('neon'), ThemeSource.custom);
      expect(ThemeSource.fromKey(''), ThemeSource.custom);
    });
  });

  group('buildTheme', () {
    test('default keeps the built-in look exactly', () {
      final theme = buildTheme();
      expect(theme.colorScheme.primary, const Color(0xffffb3b3));
      expect(theme.colorScheme.surface, const Color(0xff131314));
      expect(theme.scaffoldBackgroundColor, const Color(0xff0b0b0c));
    });

    test('custom scheme drives the scheme and the backdrop', () {
      const scheme = ColorScheme.dark(primary: Color(0xff2196f3));
      final theme = buildTheme(scheme: scheme);
      expect(theme.colorScheme.primary, const Color(0xff2196f3));
      expect(theme.scaffoldBackgroundColor, scheme.surface);
    });
  });

  group('theme config', () {
    test('defaults keep the built-in look', () {
      final dir = Directory.systemTemp.createTempSync('nt-theme-config');
      addTearDown(() => dir.deleteSync(recursive: true));
      final config = SysConfig(configPath: '${dir.path}/config.properties');
      expect(config.themeSource, 'custom');
      expect(config.themeSeedColor, 0xffff0000);
      expect(config.themePrimaryOverride, isNull);
      expect(config.themeSecondaryOverride, isNull);
      expect(config.themeTertiaryOverride, isNull);
      expect(config.themeSurfaceOverride, isNull);
    });

    test('source, seed and overrides persist and reload', () {
      final dir = Directory.systemTemp.createTempSync('nt-theme-config');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/config.properties';
      final config = SysConfig(configPath: path);
      config.themeSource = 'system';
      config.themeSeedColor = 0xff2196f3;
      config.themePrimaryOverride = 0xffe91e63;
      config.themeSurfaceOverride = 0xff000000;
      final reloaded = SysConfig(configPath: path);
      expect(reloaded.themeSource, 'system');
      expect(reloaded.themeSeedColor, 0xff2196f3);
      expect(reloaded.themePrimaryOverride, 0xffe91e63);
      expect(reloaded.themeSecondaryOverride, isNull);
      expect(reloaded.themeSurfaceOverride, 0xff000000);
    });

    test('clearing an override removes the key', () {
      final dir = Directory.systemTemp.createTempSync('nt-theme-config');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/config.properties';
      final config = SysConfig(configPath: path);
      config.themePrimaryOverride = 0xffe91e63;
      expect(config.themePrimaryOverride, 0xffe91e63);
      config.themePrimaryOverride = null;
      expect(config.themePrimaryOverride, isNull);
      expect(SysConfig(configPath: path).themePrimaryOverride, isNull);
    });

    test('corrupt values fall back safely', () {
      final dir = Directory.systemTemp.createTempSync('nt-theme-config');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/config.properties';
      final config = SysConfig(configPath: path);
      config.set('theme.seedColor', 'not-a-color');
      config.set('theme.primary', 'xyz');
      expect(config.themeSeedColor, 0xffff0000);
      expect(config.themePrimaryOverride, isNull);
    });
  });
}
