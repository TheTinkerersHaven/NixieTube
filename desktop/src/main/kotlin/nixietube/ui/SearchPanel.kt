package nixietube.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import nixietube.innertube.ShelfItem

/**
 * Search screen with query field, category filter chips, history, and grouped results.
 * @param state app state providing search results, history, and playback/navigation actions.
 */
@Composable
fun SearchPanel(state: AppState) {
    val ui by state.search.collectAsState()
    val history by state.searchHistory.collectAsState()
    val player by state.player.state.collectAsState()
    val account by state.account.collectAsState()
    var text by remember { mutableStateOf(ui.query) }
    var selectedCategory by remember(ui.query) { mutableStateOf<String?>(null) }
    LaunchedEffect(ui.query) { text = ui.query }
    val submitSearch = {
        val query = text.trim()
        if (query.isNotEmpty()) state.search(query)
    }
    Column(Modifier.fillMaxSize().padding(ScreenPadding)) {
        androidx.compose.runtime.key(ui.query) {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                label = { Text("Search songs, releases, artists") },
                leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
                trailingIcon = {
                    if (text.isNotEmpty()) {
                        IconButton(onClick = { text = "" }) {
                            Icon(Icons.Rounded.Close, "Clear search")
                        }
                    }
                },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { submitSearch() }),
                modifier = Modifier.fillMaxWidth()
                    .onFocusChanged { state.searchFieldFocused = it.isFocused }
                    .onPreviewKeyEvent { event ->
                        if (event.key == Key.Enter && event.type == KeyEventType.KeyDown) {
                            submitSearch()
                            true
                        } else {
                            false
                        }
                    },
            )
        }
        if (ui.query.isNotBlank()) {
            LazyRow(
                contentPadding = PaddingValues(vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(SearchCategories) { category ->
                    val count = ui.sections[category]?.size ?: 0
                    FilterChip(
                        selected = selectedCategory == category,
                        enabled = count > 0,
                        onClick = { selectedCategory = if (selectedCategory == category) null else category },
                        label = { Text(if (count > 0) "$category ($count)" else category) },
                    )
                }
            }
        }
        if (ui.loading) {
            Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
        ui.error?.let { ErrorBox(it) { state.search(text) } }
        if (!ui.loading && ui.error == null && ui.sections.isEmpty()) {
            if (ui.query.isNotBlank()) {
                Text(
                    "No results for \"${ui.query}\"",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
            if (history.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Recent searches",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f).padding(vertical = 8.dp),
                    )
                    TextButton(onClick = { state.clearSearchHistory() }) {
                        Text("Clear")
                    }
                }
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(bottom = 8.dp),
                ) {
                    items(history, key = { it }) { past ->
                        SuggestionChip(
                            onClick = {
                                text = past
                                state.search(past)
                            },
                            label = { Text(past, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        )
                    }
                }
            } else {
                Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text(
                        "Search for songs, albums, or artists",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
            ui.sections.forEach { (title, items) ->
                if (selectedCategory != null && selectedCategory != title) return@forEach
                val songs = items.filterIsInstance<ShelfItem.Song>().map { it.track }
                item(key = "h-$title") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            title,
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f).padding(vertical = 8.dp),
                        )
                        if (title == "Songs" && songs.isNotEmpty()) {
                            TextButton(onClick = { state.playSongs(songs, 0) }) {
                                Text("Play all")
                            }
                        }
                    }
                }
                itemsIndexed(
                    items,
                    key = { _, item ->
                        when (item) {
                            is ShelfItem.Song -> "s-" + item.track.videoId
                            is ShelfItem.Browse -> "b-" + item.browseId
                        }
                    },
                ) { _, item ->
                    when (item) {
                        is ShelfItem.Song -> TrackRow(
                            track = item.track,
                            playing = item.track.videoId == player.current?.videoId,
                            onPlay = {
                                val idx = songs.indexOf(item.track)
                                state.playSongs(songs, idx.coerceAtLeast(0))
                            },
                            onEnqueue = { state.player.enqueueNext(item.track) },
                            rating = item.track.rating,
                            onRate = if (account != null) {
                                ({ state.rateTrack(item.track.videoId, it) })
                            } else {
                                null
                            },
                        )
                        is ShelfItem.Browse -> ListItem(
                            modifier = Modifier.clickable { state.go(Screen.Detail(item)) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                            leadingContent = {
                                Artwork(
                                    item.thumbnails.maxByOrNull { t -> t.width }?.url,
                                    Modifier.size(48.dp).clip(RowArtRadius),
                                )
                            },
                            headlineContent = { Text(item.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            supportingContent = { Text(item.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        )
                    }
                }
            }
        }
    }
}

/** Result section names offered as filter chips on the search screen. */
private val SearchCategories = listOf("Songs", "Albums/EP/Singles", "Artists")
