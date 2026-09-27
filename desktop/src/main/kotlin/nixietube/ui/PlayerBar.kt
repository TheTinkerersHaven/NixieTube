package nixietube.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Renders the persistent bottom player bar with track info, transport controls and a seek slider.
 *
 * @param state shared app state backing playback and navigation.
 * @param onExpand invoked when the bar body is tapped to open the full Now Playing view.
 */
@Composable
fun PlayerBar(state: AppState, onExpand: () -> Unit) {
    val player by state.player.state.collectAsState()
    val track = player.current
    // Floating bar: rounded container echoing the progress track's
    // curvature, ending exactly at the progress line fused to its bottom.
    // The whole bar expands to Now Playing (the queue button is gone);
    // only the controls consume their own taps.
    Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
        Surface(shape = PlayerRadius, tonalElevation = 3.dp) {
            Column(Modifier.clickable(onClick = onExpand)) {
                Row(
                    Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp).heightIn(min = 64.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (track != null) {
                        Artwork(track.displayArtwork, Modifier.size(56.dp).clip(CardRadius))
                        Spacer(Modifier.width(14.dp))
                        Column(
                            Modifier.weight(1f).padding(vertical = 2.dp),
                        ) {
                            Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
                            Text(
                                track.artistNames, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 2.dp),
                            )
                        }
                    } else {
                        Text(
                            "Search for music to start playing",
                            Modifier.weight(1f).clickable { state.go(Screen.Search) },
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (player.loading) {
                        CircularProgressIndicator(Modifier.size(28.dp))
                    } else {
                        IconButton(onClick = { state.player.previous() }, enabled = track != null) {
                            Icon(Icons.Rounded.SkipPrevious, "Previous", modifier = Modifier.size(28.dp))
                        }
                        IconButton(onClick = { state.player.togglePlayPause() }, enabled = track != null) {
                            Icon(
                                if (player.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                "Play/pause",
                                modifier = Modifier.size(28.dp),
                            )
                        }
                        IconButton(onClick = { state.player.next() }, enabled = track != null) {
                            Icon(Icons.Rounded.SkipNext, "Next", modifier = Modifier.size(28.dp))
                        }
                    }
                }
                // Progress + times always render (disabled at zero when idle)
                // so the bar height never jumps when playback starts.
                player.error?.let {
                    Text(
                        it, color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
                val hasLength = track != null && player.durationMs > 0
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        fmtTime(if (hasLength) player.positionMs else 0L),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "-" + fmtTime(
                            if (hasLength) {
                                (player.durationMs - player.positionMs).coerceAtLeast(0L)
                            } else {
                                0L
                            },
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                val progress = if (hasLength) {
                    (player.positionMs.toFloat() / player.durationMs.toFloat()).coerceIn(0f, 1f)
                } else {
                    0f
                }
                Box(
                    Modifier.fillMaxWidth()
                        .padding(start = 16.dp, end = 16.dp, bottom = 4.dp),
                ) {
                    SeekSlider(
                        progress = progress,
                        onSeek = { state.player.seekTo((it * player.durationMs).toLong()) },
                        modifier = Modifier.fillMaxWidth().height(20.dp),
                        enabled = hasLength,
                    )
                }
            }
        }
    }
}
