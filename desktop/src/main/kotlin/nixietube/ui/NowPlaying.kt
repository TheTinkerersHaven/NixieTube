package nixietube.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.ThumbDown
import androidx.compose.material.icons.rounded.ThumbUp
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.key
import nixietube.innertube.LyricLine
import nixietube.innertube.RatingStatus
import nixietube.innertube.Track
import nixietube.player.RepeatMode

/** Linearly interpolates this color toward [other] by [amount] (0..1). */
private fun Color.blendToward(other: Color, amount: Float): Color = Color(
    red = red + (other.red - red) * amount,
    green = green + (other.green - green) * amount,
    blue = blue + (other.blue - blue) * amount,
)

// Layered, non-invasive backdrop: a vertical wash following the cover's
// top/middle/bottom bands, plus a soft radial glow so the tint varies in
// every direction instead of only top-to-bottom.
/**
 * Paints the Now Playing tinted backdrop derived from the cover palette.
 *
 * @param artworkUrl cover URL used to sample the backdrop colors, or null for a plain background.
 */
@Composable
private fun NowPlayingBackdrop(artworkUrl: String?) {
    val backdrop = MaterialTheme.colorScheme.background
    val palette = rememberCoverPalette(artworkUrl)
    val wash = remember(backdrop, palette) {
        if (palette.size < 3) {
            Brush.verticalGradient(listOf(backdrop, backdrop))
        } else {
            Brush.verticalGradient(
                0f to backdrop.blendToward(palette[0], 0.15f),
                0.3f to backdrop.blendToward(palette[0], 0.28f),
                0.62f to backdrop.blendToward(palette[1], 0.28f),
                1f to backdrop.blendToward(palette[2], 0.35f),
            )
        }
    }
    val glow = remember(palette) {
        palette.getOrNull(1)?.let { mid ->
            Brush.radialGradient(listOf(mid.copy(alpha = 0.2f), Color.Transparent))
        }
    }
    Box(Modifier.fillMaxSize().background(wash)) {
        if (glow != null) Box(Modifier.fillMaxSize().background(glow))
    }
}

/**
 * Renders the full Now Playing view with cover, transport controls and Up-next/Lyrics/Info tabs.
 *
 * Shows nothing when no track is loaded.
 *
 * @param state shared app state backing the player, lyrics and rating actions.
 * @param onClose invoked to collapse back to the mini player bar.
 */
