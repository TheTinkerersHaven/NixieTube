// Material 3 theme ported from Kotlin `Theme.kt` + `Style.kt`.
//
// Only the dark scheme is applied (the Kotlin `App` hardcodes
// `YtmDarkScheme`); the light scheme is defined but unused there too.

import 'package:material_ui/material_ui.dart';

import 'widgets/gapped_rounded_track_shape.dart';

/// Shared outer padding applied by every top-level screen.
const double screenPadding = 20.0;

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

ThemeData buildTheme() {
  const scheme = ColorScheme(
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
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0B0B0C),
    useMaterial3: true,
    // M3 Expressive styling for indicators and sliders. The flag reads
    // deprecated, but the 2023 Material You look is still the default,
    // so opt out explicitly (here = every widget app-wide).
    progressIndicatorTheme:
        // ignore: deprecated_member_use
        const ProgressIndicatorThemeData(year2023: false),
    sliderTheme: const SliderThemeData(
      trackHeight: 16,
      trackShape: GappedRoundedTrackShape(),
      // ignore: deprecated_member_use
      year2023: false,
    ),
  );
}

/// YTM red accent used sparingly (badges, active states).
Color get ytmRed => _ytmRed;
