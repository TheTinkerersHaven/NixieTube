package nixietube.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.key
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import nixietube.innertube.Shelf
import nixietube.innertube.ShelfItem
import nixietube.innertube.Track

/**
 * Home screen with greeting, mood chips, personal quick picks, discover rail, and content shelves.
 * @param state app state providing home shelves, activity, liked songs, and playback actions.
 */
@Composable
fun HomePanel(state: AppState) {
    val ui by state.home.collectAsState()
    val player by state.player.state.collectAsState()
    val account by state.account.collectAsState()
    val activity by state.activity.collectAsState()
    val liked by state.liked.collectAsState()
    val playlists by state.playlists.collectAsState()
    val artists by state.artists.collectAsState()
    val recentArtists by state.recentArtists.collectAsState()
    val discover by state.discover.collectAsState()
    // Personal quick picks: recent songs, artists, then your playlists.
    // Replaces the generic shelf (and the redundant Jump-back-in rail)
    // once there is enough of your own data to fill the grid. Sized for
    // up to a 6x3 grid on wide windows.
    val quickPicks = remember(activity, liked, playlists, artists, recentArtists) {
        buildList {
            activity.distinctBy { it.videoId }.take(8).forEach { add(ShelfItem.Song(it)) }
            (recentArtists + artists).distinctBy { it.browseId }.take(6).forEach { add(it) }
            playlists.filter { it.id != "__liked" }.take(4).forEach { pl ->
                val thumbs = (pl.arts.takeIf { it.isNotEmpty() } ?: listOfNotNull(pl.art))
                    .map { nixietube.innertube.Thumbnail(it) }
                add(
                    ShelfItem.Browse(
                        pl.title,
                        listOf(pl.owner, "${pl.itemCount} songs")
                            .filter { it.isNotBlank() }.joinToString(" • "),
                        pl.id,
                        thumbs,
                    ),
                )
            }
        }.take(18)
    }
    val showPersonalPicks = account != null && quickPicks.size >= 6
    val shelves = remember(ui.shelves, showPersonalPicks) {
        if (showPersonalPicks) {
            ui.shelves.filterNot { it.title.equals("Quick picks", ignoreCase = true) }
        } else {
            ui.shelves
        }
    }
    if (ui.loading && ui.shelves.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }
    if (ui.error != null && ui.shelves.isEmpty()) {
        ErrorBox(ui.error!!, onRetry = { state.loadHome() })
        return
    }
    Box(
        Modifier.fillMaxSize().background(
            androidx.compose.ui.graphics.Brush.verticalGradient(
                listOf(
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f),
                    MaterialTheme.colorScheme.background,
                ),
            ),
        ),
    ) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(ScreenPadding)) {
            item(key = "greeting") {
                val hour = java.time.LocalTime.now().hour
                val avatar by state.accountAvatar.collectAsState()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (account != null) {
                        if (avatar.isNullOrBlank()) {
                            Box(
                                Modifier.size(44.dp).clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    account!!.first().uppercase(),
                                    style = MaterialTheme.typography.titleMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        } else {
                            Artwork(
                                avatar,
                                Modifier.size(44.dp).clip(CircleShape),
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                    }
                    Column(Modifier.weight(1f)) {
                        Text(
                            when (hour) {
                                in 5..11 -> "Good morning"
                                in 12..17 -> "Good afternoon"
                                else -> "Good evening"
                            },
                            style = MaterialTheme.typography.headlineMedium,
                        )
                        if (account != null) {
                            Text(
                                account!!,
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(state.moods) { mood ->
                        FilterChip(
                            selected = false,
                            onClick = { state.searchAndGo(mood) },
                            label = { Text(mood) },
                        )
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
        if (showPersonalPicks) {
            item(key = "quickpicks") {
                // Responsive: side-by-side on wide windows, stacked with a
                // capped grid + shorter list on narrow ones.
                BoxWithConstraints(Modifier.fillMaxWidth()) {
                    if (maxWidth >= 900.dp) {
                        QuickPicksLikedRow(
                            modifier = Modifier.fillMaxWidth(),
                            spacing = 16.dp,
                            quickContent = {
                                QuickPicksGrid(quickPicks, state, player.current?.videoId)
                            },
                            likedContent = {
                                LikedSideList(
                                    liked,
                                    state,
                                    player.current?.videoId,
                                    listHeight = null,
                                )
                            },
                        )
                    } else {
                        Column(Modifier.fillMaxWidth()) {
                            QuickPicksGrid(quickPicks, state, player.current?.videoId)
                            Spacer(Modifier.height(16.dp))
                            LikedSideList(liked, state, player.current?.videoId, listHeight = 400.dp)
                        }
                    }
                }
                Spacer(Modifier.height(20.dp))
            }
        } else if (account != null && activity.isNotEmpty()) {
            item(key = "personal") {
                val railState = rememberLazyListState()
                RailHeader("Jump back in", railState)
                LazyRow(state = railState) {
                    itemsIndexed(activity.take(14), key = { i, t -> "${t.videoId}@$i" }) { i, t ->
                        TrackRailCard(
                            track = t,
                            playing = t.videoId == player.current?.videoId,
                            onClick = { state.playSongs(activity, i) },
                        )
                    }
                }
                Spacer(Modifier.height(20.dp))
            }
        }
        if (discover.isNotEmpty()) {
            item(key = "discover") {
                val railState = rememberLazyListState()
                RailHeader("Discover", railState) {
                    TextButton(onClick = { state.playSongs(discover, 0) }) { Text("Play all") }
                }
                LazyRow(state = railState) {
                    itemsIndexed(discover, key = { i, t -> "${t.videoId}@$i" }) { i, t ->
                        TrackRailCard(
                            track = t,
                            playing = t.videoId == player.current?.videoId,
                            onClick = { state.playSongs(discover, i) },
                        )
                    }
                }
                Spacer(Modifier.height(20.dp))
            }
        }
        items(shelves) { shelf ->
            ShelfSection(shelf, state, player.current?.videoId)
            Spacer(Modifier.height(20.dp))
        }
        }
    }
}


// Side-by-side row where the liked list is cut to the quick-picks height.
// Measures quick picks first, then forces the liked column to that exact
// height so its inner list scrolls/clips. Avoids IntrinsicSize, which is
// unsupported for SubcomposeLayout children like LazyColumn/BoxWithConstraints.
/**
 * Side-by-side quick-picks + liked-songs row matched in height.
 * @param modifier outer layout modifier.
 * @param spacing horizontal gap between the two columns.
 * @param quickWeight relative width of the quick-picks column.
 * @param likedWeight relative width of the liked column.
 * @param quickContent quick-picks grid content; measured first and drives the row height.
 * @param likedContent liked-songs content; constrained to the quick-picks height.
 */
@Composable
private fun QuickPicksLikedRow(
    modifier: Modifier = Modifier,
    spacing: Dp = 16.dp,
    quickWeight: Float = 1.55f,
    likedWeight: Float = 1f,
    quickContent: @Composable () -> Unit,
    likedContent: @Composable () -> Unit,
) {
    Layout(
        content = {
            // Wrap in Column/Box so each side is a single measurable.
            // QuickPicksGrid emits 3 siblings (header, spacer, grid) which
            // must stay vertical -> Column. Liked is a single Column -> Box.
            Column { quickContent() }
            Box { likedContent() }
        },
        modifier = modifier,
    ) { measurables, constraints ->
        check(measurables.size == 2) { "Expected 2 children, got ${measurables.size}" }
        val spacingPx = spacing.toPx().roundToInt()
        val totalWidth = if (constraints.hasBoundedWidth) {
            constraints.maxWidth
        } else {
            measurables[0].measure(constraints).width +
                spacingPx +
                measurables[1].measure(constraints).width
        }
        val totalWeight = quickWeight + likedWeight
        val quickWidth = ((totalWidth - spacingPx) * (quickWeight / totalWeight)).toInt()
            .coerceAtLeast(0)
        val likedWidth = (totalWidth - spacingPx - quickWidth).coerceAtLeast(0)
        // Quick picks first: unbounded height, fixed width. No intrinsics.
        val quickPlaceable = measurables[0].measure(
            Constraints.fixedWidth(quickWidth).copy(
                minHeight = 0,
                maxHeight = Constraints.Infinity,
            ),
        )
        val rowHeight = quickPlaceable.height
        // Liked second: forced to the exact quick-picks height so the inner
        // LazyColumn (weight 1f) fills the remainder and clips.
        val likedPlaceable = measurables[1].measure(
            Constraints.fixedWidth(likedWidth).copy(
                minHeight = rowHeight,
                maxHeight = rowHeight,
            ),
        )
        layout(totalWidth, rowHeight) {
            quickPlaceable.placeRelative(0, 0)
            likedPlaceable.placeRelative(quickWidth + spacingPx, 0)
        }
    }
}

// Liked songs list: normal rows under a header with Play all.
/**
 * Liked-songs side list with a "Play all" header and rate/enqueue row actions.
 * @param liked liked tracks to display.
 * @param state app state used for playback and rating actions.
 * @param playingId videoId of the currently playing track, or null.
 * @param listHeight fixed height of the scrolling list, or null to fill the
 * available height (wide side-by-side mode, cut where the quick-pick tiles end).
 * @param modifier outer layout modifier.
 */
@Composable
private fun LikedSideList(
    liked: List<Track>,
    state: AppState,
    playingId: String?,
    listHeight: Dp? = 600.dp,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Liked songs",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = { state.playSongs(liked, 0) },
                enabled = liked.isNotEmpty(),
            ) {
                Text("Play all")
            }
        }
        Spacer(Modifier.height(8.dp))
        val listModifier = if (listHeight != null) {
            Modifier.fillMaxWidth().height(listHeight)
        } else {
            Modifier.fillMaxWidth().weight(1f)
        }
        LazyColumn(listModifier) {
            itemsIndexed(liked, key = { i, t -> "${t.videoId}@$i" }) { i, t ->
                TrackRow(
                    track = t,
                    playing = t.videoId == playingId,
                    onPlay = { state.playSongs(liked, i) },
                    onPlaylists = { state.openPlaylistDialog(t) },
                    rating = t.rating,
                    onRate = ({ state.rateTrack(t.videoId, it) }),
                )
            }
        }
    }
}

// Personal quick picks: compact 3x3 card grid (recent songs, artists,
// playlists), capped so cells stay small.
/**
 * Personal quick-picks grid (recent songs, artists, playlists) with play/shuffle actions.
 * @param items shelf items to arrange in a 3-row responsive grid.
 * @param state app state used for playback and navigation.
 * @param playingId videoId of the currently playing track, or null.
 */
@Composable
private fun QuickPicksGrid(
    items: List<ShelfItem>,
    state: AppState,
    playingId: String?,
) {
    val gridSongs = remember(items) {
        items.filterIsInstance<ShelfItem.Song>().map { it.track }
    }
    fun open(item: ShelfItem) {
        when (item) {
            is ShelfItem.Song -> {
                val idx = gridSongs.indexOf(item.track).coerceAtLeast(0)
                state.playSongs(gridSongs, idx)
            }
            is ShelfItem.Browse ->
                if (item.browseId.startsWith("UC")) {
                    state.go(Screen.Detail(item))
                } else {
                    state.openPlaylistById(item.browseId)
                }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "Quick picks",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.weight(1f),
        )
        IconButton(
            onClick = { state.playSongs(gridSongs, 0) },
            enabled = gridSongs.isNotEmpty(),
        ) {
            Icon(Icons.Rounded.PlayArrow, "Play quick picks")
        }
        IconButton(
            onClick = { state.playShuffled(gridSongs) },
            enabled = gridSongs.isNotEmpty(),
        ) {
            Icon(Icons.Rounded.Shuffle, "Shuffle quick picks")
        }
    }
    Spacer(Modifier.height(8.dp))
    // Columns grow with the available width (~170dp cells, 3 to 6); rows
    // stay at 3. Cells keep a stable size while the count reacts.
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val cols = (maxWidth / 170.dp).toInt().coerceIn(3, 6)
        val shown = items.take(cols * 3)
        Column(Modifier.fillMaxWidth()) {
            repeat(3) { row ->
                Row(Modifier.fillMaxWidth()) {
                    repeat(cols) { col ->
                        when (val item = shown.getOrNull(row * cols + col)) {
                            null -> Spacer(Modifier.weight(1f))
                            is ShelfItem.Song -> QuickPickCard(
                                title = item.track.title,
                                subtitle = item.track.artistNames,
                                art = item.track.displayArtwork,
                                playing = item.track.videoId == playingId,
                                onClick = { open(item) },
                                modifier = Modifier.weight(1f),
                            )
                            is ShelfItem.Browse -> QuickPickCard(
                                title = item.title,
                                subtitle = item.subtitle,
                                art = item.thumbnails.maxByOrNull { it.width }?.url,
                                playing = false,
                                onClick = { open(item) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Renders one home shelf: song-only shelves as a track column, mixed shelves as a browse rail.
 * @param shelf shelf content to display.
 * @param state app state used for playback and navigation.
 * @param playingId videoId of the currently playing track, or null.
 */
@Composable
private fun ShelfSection(shelf: Shelf, state: AppState, playingId: String?) {
    val songs = shelf.items.filterIsInstance<ShelfItem.Song>().map { it.track }
    val browses = shelf.items.filterIsInstance<ShelfItem.Browse>()
    if (songs.isNotEmpty() && browses.isEmpty()) {
        Text(shelf.title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(bottom = 8.dp))
        Column {
            songs.forEachIndexed { i, t ->
                TrackRow(
                    track = t, playing = t.videoId == playingId,
                    onPlay = { state.playSongs(songs, i) },
                    onPlaylists = { state.openPlaylistDialog(t) },
                    rating = t.rating,
                )
            }
        }
    } else {
        val listState = rememberLazyListState()
        val scope = rememberCoroutineScope()
        // YTM-style shelf header: big title, Altro + arrows.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                shelf.title, style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f).padding(bottom = 8.dp),
            )
            TextButton(onClick = { /* shelves expand in place on YTM; no-op */ }) {
                Text("Altro")
            }
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
        }
        LazyRow(state = listState) {
            items(shelf.items) { item ->
                when (item) {
                    is ShelfItem.Song -> BrowseCard(
                        ShelfItem.Browse(item.track.title, item.track.artistNames, "", item.track.thumbnails),
                        onClick = {
                            val idx = songs.indexOf(item.track)
                            state.playSongs(songs, idx.coerceAtLeast(0))
                        },
                    )
                    is ShelfItem.Browse -> BrowseCard(item, onClick = { state.go(Screen.Detail(item)) })
                }
            }
        }
    }
}
