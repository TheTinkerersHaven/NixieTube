package nixietube.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Image
import androidx.compose.ui.input.key.key
import kotlinx.coroutines.launch
import nixietube.innertube.RatingStatus
import nixietube.innertube.ShelfItem
import nixietube.innertube.Track
import nixietube.innertube.upscaledTo

/**
 * Detail page routing to artist or album/playlist views, with loading/error states and a back button.
 * @param state app state providing the loaded detail and navigation.
 * @param item the browse item this detail page is for.
 */
@Composable
fun DetailScreen(state: AppState, item: ShelfItem.Browse) {
    val detail by state.detail.collectAsState()
    val player by state.player.state.collectAsState()
    val account by state.account.collectAsState()
    val canGoBack by state.canGoBack.collectAsState()

    Box(Modifier.fillMaxSize()) {
        when {
            detail.loading -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            detail.error != null -> {
                ErrorBox(detail.error!!) { state.go(Screen.Detail(item)) }
            }
            detail.artist != null -> {
                ArtistDetailView(
                    state = state,
                    item = item,
                    artist = detail.artist!!,
                    playingId = player.current?.videoId,
                    canRate = account != null,
                )
            }
            detail.album != null || detail.playlist != null -> {
                val d = detail
                val (title, subtitle, art, tracks, blurb) = if (d.album != null) {
                    Quint(
                        d.album.title,
                        d.album.subtitle,
                        d.album.thumbnails.maxByOrNull { it.width }?.url,
                        d.album.tracks,
                        d.album.description,
                    )
                } else {
                    val playlist = d.playlist!!
                    Quint(
                        playlist.title,
                        playlist.subtitle,
                        playlist.thumbnails.maxByOrNull { it.width }?.url,
                        playlist.tracks,
                        "",
                    )
                }
                CollectionDetailView(
                    state = state,
                    playingId = player.current?.videoId,
                    canRate = account != null,
                    title = title,
                    subtitle = subtitle,
                    art = art,
                    tracks = tracks,
                    blurb = blurb,
                    numbered = detail.album != null,
                )
            }
            else -> {
                ErrorBox("Detail unavailable") { state.go(Screen.Detail(item)) }
            }
        }

        // Keep the control transparent over the page. In particular, it must
        // not consume a separate opaque bar above an artist banner.
        Box(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(8.dp)
                .size(48.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.28f)),
            contentAlignment = Alignment.Center,
        ) {
            IconButton(onClick = { state.goBack() }, enabled = canGoBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
            }
        }
    }
}

/**
 * Normalized album/playlist header data passed to [CollectionDetailView].
 * @property title collection title.
 * @property subtitle collection subtitle.
 * @property art header artwork URL.
 * @property tracks tracks in the collection.
 * @property blurb short description text.
 */
private data class Quint(
    val title: String,
    val subtitle: String,
    val art: String?,
    val tracks: List<Track>,
    val blurb: String,
)

