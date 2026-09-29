package nixietube.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type

/**
 * Root app layout: navigation rail, active screen content, player bar, and now-playing overlay.
 * @param state shared [AppState] holding navigation, player, and screen state.
 */
@Composable
fun App(state: AppState) {
    var showNowPlaying by remember { mutableStateOf(false) }
    val screen by state.screen.collectAsState()
    val player by state.player.state.collectAsState()
    val playlistTrack by state.playlistDialogTrack.collectAsState()

    MaterialTheme(colorScheme = YtmDarkScheme) {
        Scaffold(
            modifier = Modifier.onPreviewKeyEvent { event ->
                val toggleShortcut = event.key == Key.Spacebar && event.type == KeyEventType.KeyDown &&
                    !state.searchFieldFocused && player.current != null
                if (toggleShortcut) {
                    state.player.togglePlayPause()
                    true
                } else {
                    false
                }
            },
            bottomBar = {
                PlayerBar(
                    state = state,
                    onExpand = { showNowPlaying = true },
                )
            },
        ) { padding ->
            Row(Modifier.fillMaxSize().padding(padding)) {
                NavigationRail(
                    header = {
                        Spacer(Modifier.height(8.dp))
                    },
                ) {
                    RailEntry(screen == Screen.Home, Icons.Rounded.Home, "Home") {
                        state.go(Screen.Home)
                    }
                    RailEntry(screen == Screen.Search, Icons.Rounded.Search, "Search") {
                        state.go(Screen.Search)
                    }
                    RailEntry(screen == Screen.Library, Icons.Rounded.LibraryMusic, "Library") {
                        state.go(Screen.Library)
                    }
                    Spacer(Modifier.weight(1f))
                    RailEntry(screen == Screen.Settings, Icons.Rounded.Settings, "Settings") {
                        state.go(Screen.Settings)
                    }
                }
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    when (val s = screen) {
                        is Screen.Home -> HomePanel(state)
                        is Screen.Search -> searchPanel(state)
                        is Screen.Library -> LibraryPanel(state)
                        is Screen.Settings -> SettingsScreen(state)
                        is Screen.Detail -> DetailScreen(state, s.item)
                    }
                }
            }
        }
        // Bottom-sheet motion: the page slides up from the player bar
        // (full height offset) with a fade, and slides back down on close.
        AnimatedVisibility(
            visible = showNowPlaying,
            enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
        ) {
            NowPlaying(state = state, onClose = { showNowPlaying = false })
        }
        playlistTrack?.let { PlaylistPickerDialog(state, it) }
    }
}

/**
 * Single navigation-rail destination entry.
 * @param selected whether this destination is currently active.
 * @param icon icon shown for the entry.
 * @param label text label shown under the icon.
 * @param onClick invoked when the entry is selected.
 */
@Composable
private fun RailEntry(
    selected: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    NavigationRailItem(
        selected = selected,
        onClick = onClick,
        icon = { Icon(icon, label) },
        label = { Text(label) },
    )
}