@Composable
fun NowPlaying(state: AppState, onClose: () -> Unit) {
    val player by state.player.state.collectAsState()
    val lyrics by state.lyrics.collectAsState()
    val account by state.account.collectAsState()
    val track = player.current ?: return
    var tab by remember { mutableIntStateOf(0) }
    val backdrop = MaterialTheme.colorScheme.background
    // Keep the Surface on the theme background so content (title, icons)
    // resolves to the right color; the crossfading backdrop paints over it.
    Surface(Modifier.fillMaxSize(), color = backdrop) {
        Box(Modifier.fillMaxSize()) {
            Crossfade(targetState = track.displayArtwork, label = "np-backdrop") { url ->
                NowPlayingBackdrop(url)
            }
            Column(Modifier.fillMaxSize().padding(ScreenPadding)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.Rounded.KeyboardArrowDown, "Close") }
                Text("Now playing", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            }
            Spacer(Modifier.height(8.dp))
            BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
                // Shrink the cover on short/narrow windows so the title,
                // controls and volume around it never clip: ~320dp of the
                // column is the fixed chrome surrounding the art.
                val artSize = minOf(
                    maxWidth * 0.44f,
                    (maxHeight - 320.dp).coerceAtLeast(180.dp),
                    360.dp,
                )
            Row(Modifier.fillMaxSize()) {
                Column(
                    Modifier.weight(1f).fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Crossfade(targetState = track.displayArtwork, label = "np-art") { art ->
                        Artwork(art, Modifier.size(artSize).clip(PlayerRadius))
                    }
                    Spacer(Modifier.height(16.dp))
                    Text(
                        track.title,
                        style = MaterialTheme.typography.headlineSmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                    if (track.artists.isNotEmpty()) {
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            track.artists.forEachIndexed { index, artist ->
                                Text(
                                    artist.name,
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier
                                        .clickable {
                                            onClose()
                                            state.openArtist(artist, track)
                                        }
                                        .padding(horizontal = 2.dp),
                                )
                                if (index != track.artists.lastIndex) {
                                    Text(
                                        "•",
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                }
                            }
                        }
                    }
                    track.album?.let { album ->
                        Text(
                            album.name,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
                                .clickable {
                                    onClose()
                                    state.openAlbum(track, album)
                                }
                                .padding(top = 4.dp),
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    if (player.durationMs > 0) {
                        val progress = (player.positionMs.toFloat() / player.durationMs.toFloat()).coerceIn(0f, 1f)
                        SeekSlider(
                            progress = progress,
                            onSeek = { state.player.seekTo((it * player.durationMs).toLong()) },
                            modifier = Modifier.fillMaxWidth(0.9f),
                        )
                        Row(Modifier.fillMaxWidth(0.9f), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(fmtTime(player.positionMs), style = MaterialTheme.typography.bodySmall)
                            Text(fmtTime(player.durationMs), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        IconButton(onClick = { state.player.toggleShuffle() }) {
                            Icon(
                                Icons.Rounded.Shuffle, "Shuffle",
                                tint =
                                    if (player.shuffle) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                        // Buttons are sized to match their icons: M3 IconButton
                        // clips content to its own circle, so oversized icons
                        // alone stay invisible.
                        IconButton(
                            onClick = { state.player.previous() },
                            modifier = Modifier.size(60.dp),
                        ) {
                            Icon(Icons.Rounded.SkipPrevious, "Previous", modifier = Modifier.size(48.dp))
                        }
                        if (player.loading) {
                            Box(
                                Modifier.size(76.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                CircularProgressIndicator(Modifier.size(60.dp))
                            }
                        } else {
                            FilledIconButton(
                                onClick = { state.player.togglePlayPause() },
                                modifier = Modifier.size(76.dp),
                                colors = IconButtonDefaults.filledIconButtonColors(
                                    containerColor = androidx.compose.ui.graphics.Color.White,
                                    contentColor = androidx.compose.ui.graphics.Color.Black,
                                ),
                            ) {
                                Icon(
                                    if (player.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                    "Play/pause", modifier = Modifier.size(42.dp),
                                )
                            }
                        }
                        IconButton(
                            onClick = { state.player.next() },
                            modifier = Modifier.size(60.dp),
                        ) {
                            Icon(Icons.Rounded.SkipNext, "Next", modifier = Modifier.size(48.dp))
                        }
                        IconButton(onClick = { state.player.cycleRepeat() }) {
                            Icon(
                                if (player.repeat == RepeatMode.ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,
                                "Repeat",
                                tint =
                                    if (player.repeat == RepeatMode.OFF) MaterialTheme.colorScheme.onSurface
                                    else MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                    Spacer(Modifier.height(32.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Icon(Icons.AutoMirrored.Rounded.VolumeUp, null, modifier = Modifier.size(20.dp))
                        Slider(
                            value = player.volume / 100f,
                            onValueChange = { state.player.setVolume((it * 100).toInt()) },
                            modifier = Modifier.width(120.dp),
                        )
                        val account by state.account.collectAsState()
                        if (account != null) {
                            val rating = track.rating
                            IconButton(
                                onClick = {
                                    state.rateCurrent(
                                        if (rating == RatingStatus.LIKE) RatingStatus.INDIFFERENT
                                        else RatingStatus.LIKE,
                                    )
                                },
                            ) {
                                Icon(
                                    Icons.Rounded.ThumbUp,
                                    if (rating == RatingStatus.LIKE) "Remove like" else "Like",
                                    tint =
                                        if (rating == RatingStatus.LIKE) MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.onSurface,
                                )
                            }
                            IconButton(
                                onClick = {
                                    state.rateCurrent(
                                        if (rating == RatingStatus.DISLIKE) RatingStatus.INDIFFERENT
                                        else RatingStatus.DISLIKE,
                                    )
                                },
                            ) {
                                Icon(
                                    Icons.Rounded.ThumbDown,
                                    if (rating == RatingStatus.DISLIKE) "Remove dislike" else "Dislike",
                                    tint =
                                        if (rating == RatingStatus.DISLIKE) MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.width(24.dp))
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    // Transparent container so the gradient flows through
                    // instead of a solid bar punching through it.
                    PrimaryTabRow(
                        selectedTabIndex = tab,
                        containerColor = Color.Transparent,
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ) {
                        Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("Up next") })
                        Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("Lyrics") })
                        Tab(selected = tab == 2, onClick = { tab = 2 }, text = { Text("Info") })
                    }
                    if (tab == 0) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            FilterChip(
                                selected = player.autoplay,
                                onClick = { state.player.toggleAutoplay() },
                                label = { Text("Autoplay") },
                            )
                            AssistChip(
                                onClick = { player.current?.let { state.startRadio(it) } },
                                enabled = player.current != null,
                                leadingIcon = {
                                    Icon(
                                        Icons.Rounded.PlayArrow, null,
                                        modifier = Modifier.size(18.dp),
                                    )
                                },
                                label = { Text("Radio") },
                            )
                        }
                        LazyColumn(Modifier.fillMaxSize()) {
                            itemsIndexed(
                                player.queue,
                                key = { _, t -> t.videoId + "@" + player.queue.indexOf(t) },
                            ) { i, t ->
                                TrackRow(
                                    track = t,
                                    playing = i == player.index,
                                    onPlay = { state.player.playAt(i) },
                                    rating = t.rating,
                                    onRate = if (account != null) {
                                        ({ state.rateTrack(t.videoId, it) })
                                    } else {
                                        null
                                    },
                                )
                            }
                        }
                    } else if (tab == 1) {
                        LyricsView(
                            lyrics = lyrics,
                            positionMs = player.positionMs,
                            onSeek = { state.player.seekTo(it) },
                        )
                    } else {
                        SongInfoView(state = state, track = track, onClose = onClose)
                    }
                }
            }
            }
        }
        }
    }
}

/**
 * Renders the Info tab rows (title, artists, album, counts) with artist/album navigation links.
 *
 * @param state shared app state used to open artist/album detail screens.
 * @param track the track whose metadata is displayed.
 * @param onClose invoked before navigating away from Now Playing.
 */
@Composable
fun SongInfoView(state: AppState, track: Track, onClose: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        @Composable
        fun Row(label: String, value: String, onClick: (() -> Unit)? = null) {
            val mod = if (onClick != null) {
                Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 4.dp, vertical = 6.dp)
            } else {
                Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp)
            }
            Column(mod) {
                Text(
                    label,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    value.ifBlank { "—" },
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (onClick != null) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceContainerHigh)
        }
        Row("Title", track.title)
        if (track.artists.isEmpty()) {
            Row("Artists", "")
        } else {
            Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp)) {
                Text(
                    "Artists",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
                    track.artists.forEachIndexed { index, artist ->
                        Text(
                            artist.name,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.clickable {
                                onClose()
                                state.openArtist(artist, track)
                            },
                        )
                        if (index != track.artists.lastIndex) {
                            Text(
                                ", ",
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceContainerHigh)
        }
        track.album?.let { album ->
            Row(
                "Album" + (album.kind?.let { " (${it.label})" } ?: ""),
                album.name,
                onClick = {
                    onClose()
                    state.openAlbum(track, album)
                },
            )
        } ?: Row("Album", "")
        Row("Year", track.album?.year.orEmpty())
        Row(
            "Duration",
            if (track.durationSec > 0) fmtDur(track.durationSec) else "",
        )
        Row(
            "Rating",
            when (track.rating) {
                RatingStatus.LIKE -> "Liked"
                RatingStatus.DISLIKE -> "Disliked"
                RatingStatus.INDIFFERENT -> "Indifferent"
                RatingStatus.UNKNOWN -> ""
            },
        )
        if (track.views.isNotBlank()) Row("Views", track.views)
        Row("Likes", fmtCount(track.likeCount))
        Row("Dislikes", fmtCount(track.dislikeCount))
    }
}

/**
 * Renders scrollable lyrics with the active line highlighted and auto-scrolled into view.
 *
 * Timed lines are clickable: tapping one seeks playback to that timestamp.
 *
 * @param lyrics lines to display; untimed lines render without highlighting and are not clickable.
 * @param positionMs current playback position used to pick the active line.
 * @param onSeek invoked with the target position in milliseconds when a timed line is clicked.
 */
@Composable
fun LyricsView(lyrics: List<LyricLine>, positionMs: Long, onSeek: (Long) -> Unit = {}) {
    if (lyrics.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("No lyrics found", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    val timed = lyrics.any { it.timeMs >= 0 }
    val currentIndex = if (timed) {
        lyrics.indexOfLast { it.timeMs <= positionMs }.coerceAtLeast(0)
    } else {
        -1
    }
    val listState = rememberLazyListState()
    LaunchedEffect(currentIndex) {
        if (currentIndex >= 0) listState.animateScrollToItem((currentIndex - 3).coerceAtLeast(0))
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(vertical = 24.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        itemsIndexed(lyrics) { i, line ->
            val active = i == currentIndex
            val emphasis by animateFloatAsState(if (active) 1.12f else 1f, label = "lyric-scale")
            val tint by animateColorAsState(
                if (active) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
                },
                label = "lyric-color",
            )
            val seekModifier = if (line.timeMs >= 0) {
                Modifier.clickable { onSeek(line.timeMs) }
            } else {
                Modifier
            }
            Text(
                line.text,
                style = if (active) MaterialTheme.typography.titleLarge else MaterialTheme.typography.bodyLarge,
                color = tint,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                modifier = seekModifier
                    .graphicsLayer {
                        scaleX = emphasis
                        scaleY = emphasis
                    }
                    .padding(vertical = 8.dp, horizontal = 16.dp),
            )
        }
    }
}