// Album / playlist: fixed left header column + track list, YTM-style.
/**
 * Album/playlist view with a fixed header column (art, title, play/shuffle) and a sortable track list.
 * @param modifier layout modifier.
 * @param state app state used for playback and rating actions.
 * @param playingId videoId of the currently playing track, or null.
 * @param canRate whether rating controls are shown (signed-in user).
 * @param title collection title.
 * @param subtitle collection subtitle.
 * @param art header artwork URL.
 * @param tracks tracks in the collection.
 * @param blurb short description shown under the header.
 * @param numbered whether track rows show position numbers.
 * @param ownerName playlist owner name shown under the title when non-blank.
 * @param collageArts artwork URLs rendered as a 2x2 collage when more than one is given.
 * @param listLoading whether to show a spinner when [tracks] is empty.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CollectionDetailView(
    modifier: Modifier = Modifier,
    state: AppState,
    playingId: String?,
    canRate: Boolean,
    title: String,
    subtitle: String,
    art: String?,
    tracks: List<Track>,
    blurb: String,
    numbered: Boolean,
    ownerName: String = "",
    collageArts: List<String> = emptyList(),
    listLoading: Boolean = false,
) {
    var sort by remember { mutableIntStateOf(0) }
    var sortOpen by remember { mutableStateOf(false) }
    val sorted = remember(tracks, sort) {
        when (sort) {
            1 -> tracks.sortedBy { it.title.lowercase() }
            2 -> tracks.sortedBy { it.artistNames.lowercase() }
            3 -> tracks.sortedByDescending { it.durationSec }
            else -> tracks
        }
    }
    val totalSec = tracks.sumOf { it.durationSec }
    val stats = buildList {
        if (tracks.isNotEmpty()) add("${tracks.size} songs")
        if (totalSec > 0) {
            add(if (totalSec >= 3600) "${totalSec / 3600} hr ${totalSec % 3600 / 60} min" else "${totalSec / 60} min")
        }
    }.joinToString(" • ")
    Row(modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        Column(
            Modifier.width(320.dp).fillMaxHeight().verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            if (collageArts.size > 1) {
                PlaylistArt(null, collageArts, Modifier.size(280.dp))
            } else {
                Artwork(art, Modifier.size(280.dp).clip(CardRadius))
            }
            Spacer(Modifier.height(16.dp))
            Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            if (ownerName.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(24.dp).clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            ownerName.first().uppercase(),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        ownerName,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(4.dp))
            if (subtitle.isNotBlank()) {
                Text(
                    subtitle, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center, maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (stats.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    stats, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
            if (blurb.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    blurb.take(280), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center, maxLines = 5,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(20.dp))
            // Play sits dead-center; shuffle anchors to its left. No phantom
            // spacer balancing, so the circle can't drift off-center.
            Box(Modifier.fillMaxWidth()) {
                FilledIconButton(
                    onClick = { state.playSongs(tracks, 0) },
                    enabled = tracks.isNotEmpty(),
                    modifier = Modifier.align(Alignment.Center).size(64.dp),
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = androidx.compose.ui.graphics.Color.White,
                        contentColor = androidx.compose.ui.graphics.Color.Black,
                    ),
                ) {
                    Icon(Icons.Rounded.PlayArrow, "Play", modifier = Modifier.size(36.dp))
                }
                IconButton(
                    onClick = { state.playShuffled(tracks) },
                    enabled = tracks.isNotEmpty(),
                    modifier = Modifier.align(Alignment.CenterStart).padding(start = 24.dp),
                ) {
                    Icon(
                        Icons.Rounded.Shuffle, "Shuffle play",
                        modifier = Modifier.size(28.dp),
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
        }
        Spacer(Modifier.width(24.dp))
        Column(
            Modifier.weight(1f).fillMaxHeight(),
            verticalArrangement = Arrangement.Center,
        ) {
            if (listLoading && tracks.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { sortOpen = true }) {
                        Text("Ordina")
                    }
                    DropdownMenu(expanded = sortOpen, onDismissRequest = { sortOpen = false }) {
                        val labels = listOf("Default order", "Title", "Artist", "Duration")
                        labels.forEachIndexed { i, label ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = { sort = i; sortOpen = false },
                            )
                        }
                    }
                }
                LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false)) {
                    itemsIndexed(sorted, key = { _, t -> t.videoId }) { i, t ->
                        val origIdx = tracks.indexOf(t)
                        TrackRow(
                            track = t,
                            index = if (numbered) i + 1 else null,
                            playing = t.videoId == playingId,
                            onPlay = { state.playSongs(sorted, i) },
                            onEnqueue = { state.player.enqueueNext(t) },
                            showLike = canRate,
                            onLike = { state.rateTrack(t.videoId, RatingStatus.LIKE) },
                            rating = t.rating,
                            onRate = if (canRate) ({ state.rateTrack(t.videoId, it) }) else null,
                        )
                    }
                }
            }
        }
    }
}
// Artist: banner header, action pills, top-songs table, and discovery rails.
/**
 * Artist view with banner header, shuffle/radio/subscribe actions, top songs, rails, and bio.
 * @param state app state used for playback, radio, subscription, and navigation.
 * @param item the artist browse item this page is for.
 * @param artist loaded artist detail content.
 * @param playingId videoId of the currently playing track, or null.
 * @param canRate whether rating controls are shown (signed-in user).
 */
