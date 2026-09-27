package nixietube.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Button
import androidx.compose.material3.Tab
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.key
import nixietube.innertube.ArtistRef

/**
 * Renders the Library screen with Playlists/Artists/Liked tabs, or the open playlist detail.
 *
 * Shows a sign-in prompt when logged out and a loading spinner while the library first loads.
 *
 * @param state shared app state backing the library flows and playback actions.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(state: AppState) {
    val account by state.account.collectAsState()
    val playlists by state.playlists.collectAsState()
    val liked by state.liked.collectAsState()
    val artists by state.artists.collectAsState()
    val openPl by state.openPlaylist.collectAsState()
    val accountAvatar by state.accountAvatar.collectAsState()
    val libLoading by state.libraryLoading.collectAsState()
    val player by state.player.state.collectAsState()
    var tab by remember { mutableIntStateOf(0) }
    Column(Modifier.fillMaxSize().padding(ScreenPadding)) {
        if (openPl == null) {
            Text("Library", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(16.dp))
        }
        if (account == null) {
            Text(
                "Your playlists, liked songs and followed artists live here once you're signed in.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            Button(onClick = { state.go(Screen.Settings) }) { Text("Open Settings") }
            return@Column
        }
        if (libLoading && playlists.isEmpty() && liked.isEmpty() && artists.isEmpty() && openPl == null) {
            Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            return@Column
        }
        openPl?.let { (pl, tracks) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { state.closePlaylist() }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                }
                Text("Library", style = MaterialTheme.typography.headlineSmall)
            }
            Spacer(Modifier.height(8.dp))
            AlbumPanel(
                modifier = Modifier.weight(1f),
                state = state,
                playingId = player.current?.videoId,
                canRate = account != null,
                title = pl.title,
                // The owner already has its own avatar row and the count
                // comes from the stats line; repeating either here
                // duplicates them.
                subtitle = if (pl.id == "__liked") {
                    "Automatic playlist"
                } else {
                    ""
                },
                art = pl.art,
                tracks = tracks,
                blurb = "",
                numbered = false,
                owner = if (pl.id == "__liked") {
                    ArtistRef(account.orEmpty())
                } else {
                    ArtistRef(pl.owner, pl.ownerId.takeIf { it.isNotBlank() })
                },
                ownerAvatar = if (pl.id == "__liked") accountAvatar else null,
                collageArts = pl.arts,
                listLoading = tracks.isEmpty() && libLoading,
            )
            return@Column
        }
        Column(Modifier.fillMaxSize()) {
        PrimaryTabRow(
            selectedTabIndex = tab,
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ) {
            Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("Playlists (${playlists.size})") })
            Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("Artists (${artists.size})") })
            Tab(selected = tab == 2, onClick = { tab = 2 }, text = { Text("Liked (${liked.size})") })
        }
        Spacer(Modifier.height(16.dp))
        when (tab) {
            0 -> {
                if (playlists.isEmpty()) {
                    Text(
                        "No playlists yet — create some on YouTube Music.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
                        val cols = ((maxWidth / 150.dp).toInt())
                            .coerceIn(2, 8)
                            .coerceAtMost(playlists.size.coerceAtLeast(1))
                        // Explicit card width with a hard upper bound: weight
                        // columns stretch to fill the window, so a max-only
                        // cap on the card is ignored (exact constraints).
                        val cardWidth = minOf(maxWidth / cols, 180.dp)
                        Column(Modifier.verticalScroll(rememberScrollState())) {
                            repeat((playlists.size + cols - 1) / cols) { row ->
                                Row(
                                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    repeat(cols) { col ->
                                        val pl = playlists.getOrNull(row * cols + col)
                                        if (pl == null) {
                                            Spacer(Modifier.width(cardWidth))
                                        } else {
                                            QuickPickCard(
                                                title = pl.title,
                                                subtitle = if (pl.id == "__liked") {
                                                    "Automatic playlist"
                                                } else if (pl.owner.isNotBlank()) {
                                                    "${pl.owner} • ${pl.itemCount} songs"
                                                } else {
                                                    "${pl.itemCount} songs"
                                                },
                                                art = pl.arts.firstOrNull() ?: pl.art,
                                                playing = false,
                                                onClick = { state.openPlaylist(pl) },
                                                modifier = Modifier.width(cardWidth),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            1 -> {
                val recentArtists by state.recentArtists.collectAsState()
                if (artists.isEmpty() && recentArtists.isEmpty()) {
                    Text(
                        "No followed artists yet — subscribe on YouTube Music.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                        if (artists.isNotEmpty()) {
                            ArtistBrowseRail("Followed", artists, state, circular = true)
                        }
                        if (recentArtists.isNotEmpty()) {
                            Text(
                                "Recently listened",
                                style = MaterialTheme.typography.titleMedium,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                            recentArtists.forEach { artist ->
                                ListItem(
                                    modifier = Modifier.clickable { state.go(Screen.Detail(artist)) },
                                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                                    leadingContent = {
                                        Artwork(
                                            artist.thumbnails.maxByOrNull { it.width }?.url,
                                            Modifier.size(48.dp).clip(CircleShape),
                                        )
                                    },
                                    headlineContent = { Text(artist.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                    supportingContent = { Text("Recently listened") },
                                )
                            }
                        }
                    }
                }
            }
            else -> {
                if (liked.isEmpty()) {
                    Text(
                        "Songs you like will appear here.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${liked.size} songs",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { state.playSongs(liked, 0) }) {
                            Text("Play all")
                        }
                        IconButton(onClick = { state.playShuffled(liked) }) {
                            Icon(Icons.Rounded.Shuffle, "Shuffle liked songs")
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                        itemsIndexed(liked, key = { _, t -> t.videoId }) { i, t ->
                            TrackRow(
                                track = t,
                                playing = t.videoId == player.current?.videoId,
                                onPlay = { state.playSongs(liked, i) },
                                onEnqueue = { state.player.enqueueNext(t) },
                                rating = t.rating,
                                onRate = ({ state.rateTrack(t.videoId, it) }),
                            )
                        }
                    }
                }
            }
        }
    }
}
}
