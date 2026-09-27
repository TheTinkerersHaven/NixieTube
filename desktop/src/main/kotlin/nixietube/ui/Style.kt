package nixietube.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

// App-wide styling constants: screens share one outer padding and one
// card language so every surface reads as the same app.
/** Shared outer padding applied by every top-level screen. */
val ScreenPadding = 20.dp
/** Default corner radius for cards and artwork tiles. */
val CardRadius = RoundedCornerShape(12.dp)
/** Smaller corner radius for list-row artwork thumbnails. */
val RowArtRadius = RoundedCornerShape(8.dp)
/** Large corner radius for the player bar and Now Playing artwork. */
val PlayerRadius = RoundedCornerShape(20.dp)