@Composable
fun ArtistDetailView(
    state: AppState,
    item: ShelfItem.Browse,
    artist: nixietube.innertube.ArtistDetail,
    playingId: String?,
    canRate: Boolean,
) {
    val scope = rememberCoroutineScope()
    val gdata = state.gdata
    var subscribed by remember(item.browseId) { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(item.browseId) {
        subscribed = null
        val api = gdata
        if (api != null) {
            subscribed = try {
                api.subscriptionId(item.browseId) != null
            } catch (_: Exception) {
                null
            }
        }
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item(key = "banner") {
            // The box follows the loaded image aspect (like the reference)
            // instead of a fixed height, so wide banners show fully instead
            // of cropping heads. Clamped to sane bounds; placeholder while
            // loading.
            val bannerUrl = artist.thumbnails.maxByOrNull { it.width }
                ?.upscaledTo(1920)?.url
            val bitmap = rememberSourceArtwork(bannerUrl)
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val boxHeight = if (bitmap != null && bitmap.width > 0 && bitmap.height > 0) {
                    ((maxWidth.value * bitmap.height / bitmap.width).dp).coerceIn(320.dp, 560.dp)
                } else {
                    460.dp
                }
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(boxHeight)
                        .clipToBounds(),
                ) {
                    if (bitmap != null) {
                        Image(
                            bitmap = bitmap,
                            contentDescription = null,
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Crop,
                            alignment = Alignment.Center,
                        )
                    }
                    Box(
                        Modifier.fillMaxSize().background(
                            androidx.compose.ui.graphics.Brush.verticalGradient(
                                0f to androidx.compose.ui.graphics.Color.Transparent,
                                0.5f to androidx.compose.ui.graphics.Color.Transparent,
                                1f to MaterialTheme.colorScheme.background,
                            ),
                        ),
                    )
                }
            }
                Column(
                    Modifier.fillMaxSize().padding(ScreenPadding),
                    verticalArrangement = Arrangement.Bottom,
                ) {
                    Text(artist.name, style = MaterialTheme.typography.displaySmall)
                    if (artist.subscribers.isNotBlank()) {
                        Text(
                            artist.subscribers,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = { state.playArtistSongs(artist, shuffled = true) },
                            enabled = artist.topSongs.isNotEmpty(),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = androidx.compose.ui.graphics.Color.White,
                                contentColor = androidx.compose.ui.graphics.Color.Black,
                            ),
                        ) {
                            Icon(Icons.Rounded.Shuffle, null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Casuale")
                        }
                        OutlinedButton(
                            onClick = { state.startArtistRadio(artist) },
                            enabled = artist.topSongs.isNotEmpty(),
                        ) {
                            Text("Mix")
                        }
                        if (gdata != null) {
                            OutlinedButton(
                                onClick = {
                                    scope.launch {
                                        val api = gdata
                                        if (subscribed == true) {
                                            val id = try {
                                                api.subscriptionId(item.browseId)
                                            } catch (_: Exception) {
                                                null
                                            }
                                            if (id != null && api.unsubscribe(id)) subscribed = false
                                        } else {
                                            if (api.subscribe(item.browseId)) subscribed = true
                                        }
                                    }
                                },
                            ) {
                                Text(if (subscribed == true) "Iscritto" else "Iscriviti")
                            }
                        }
                    }
                }
            }
        if (artist.topSongs.isNotEmpty()) {
            item(key = "tops-h") {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Brani più ascoltati",
                        style = MaterialTheme.typography.titleLarge,
                        modifier = Modifier.weight(1f),
                    )
                    artist.songsPlaylistId?.let { playlistId ->
                        OutlinedButton(
                            onClick = {
                                state.go(
                                    Screen.Detail(
                                        ShelfItem.Browse(
                                            title = "Tutti i brani",
                                            subtitle = "Ordinati per ascolti",
                                            browseId = playlistId,
                                            thumbnails = emptyList(),
                                            browseParams = artist.songsPlaylistParams,
                                        ),
                                    ),
                                )
                            },
                        ) {
                            Text("See all")
                        }
                    }
                }
            }
            itemsIndexed(artist.topSongs, key = { _, t -> t.videoId }) { i, t ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        state.playArtistTopSong(artist, i)
                    }.padding(horizontal = 20.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Artwork(t.displayArtwork, Modifier.size(40.dp).clip(RowArtRadius))
                    Spacer(Modifier.width(12.dp))
                    Text(
                        t.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(3f),
                        color = if (t.videoId == playingId) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        t.artistNames, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(2f),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        t.views.ifBlank { if (t.durationSec > 0) fmtDur(t.durationSec) else "" },
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(2f),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        t.album?.name.orEmpty(), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(2f),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        if (artist.albums.isNotEmpty()) {
            item(key = "albums-r") {
                ArtistBrowseRail("Albums", artist.albums, state)
            }
        }
        if (artist.singlesAndEps.isNotEmpty()) {
            item(key = "singles-r") {
                ArtistBrowseRail("Singles & EPs", artist.singlesAndEps, state)
            }
        }
        if (artist.relatedPlaylists.isNotEmpty()) {
            item(key = "playlists-r") {
                ArtistBrowseRail("Related playlists", artist.relatedPlaylists, state)
            }
        }
        if (artist.similarArtists.isNotEmpty()) {
            item(key = "similar-r") {
                ArtistBrowseRail("Similar artists", artist.similarArtists, state, circular = true)
            }
        }
        if (artist.description.isNotBlank()) {
            item(key = "about") {
                Column(Modifier.padding(20.dp)) {
                    Text("Info", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        artist.description.take(600),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/**
 * Playlist artwork: 2x2 collage when several arts are given, single artwork otherwise.
 * @param art fallback artwork URL used when [arts] has at most one entry.
 * @param arts artwork URLs for the collage tiles.
 * @param modifier layout modifier.
 */
@Composable
private fun PlaylistArt(art: String?, arts: List<String>, modifier: Modifier = Modifier) {
    if (arts.size > 1) {
        Column(modifier.clip(CardRadius)) {
            Row(Modifier.weight(1f)) {
                Artwork(arts.getOrNull(0), Modifier.weight(1f).fillMaxHeight())
                Artwork(arts.getOrNull(1), Modifier.weight(1f).fillMaxHeight())
            }
            Row(Modifier.weight(1f)) {
                Artwork(arts.getOrNull(2), Modifier.weight(1f).fillMaxHeight())
                Artwork(arts.getOrNull(3), Modifier.weight(1f).fillMaxHeight())
            }
        }
    } else {
        Artwork(art, modifier.clip(CardRadius))
    }
}
