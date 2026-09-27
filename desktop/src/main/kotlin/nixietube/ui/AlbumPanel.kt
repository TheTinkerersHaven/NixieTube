@file:Suppress("FunctionName")
// Composables conventionally use UpperCamelCase (Kotlin coding conventions);
// the generic function-name rule does not know that.

package nixietube.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import nixietube.innertube.ArtistRef
import nixietube.innertube.RatingStatus
import nixietube.innertube.Track

// Album / playlist: fixed left header column + track list, YTM-style.
// Single shared panel for every collection view (album detail, browsed
// playlist, library playlist, liked songs) so spacing and rows cannot
// drift apart between screens.
/**
 * Shared album/playlist panel with a fixed header column (art, title,
 * author, play/shuffle) and a sortable track list.
 *
 * @param modifier layout modifier.
 * @param state app state used for playback, rating and navigation actions.
 * @param playingId videoId of the currently playing track, or null.
 * @param canRate whether rating controls are shown (signed-in user).
 * @param title collection title.
 * @param subtitle collection subtitle.
 * @param art header artwork URL.
 * @param tracks tracks in the collection.
 * @param blurb short description shown under the header.
 * @param numbered whether track rows show position numbers.
 * @param owner author/owner shown under the title with a profile picture when known.
 * @param ownerAvatar explicit avatar URL for [owner], skipping the lookup when given.
 * @param collageArts artwork URLs rendered as a 2x2 collage when more than one is given.
 * @param listLoading whether to show a spinner when [tracks] is empty.
 */
@Composable
fun AlbumPanel(
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
    owner: ArtistRef? = null,
    ownerAvatar: String? = null,
    collageArts: List<String> = emptyList(),
    listLoading: Boolean = false,
) {
    var sort by remember { mutableIntStateOf(0) }
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
        // Both columns anchor to the top (YTM-style): a centered header
        // drifts away from the top-packed list based on content height,
        // which is what made albums and playlists look inconsistent.
        Column(
            Modifier.width(320.dp).fillMaxHeight().verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Top,
        ) {
            if (collageArts.size > 1) {
                PlaylistArt(null, collageArts, Modifier.size(280.dp))
            } else {
                Artwork(art, Modifier.size(280.dp).clip(CardRadius))
            }
            Spacer(Modifier.height(16.dp))
            Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            if (owner != null && owner.name.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                // Profile picture and artist-page check resolve
                // asynchronously (Data API avatar, else InnerTube artist
                // imagery); the initial box shows meanwhile. Only verified
                // artist pages are clickable — plain user channels are not.
                var avatarUrl by remember(owner.browseId) { mutableStateOf(ownerAvatar) }
                var authorIsArtist by remember(owner.browseId) { mutableStateOf<Boolean?>(null) }
                LaunchedEffect(owner.browseId, ownerAvatar) {
                    val id = owner.browseId
                    avatarUrl = ownerAvatar
                        ?: if (!id.isNullOrBlank()) state.resolveAuthorAvatar(id) else null
                    authorIsArtist = if (!id.isNullOrBlank()) state.isAuthorClickable(id) else false
                }
                val openAuthor = if (authorIsArtist == true) {
                    { state.openArtist(owner) }
                } else {
                    null
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = if (openAuthor != null) Modifier.clickable(onClick = openAuthor) else Modifier,
                ) {
                    if (avatarUrl != null) {
                        Artwork(avatarUrl, Modifier.size(24.dp).clip(CircleShape))
                    } else {
                        Box(
                            Modifier.size(24.dp).clip(CircleShape)
                                .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                owner.name.first().uppercase(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        owner.name,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (openAuthor != null) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
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
                        containerColor = Color.White,
                        contentColor = Color.Black,
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
            verticalArrangement = Arrangement.Top,
        ) {
            if (listLoading && tracks.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val sortLabels = listOf("Default", "Title", "Artist", "Duration")
                    SingleChoiceSegmentedButtonRow {
                        sortLabels.forEachIndexed { i, label ->
                            SegmentedButton(
                                shape = SegmentedButtonDefaults.itemShape(index = i, count = sortLabels.size),
                                onClick = { sort = i },
                                selected = sort == i,
                                label = { Text(label, maxLines = 1) },
                            )
                        }
                    }
                }
                LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false)) {
                    itemsIndexed(sorted, key = { _, t -> t.videoId }) { i, t ->
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
