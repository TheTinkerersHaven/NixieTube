// Material 3 theme ported from Kotlin `Theme.kt` + `Style.kt`.
//
// Only the dark scheme is applied (the Kotlin `App` hardcodes
// `YtmDarkScheme`); the light scheme is defined but unused there too.

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

/// Shared outer padding applied by every top-level screen.
const double screenPadding = 20.0;

/// Horizontal gutter for the artist detail page: a fixed inset on
/// both sides instead of a centering formula, so the hero text, rows
/// and rails all share one left edge.
const double gutter = 32.0;

/// Title style for artist names on the detail page: a slightly wider,
/// rounded cut of Google Sans Flex. Defined once so other title
/// surfaces can reuse the same axis settings.
TextStyle artistTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.displayMedium!.copyWith(
      fontVariations: const [
        FontVariation('wght', 700),
        FontVariation('opsz', 28),
        FontVariation('ROND', 60),
        FontVariation('wdth', 112.5),
      ],
    );

/// Small spacing scale used inside detail/panel layouts.
const double spaceXs = 4.0;
const double spaceSm = 8.0;
const double spaceMd = 16.0;
const double spaceLg = 24.0;
const double spaceXl = 32.0;

/// Even vertical spacing between home sections.
const double homeSectionSpacing = 20.0;

/// Material 3 Expressive corner scale (10 steps, dp). The three newest
/// steps (largeIncreased, extraLargeIncreased, extraExtraLarge) serve
/// the larger components (FAB menu, toolbars, expressive buttons).
class ExpressiveCorners {
  const ExpressiveCorners._();

  /// Perfectly square: 0dp.
  static const double none = 0.0;

  /// Extra small: 4dp.
  static const double extraSmall = 4.0;

  /// Small: 8dp.
  static const double small = 8.0;

  /// Medium: 12dp.
  static const double medium = 12.0;

  /// Large: 16dp.
  static const double large = 16.0;

  /// Large increased: 20dp.
  static const double largeIncreased = 20.0;

  /// Extra large: 28dp.
  static const double extraLarge = 28.0;

  /// Extra large increased: 32dp.
  static const double extraLargeIncreased = 32.0;

  /// Extra extra large: 48dp.
  static const double extraExtraLarge = 48.0;
}

/// Default corner radius for cards and artwork tiles (Expressive medium).
const double cardRadius = ExpressiveCorners.medium;

/// Smaller corner radius for list-row artwork thumbnails (Expressive small).
const double rowArtRadius = ExpressiveCorners.small;

/// Large corner radius for the player bar and Now Playing artwork
/// (Expressive large increased).
const double playerRadius = ExpressiveCorners.largeIncreased;

/// Bottom scroll clearance so list ends clear the floating player bar,
/// which now overlays full-height content (bar + its transparent margins).
const double playerBarClearance = 150.0;

const _ytmRed = Color(0xFFFF0000);

/// Default custom seed (YTM red): the custom source with this
/// seed resolves to null, keeping the hand-tuned scheme below
/// exactly.
const int defaultSeedColor = 0xffff0000;

/// Seed/override swatch presets (opaque ARGB).
const List<int> themeColorPresets = <int>[
  0xffff0000, // YTM red (default)
  0xffff6d00, // orange
  0xffffb300, // amber
  0xff4caf50, // green
  0xff009688, // teal
  0xff00bcd4, // cyan
  0xff2196f3, // blue
  0xff7c4dff, // violet
  0xffe91e63, // pink
  0xff9e9e9e, // grey
];

/// Theme color source (mirrors `SysConfig.themeSource`).
enum ThemeSource {
  /// Desktop accent via dynamic_color (falls back to built-in
  /// when the platform reports none).
  system,

  /// Seed-generated scheme.
  custom;

  /// Unknown keys fall back to custom so the app keeps its
  /// YTM-red look instead of surprising with system colors.
  static ThemeSource fromKey(String key) =>
      key == system.name ? system : custom;
}

