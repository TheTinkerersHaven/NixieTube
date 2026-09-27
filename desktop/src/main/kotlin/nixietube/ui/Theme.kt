package nixietube.ui

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

// M3 theme with a YouTube-Music-like dark personality:
// near-black surfaces, red accent, rounded cards.
/** Signature YouTube-red accent used across the app theme. */
val YtmRed = Color(0xFFFF0000)
/** Dark red container color paired with [YtmRed] on dark surfaces. */
val YtmRedContainer = Color(0xFF5C0E0E)

/** Default dark Material 3 color scheme with near-black surfaces and a red accent. */
val YtmDarkScheme = darkColorScheme(
    primary = Color(0xFFFFB3B3),
    onPrimary = Color(0xFF680003),
    primaryContainer = YtmRedContainer,
    onPrimaryContainer = Color(0xFFFFDAD4),
    secondary = Color(0xFFE7BDB7),
    background = Color(0xFF0B0B0C),
    onBackground = Color(0xFFF5F0EE),
    surface = Color(0xFF131314),
    onSurface = Color(0xFFF5F0EE),
    surfaceVariant = Color(0xFF28282A),
    onSurfaceVariant = Color(0xFFD8CFCB),
    surfaceContainer = Color(0xFF1E1E20),
    surfaceContainerHigh = Color(0xFF28282A),
    outline = Color(0xFF534341),
    outlineVariant = Color(0xFF3A3231),
)

/** Light Material 3 color scheme mirroring the dark theme's red accent. */
val YtmLightScheme = lightColorScheme(
    primary = Color(0xFFB3261E),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFDAD4),
    background = Color(0xFFFFFBFF),
    surface = Color(0xFFFFFBFF),
    surfaceContainer = Color(0xFFF3EDEC),
)
