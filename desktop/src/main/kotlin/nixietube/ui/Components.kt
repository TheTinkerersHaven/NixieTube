package nixietube.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.ThumbDown
import androidx.compose.material.icons.rounded.ThumbUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Button
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.key
import kotlinx.coroutines.launch
import nixietube.innertube.RatingStatus
import nixietube.innertube.ShelfItem
import nixietube.innertube.Track
import kotlin.math.roundToInt
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.graphics.Brush

/**
 * Renders cached artwork for [url], or an album placeholder when none is available.
 * @param url artwork URL to load, or null for the placeholder.
 * @param modifier layout modifier applied to the artwork surface.
 */
@Composable
fun Artwork(url: String?, modifier: Modifier = Modifier) {
    val bitmap = rememberArtwork(url)
    if (bitmap != null) {
        androidx.compose.foundation.Canvas(
            modifier.clip(CardRadius),
        ) {
            // Manual center-crop blit: no ContentScale involved at all.
            val side = minOf(bitmap.width, bitmap.height)
            drawImage(
                image = bitmap,
                srcOffset = androidx.compose.ui.unit.IntOffset(
                    (bitmap.width - side) / 2,
                    (bitmap.height - side) / 2,
                ),
                srcSize = androidx.compose.ui.unit.IntSize(side, side),
                dstOffset = androidx.compose.ui.unit.IntOffset.Zero,
                dstSize = androidx.compose.ui.unit.IntSize(
                    size.width.toInt(),
                    size.height.toInt(),
                ),
            )
        }
    } else {
        Box(
            modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Album, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * Formats a millisecond duration as "m:ss".
 * @param ms duration in milliseconds.
 * @return formatted time string.
 */
fun fmtTime(ms: Long): String {
    if (ms <= 0) return "0:00"
    val s = (ms / 1000).toInt()
    return "%d:%02d".format(s / 60, s % 60)
}

/**
 * Formats a second duration as "m:ss".
 * @param sec duration in seconds.
 * @return formatted time string.
 */
fun fmtDur(sec: Int): String = fmtTime(sec * 1000L)

// Compact counter: 999 -> "999", 1500 -> "1.5K", 2_300_000 -> "2.3M".
// Negative means unknown -> blank.
/**
 * Formats a count compactly ("1.5K", "2.3M"); negative means unknown and yields blank.
 * @param n raw count, or negative when unknown.
 * @return compact display string.
 */
fun fmtCount(n: Long): String {
    if (n < 0) return ""
    if (n < 1000) return n.toString()
    if (n < 1_000_000) {
        val v = n / 1000.0
        return if (v >= 100) "${v.roundToInt()}K" else "%.1fK".format(java.util.Locale.US, v)
    }
    val m = n / 1_000_000.0
    return if (m >= 100) "${m.roundToInt()}M" else "%.1fM".format(java.util.Locale.US, m)
}

// Seek slider that glides between position ticks instead of jumping. The
// glide is linear over the tick interval, so motion looks constant; track
// changes sweep back through the bar. While dragging, the raw finger value
// shows so the thumb never lags behind.
/**
 * Seek slider that glides between position ticks and shows the raw value while dragging.
 * @param progress current position as a 0..1 fraction.
 * @param onSeek invoked with the new fraction when the user drags the thumb.
 * @param modifier layout modifier.
 * @param enabled whether interaction is allowed.
 */
@Composable
fun SeekSlider(
    progress: Float,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val interaction = remember { MutableInteractionSource() }
    var dragging by remember { mutableStateOf(false) }
    LaunchedEffect(interaction) {
        interaction.interactions.collect { dragging = it is DragInteraction.Start }
    }
    val glided by animateFloatAsState(
        progress,
        animationSpec = tween(durationMillis = 450, easing = LinearEasing),
        label = "seek-glide",
    )
    Slider(
        value = if (dragging) progress else glided,
        onValueChange = onSeek,
        modifier = modifier,
        enabled = enabled,
        interactionSource = interaction,
    )
}

/**
 * Track list row with artwork, title, artist/album, duration, and optional rating/enqueue actions.
 * @param track track to display.
 * @param index optional leading track number.
 * @param playing whether this track is currently playing (highlights title/index).
 * @param onPlay invoked when the row is clicked.
 * @param onEnqueue optional "play next" action; hidden when null.
 * @param showLike whether to show a standalone like button when [onRate] is absent.
 * @param onLike optional simple like callback used when [onRate] is absent.
 * @param rating current rating used to tint the like/dislike state.
 * @param onRate optional rating callback; when present, like/dislike toggle buttons are shown.
 */
@Composable
fun TrackRow(
    track: Track,
    index: Int? = null,
    playing: Boolean = false,
    onPlay: () -> Unit,
    onEnqueue: (() -> Unit)? = null,
    showLike: Boolean = false,
    onLike: (() -> Unit)? = null,
    rating: RatingStatus = RatingStatus.UNKNOWN,
    onRate: ((RatingStatus) -> Unit)? = null,
) {
    ListItem(
        modifier = Modifier.clickable(onClick = onPlay),
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        leadingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (index != null) {
                    Text(
                        "$index",
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(28.dp),
                    )
                }
                Artwork(
                    track.displayArtwork,
                    Modifier.size(48.dp).clip(RowArtRadius),
                )
            }
        },
        headlineContent = {
            Text(
                track.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            )
        },
        supportingContent = {
            Text(
                listOf(track.artistNames, track.album?.name).filter { it?.isNotBlank() == true }.joinToString(" • "),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (onRate != null) {
                    IconButton(
                        onClick = {
                            onRate(if (rating == RatingStatus.LIKE) RatingStatus.INDIFFERENT else RatingStatus.LIKE)
                        },
                    ) {
                        Icon(
                            Icons.Rounded.ThumbUp,
                            if (rating == RatingStatus.LIKE) "Remove like" else "Like",
                            tint = if (rating == RatingStatus.LIKE) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    IconButton(
                        onClick = {
                            onRate(if (rating == RatingStatus.DISLIKE) RatingStatus.INDIFFERENT else RatingStatus.DISLIKE)
                        },
                    ) {
                        Icon(
                            Icons.Rounded.ThumbDown,
                            if (rating == RatingStatus.DISLIKE) "Remove dislike" else "Dislike",
                            tint = if (rating == RatingStatus.DISLIKE) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                } else if (showLike && onLike != null) {
                    IconButton(onClick = onLike) {
                        Icon(
                            Icons.Rounded.ThumbUp,
                            "Like",
                            tint = if (rating == RatingStatus.LIKE) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                } else if (rating == RatingStatus.LIKE || rating == RatingStatus.DISLIKE) {
                    Icon(
                        if (rating == RatingStatus.DISLIKE) Icons.Rounded.ThumbDown else Icons.Rounded.ThumbUp,
                        if (rating == RatingStatus.DISLIKE) "Disliked" else "Liked",
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
                if (track.durationSec > 0) {
                    Text(fmtDur(track.durationSec), style = MaterialTheme.typography.bodySmall)
                }
                if (onEnqueue != null) {
                    IconButton(onClick = onEnqueue) {
                        Icon(Icons.AutoMirrored.Rounded.PlaylistAdd, "Play next")
                    }
                }
            }
        },
    )
}

/**
 * Card for a browsable shelf item (album, playlist, artist) with artwork, title, and subtitle.
 * @param item browse item to display.
 * @param onClick invoked when the card is clicked.
 */
@Composable
fun BrowseCard(item: ShelfItem.Browse, onClick: () -> Unit) {
    Column(
        Modifier.width(208.dp).clickable(onClick = onClick).padding(4.dp),
    ) {
        Artwork(item.thumbnails.maxByOrNull { it.width }?.url, Modifier.size(200.dp).clip(CardRadius))
        Spacer(Modifier.height(8.dp))
        Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
        Text(
            item.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Rail card for a track with large artwork, title, and artist/album line.
 * @param track track to display.
 * @param playing whether this track is currently playing (highlights the title).
 * @param onClick invoked when the card is clicked.
 */
@Composable
fun TrackRailCard(track: Track, playing: Boolean, onClick: () -> Unit) {
    Column(
        Modifier.width(208.dp).clickable(onClick = onClick).padding(4.dp),
    ) {
        Artwork(
            track.displayArtwork,
            Modifier.size(200.dp).clip(CardRadius),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            track.title, maxLines = 2, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodyMedium,
            color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
        )
        Text(
            track.artistNames.ifBlank { track.album?.name.orEmpty() },
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Section header for a horizontal rail with title plus scroll-left/right buttons.
 * @param title header text.
 * @param listState list state scrolled by the arrow buttons.
 * @param modifier layout modifier.
 * @param trailing optional extra header content after the arrows.
 */
@Composable
fun RailHeader(
    title: String,
    listState: LazyListState,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(
            title, style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.weight(1f).padding(bottom = 8.dp),
        )
        IconButton(onClick = {
            scope.launch {
                listState.animateScrollToItem((listState.firstVisibleItemIndex - 4).coerceAtLeast(0))
            }
        }) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Scroll left")
        }
        IconButton(onClick = {
            scope.launch {
                listState.animateScrollToItem(listState.firstVisibleItemIndex + 4)
            }
        }) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, "Scroll right")
        }
        trailing()
    }
}

/**
 * Horizontal rail of track cards; renders nothing when [tracks] is empty.
 * @param tracks tracks to display in order.
 * @param playingId videoId of the currently playing track, or null.
 * @param onPlay invoked with the clicked track.
 * @param listState scroll state of the rail.
 */
@Composable
fun TrackRailGrid(
    tracks: List<Track>,
    playingId: String?,
    onPlay: (Track) -> Unit,
    listState: LazyListState = rememberLazyListState(),
) {
    if (tracks.isEmpty()) return
    LazyRow(state = listState) {
        items(tracks, key = { it.videoId }) { t ->
            TrackRailCard(
                track = t,
                playing = t.videoId == playingId,
                onClick = { onPlay(t) },
            )
        }
    }
}

// Quick picks card in the YTM style: title overlaid on the artwork with a
// bottom scrim and a chevron, no text below the art.
/**
 * Quick-pick card with title overlaid on artwork plus a bottom scrim and chevron.
 * @param title main label shown over the artwork.
 * @param subtitle secondary label; hidden when blank.
 * @param art artwork URL, or null for the placeholder.
 * @param playing whether the item is currently playing (highlights the title).
 * @param onClick invoked when the card is clicked.
 * @param modifier layout modifier.
 */
@Composable
fun QuickPickCard(
    title: String,
    subtitle: String,
    art: String?,
    playing: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .padding(4.dp)
            .clip(CardRadius)
            .clickable(onClick = onClick),
    ) {
        Artwork(art, Modifier.fillMaxWidth().aspectRatio(1f))
        Box(
            Modifier.fillMaxWidth().aspectRatio(1f).background(
                Brush.verticalGradient(
                    listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f)),
                ),
            ),
        )
        Row(
            Modifier.fillMaxWidth().align(Alignment.BottomStart).padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (playing) MaterialTheme.colorScheme.primary else Color.White,
                )
                if (subtitle.isNotBlank()) {
                    Text(
                        subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.75f),
                    )
                }
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight, null,
                tint = Color.White.copy(alpha = 0.9f),
            )
        }
    }
}

/**
 * Horizontal rail of browsable items that navigates to the detail screen on click.
 * @param title rail header text.
 * @param items browse items to display; nothing renders when empty.
 * @param state app state used for navigation.
 * @param circular whether to render items as circular artist cards.
 */
@Composable
fun ArtistBrowseRail(
    title: String,
    items: List<ShelfItem.Browse>,
    state: AppState,
    circular: Boolean = false,
) {
    if (items.isEmpty()) return
    val railState = rememberLazyListState()
    RailHeader(title, railState, Modifier.padding(horizontal = 12.dp))
    LazyRow(state = railState, contentPadding = PaddingValues(horizontal = 16.dp)) {
        items(items, key = { it.browseId }) { item ->
            if (circular) {
                SimilarArtistCard(item) { state.go(Screen.Detail(item)) }
            } else {
                BrowseCard(item) { state.go(Screen.Detail(item)) }
            }
        }
    }
    Spacer(Modifier.height(16.dp))
}

/**
 * Centered error message with a retry button.
 * @param message error text to display.
 * @param onRetry invoked when Retry is clicked.
 */
@Composable
fun ErrorBox(message: String, onRetry: () -> Unit = {}) {
    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(message, color = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(8.dp))
        Button(onClick = onRetry) {
            Icon(Icons.Rounded.Refresh, null)
            Spacer(Modifier.width(8.dp))
            Text("Retry")
        }
    }
}




/**
 * Circular-artwork card for an artist with title and optional subtitle.
 * @param item browse item to display.
 * @param onClick invoked when the card is clicked.
 */
@Composable
fun SimilarArtistCard(item: ShelfItem.Browse, onClick: () -> Unit) {
    Column(
        modifier = Modifier.width(160.dp).clickable(onClick = onClick).padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Artwork(
            item.thumbnails.maxByOrNull { it.width }?.url,
            Modifier.size(136.dp).clip(CircleShape),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            item.title,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodyMedium,
        )
        if (item.subtitle.isNotBlank()) {
            Text(
                item.subtitle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