const _defaultScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFFFB3B3),
  onPrimary: Color(0xFF680003),
  primaryContainer: Color(0xFF5C0E0E),
  onPrimaryContainer: Color(0xFFFFDAD4),
  secondary: Color(0xFFE7BDB7),
  onSecondary: Color(0xFF4A2C28),
  tertiary: Color(0xFFE7BDB7),
  onTertiary: Color(0xFF4A2C28),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  surface: Color(0xFF131314),
  onSurface: Color(0xFFF5F0EE),
  surfaceContainerHighest: Color(0xFF28282A),
  surfaceContainerHigh: Color(0xFF28282A),
  surfaceContainer: Color(0xFF1E1E20),
  onSurfaceVariant: Color(0xFFD8CFCB),
  outline: Color(0xFF534341),
  outlineVariant: Color(0xFF3A3231),
);

// Accessibility high contrast: brighter text and borders plus
// more distinct surface tiers, so separation and legibility
// survive low vision. The base surface stays put — only the
// luminance of the foreground and the container steps move.
// Applies to the built-in scheme only; dynamic and seeded
// schemes are contrast-safe by construction.
const _hcScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFFFC9C4),
  onPrimary: Color(0xFF680003),
  primaryContainer: Color(0xFF5C0E0E),
  onPrimaryContainer: Color(0xFFFFDAD4),
  secondary: Color(0xFFF0D5CF),
  onSecondary: Color(0xFF4A2C28),
  tertiary: Color(0xFFF0D5CF),
  onTertiary: Color(0xFF4A2C28),
  error: Color(0xFFFFC1B8),
  onError: Color(0xFF690005),
  surface: Color(0xFF131314),
  onSurface: Color(0xFFFFFFFF),
  surfaceContainerHighest: Color(0xFF3D3D40),
  surfaceContainerHigh: Color(0xFF303033),
  surfaceContainer: Color(0xFF232326),
  onSurfaceVariant: Color(0xFFF0EAE7),
  outline: Color(0xFF8A736F),
  outlineVariant: Color(0xFF5E524F),
);

/// Builds the app [ThemeData]: the dynamic/system/custom scheme by
/// default, high-contrast palette when [highContrast], or [scheme]
/// verbatim when the caller already resolved one.
ThemeData buildTheme({bool highContrast = false, ColorScheme? scheme}) {
  final effective = scheme ?? (highContrast ? _hcScheme : _defaultScheme);
  final base = ThemeData(
    colorScheme: effective,
    scaffoldBackgroundColor: scheme == null
        ? const Color(0xFF0B0B0C)
        : effective.surface,
    useMaterial3: true,
    fontFamily: 'GoogleSansFlex',
  );
  return base.copyWith(
    // De-bolded hierarchy: nothing above w500 anywhere. Emphasis
    // comes from size, spacing and color instead — heavy weights
    // clump together, especially on dark backgrounds. (A `wdth`
    // axis would be the expressive alternative, but google_fonts
    // serves Google Sans Flex as static per-weight cuts, so extra
    // width variations would be silently ignored.)
    textTheme: base.textTheme.emphasized.copyWith(
      // Overrides for the app's specific hierarchy:
      // Now Playing track title — presence via size, not weight.
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFamily: 'GoogleSansFlex',
        fontWeight: FontWeight.w500,
        fontVariations: const [
          FontVariation('wght', 500),
          FontVariation('opsz', 28),
          FontVariation('ROND', 100),
        ],
      ),
      // Shelf / section titles — light enough to not shout.
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontFamily: 'GoogleSansFlex',
        fontWeight: FontWeight.w500,
        letterSpacing: 0.25,
        fontVariations: const [
          FontVariation('wght', 500),
          FontVariation('opsz', 22),
          FontVariation('ROND', 100),
        ],
      ),
      // Track row titles — regular weight, clean.
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontFamily: 'GoogleSansFlex',
        fontWeight: FontWeight.w400,
        letterSpacing: 0.15,
        fontVariations: const [
          FontVariation('wght', 400),
          FontVariation('opsz', 16),
          FontVariation('ROND', 100),
        ],
      ),
      // Small titles — medium, aired out with spacing.
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontFamily: 'GoogleSansFlex',
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        fontVariations: const [
          FontVariation('wght', 500),
          FontVariation('opsz', 14),
          FontVariation('ROND', 100),
        ],
      ),
      // Body text — regular weight for readability.
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        fontVariations: const [
          FontVariation('wght', 400),
          FontVariation('opsz', 16),
        ],
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        fontVariations: const [
          FontVariation('wght', 400),
          FontVariation('opsz', 14),
        ],
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
        fontVariations: const [
          FontVariation('wght', 400),
          FontVariation('opsz', 12),
        ],
      ),
      // Buttons, chips, badges — medium with native spacing.
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        fontVariations: const [
          FontVariation('wght', 500),
          FontVariation('opsz', 14),
        ],
      ),
      labelMedium: base.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        fontVariations: const [
          FontVariation('wght', 500),
          FontVariation('opsz', 12),
        ],
      ),
      labelSmall: base.textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        fontVariations: const [
          FontVariation('wght', 500),
          FontVariation('opsz', 11),
        ],
      ),
    ),
  );
}

