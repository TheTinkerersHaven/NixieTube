package nixietube.ui

import androidx.compose.foundation.background
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
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
                // Clear the floating back button (48dp at an 8dp offset):
                // without this inset it clips the cover's top-left corner
                // and the sort bar hugs the window top. Library needs no
                // inset, its back button is in-flow chrome above the panel.
                detail.album?.let { album ->
                    AlbumPanel(
                        modifier = Modifier.padding(top = 64.dp),
                        state = state,
                        playingId = player.current?.videoId,
                        canRate = account != null,
                        title = album.title,
                        subtitle = album.subtitle,
                        art = album.thumbnails.maxByOrNull { it.width }?.url,
                        tracks = album.tracks,
                        blurb = album.description,
                        numbered = true,
                        owner = album.artist,
                    )
                } ?: detail.playlist?.let { playlist ->
                    AlbumPanel(
                        modifier = Modifier.padding(top = 64.dp),
                        state = state,
                        playingId = player.current?.videoId,
                        canRate = account != null,
                        title = playlist.title,
                        subtitle = playlist.subtitle,
                        art = playlist.thumbnails.maxByOrNull { it.width }?.url,
                        tracks = playlist.tracks,
                        blurb = "",
                        numbered = false,
                        owner = playlist.author,
                    )
                }
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
                            Text("Shuffle")
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
                                Text(if (subscribed == true) "Subscribed" else "Subscribe")
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
                        "Top songs",
                        style = MaterialTheme.typography.titleLarge,
                        modifier = Modifier.weight(1f),
                    )
                    artist.songsPlaylistId?.let { playlistId ->
                        OutlinedButton(
                            onClick = {
                                state.go(
                                    Screen.Detail(
                                        ShelfItem.Browse(
                                            title = "All songs",
                                            subtitle = "Sorted by plays",
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
            itemsIndexed(artist.topSongs, key = { i, t -> "${t.videoId}@$i" }) { i, t ->
                TrackRow(
                    track = t,
                    index = i + 1,
                    playing = t.videoId == playingId,
                    onPlay = { state.playArtistTopSong(artist, i) },
                    onPlaylists = { state.openPlaylistDialog(t) },
                    showLike = canRate,
                    onLike = { state.rateTrack(t.videoId, RatingStatus.LIKE) },
                    rating = t.rating,
                    onRate = if (canRate) ({ state.rateTrack(t.videoId, it) }) else null,
                )
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