/// Resolves the effective dark scheme for the theme settings,
/// or null to keep the built-in hand-tuned scheme exactly:
/// system source without platform colors (live or remembered),
/// or custom source with the default seed and no manual overrides.
ColorScheme? resolveColorScheme({
  required ThemeSource source,
  required int seedColor,
  ColorScheme? systemDark,
  int? rememberedSystemPrimary,
  int? primaryOverride,
  int? secondaryOverride,
  int? tertiaryOverride,
  int? surfaceOverride,
}) {
  ColorScheme? base;
  if (source == ThemeSource.system && systemDark != null) {
    base = systemDark;
  } else if (source == ThemeSource.system && rememberedSystemPrimary != null) {
    // The platform fetch hasn't landed yet (cold start): seed from
    // the remembered accent so the first frame — and the tray icon
    // rendered from it — already follow the system color.
    base = ColorScheme.fromSeed(
      seedColor: Color(rememberedSystemPrimary & 0xffffffff),
      brightness: Brightness.dark,
    );
  } else if (source == ThemeSource.custom &&
      (seedColor & 0xffffffff) != defaultSeedColor) {
    base = ColorScheme.fromSeed(
      seedColor: Color(seedColor & 0xffffffff),
      brightness: Brightness.dark,
    );
  }
  if (base == null &&
      primaryOverride == null &&
      secondaryOverride == null &&
      tertiaryOverride == null &&
      surfaceOverride == null) {
    return null;
  }
  base ??= _defaultScheme;
  if (primaryOverride == null &&
      secondaryOverride == null &&
      tertiaryOverride == null &&
      surfaceOverride == null) {
    return base;
  }
  // Manual overrides apply as-is on top of either source.
  return base.copyWith(
    primary: primaryOverride == null ? null : Color(primaryOverride),
    secondary: secondaryOverride == null ? null : Color(secondaryOverride),
    tertiary: tertiaryOverride == null ? null : Color(tertiaryOverride),
    surface: surfaceOverride == null ? null : Color(surfaceOverride),
  );
}

/// YTM red accent used sparingly (badges, active states).
Color get ytmRed => _ytmRed;

/// Shared toggle-button-group styling: each segment is individually
/// filled — secondary container unselected, primary selected — with
/// no surrounding outline. The `selected` widget state (added by the
/// group for checked buttons) drives both colors.
M3EToggleButtonDecoration toggleButtonGroupDecoration(ColorScheme scheme) {
  return M3EToggleButtonDecoration(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? scheme.primary
          : scheme.secondaryContainer,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? scheme.onPrimary
          : scheme.onSecondaryContainer,
    ),
  );
}
