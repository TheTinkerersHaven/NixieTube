package nixietube.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Button
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import nixietube.sys.SysConfig

/**
 * Renders the Settings screen with account, playback and desktop-integration sections.
 *
 * @param state shared app state backing sign-in state and system handles.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(state: AppState) {
    val account by state.account.collectAsState()
    Column(
        Modifier.fillMaxSize().padding(ScreenPadding)
            .verticalScroll(rememberScrollState()),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))
        Text("Account", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        if (account == null) {
            GoogleSignInCard(state)
            Spacer(Modifier.height(24.dp))
            CookieSignInCard(state)
        } else {
            val avatar by state.accountAvatar.collectAsState()
            val fullAccess = state.innerTubeAuthed
            Card {
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (avatar.isNullOrBlank()) {
                        Icon(Icons.Rounded.Person, null, modifier = Modifier.size(40.dp))
                    } else {
                        Artwork(
                            avatar,
                            Modifier.size(40.dp).clip(CircleShape),
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(account!!, style = MaterialTheme.typography.titleMedium)
                        Text(
                            if (fullAccess) "Signed in • full access" else "Signed in • limited",
                            style = MaterialTheme.typography.bodySmall,
                            color = if (fullAccess) {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            } else {
                                MaterialTheme.colorScheme.primary
                            },
                        )
                    }
                    TextButton(onClick = { state.logout() }) { Text("Sign out") }
                }
            }
            if (!fullAccess) {
                Spacer(Modifier.height(16.dp))
                Text(
                    "Limited session: library and likes work, but mixes, personalized home " +
                        "and complete like-state need a browser cookie (it unlocks InnerTube; " +
                        "your Google sign-in keeps working alongside it).",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(16.dp))
                CookieSignInCard(state)
            }
        }
        Spacer(Modifier.height(24.dp))
        state.sys?.let { IntegrationsCard(it) }
        Spacer(Modifier.height(24.dp))
        Text(
            "NixieTube • build ${nixietube.BUILD_TAG}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}


/**
 * Renders the MPRIS, Discord Rich Presence and playback-reporting toggles.
 *
 * @param sys system handles exposing integration state and persistence.
 */
@Composable
fun IntegrationsCard(sys: nixietube.sys.SysHandles) {
    val mprisActive by sys.mprisActive.collectAsState()
    val mprisError by sys.mprisError.collectAsState()
    val discordStatus by sys.discordStatus.collectAsState()
    var mprisOn by remember { mutableStateOf(nixietube.sys.SysConfig.mprisEnabled) }
    var discordOn by remember { mutableStateOf(nixietube.sys.SysConfig.discordEnabled) }
    var appId by remember { mutableStateOf(nixietube.sys.SysConfig.discordAppIdRaw) }
    var statusText by remember { mutableStateOf(nixietube.sys.SysConfig.discordStatusText) }

    Text("Desktop integrations", style = MaterialTheme.typography.headlineSmall)
    Spacer(Modifier.height(8.dp))
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("MPRIS (media keys, playerctl)")
                    Text(
                        mprisError ?: if (!sys.isLinux) {
                            "Linux only"
                        } else if (mprisActive) {
                            "Active on the session bus"
                        } else {
                            "Inactive"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (mprisError != null) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
                Switch(
                    checked = mprisOn,
                    enabled = sys.isLinux,
                    onCheckedChange = {
                        mprisOn = it
                        sys.setMprisEnabled(it)
                    },
                )
            }
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Discord Rich Presence")
                    Text(
                        "Status: $discordStatus",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = discordOn,
                    onCheckedChange = {
                        discordOn = it
                        sys.saveDiscord(appId, it, statusText)
                    },
                )
            }
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = appId,
                onValueChange = {
                    appId = it
                    sys.saveDiscord(it, discordOn, statusText)
                },
                label = { Text("Discord application ID") },
                placeholder = { Text(SysConfig.DEFAULT_DISCORD_APP_ID) },
                supportingText = {
                    Text("Optional — defaults to the built-in application ID")
                },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            Spacer(Modifier.height(12.dp))
            Text("Status text", style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(4.dp))
            val statusOptions = nixietube.sys.DiscordStatusText.entries
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                statusOptions.forEachIndexed { index, option ->
                    SegmentedButton(
                        shape = SegmentedButtonDefaults.itemShape(
                            index = index,
                            count = statusOptions.size,
                        ),
                        onClick = {
                            statusText = option.key
                            sys.saveDiscord(appId, discordOn, option.key)
                        },
                        selected = statusText == option.key,
                        label = { Text(option.label) },
                    )
                }
            }
            Text(
                "Choose what Discord shows as the activity name. " +
                    "The song and artist remain in the lower activity fields.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Optional. Leave empty to use the built-in application ID " +
                    "(${SysConfig.DEFAULT_DISCORD_APP_ID}), or paste your own from " +
                    "discord.com/developers/applications. Requires the Discord desktop client running.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(16.dp))
            var reportPlayback by remember { mutableStateOf(nixietube.sys.SysConfig.reportPlayback) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Report playback to recaps")
                    Text(
                        "Send play/pause/progress events so listening history feeds into YouTube recaps.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = reportPlayback,
                    onCheckedChange = {
                        reportPlayback = it
                        nixietube.sys.SysConfig.reportPlayback = it
                    },
                )
            }
        }
    }
}

/** Renders the browser-cookie sign-in form with DevTools copy instructions. */
@Composable
private fun CookieSignInCard(state: AppState) {
    var cookie by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val loginDetail by state.loginDetail.collectAsState()
    Text("…or sign in with a browser cookie", style = MaterialTheme.typography.titleMedium)
    Text(
        "Sign in with your YouTube Music account to see your library, likes and playlists.",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(16.dp))
    Text(
        "1. In your browser, open music.youtube.com while logged in.\n" +
            "2. Open DevTools (F12) → Network tab, then play any song.\n" +
            "3. Click any 'youtubei/v1/' request → Headers → 'view source' → copy the whole 'Cookie' value.\n" +
            "The app derives the auth signature itself and never sends your cookie anywhere but YouTube.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(12.dp))
    OutlinedTextField(
        value = cookie, onValueChange = { cookie = it },
        label = { Text("Cookie header value") }, modifier = Modifier.fillMaxWidth(),
        minLines = 3,
    )
    Spacer(Modifier.height(12.dp))
    if (failed) {
        Text(
            loginDetail
                ?: "Sign-in failed — the cookie needs a SAPISID value from a logged-in session. Try copying it again.",
            color = MaterialTheme.colorScheme.error,
        )
        Spacer(Modifier.height(8.dp))
    }
    Button(
        onClick = {
            busy = true
            failed = false
            state.login(cookie) { ok ->
                busy = false
                failed = !ok
            }
        },
        enabled = !busy && cookie.isNotBlank(),
    ) {
        Text(if (busy) "Verifying…" else "Sign in")
    }
}

// Opens a URL in the system browser without AWT: xdg-open on Linux
// (Desktop.browse drags in the AWT toolkit for the same syscall),
// Desktop API elsewhere as a fallback.
/** Opens [url] in the system browser via xdg-open on Linux, else the Desktop API. */
private fun openUrl(url: String) {
    if (System.getProperty("os.name").lowercase().contains("linux")) {
        if (runCatching { ProcessBuilder("xdg-open", url).start(); }.isSuccess) return
    }
    runCatching { java.awt.Desktop.getDesktop().browse(java.net.URI(url)) }
}

/**
 * Renders the Google TV-device OAuth sign-in card with client-ID fields and device-code flow.
 *
 * @param state shared app state driving the device login handshake.
 */
@Composable
fun GoogleSignInCard(state: AppState) {
    var clientId by remember { mutableStateOf(nixietube.sys.SysConfig.googleClientId) }
    var clientSecret by remember { mutableStateOf(nixietube.sys.SysConfig.googleClientSecret) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var userCode by remember { mutableStateOf<String?>(null) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Sign in with Google", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(4.dp))
            Text(
                "Uses a TV-device OAuth client from Google Cloud Console. " +
                    "You get a short code, approve it at google.com/device, " +
                    "and tokens stay on this machine with auto-refresh.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = clientId,
                onValueChange = {
                    clientId = it
                    nixietube.sys.SysConfig.googleClientId = it
                },
                label = { Text("OAuth client ID (TV / Limited Input type)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = clientSecret,
                onValueChange = {
                    clientSecret = it
                    nixietube.sys.SysConfig.googleClientSecret = it
                },
                label = { Text("OAuth client secret") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            Spacer(Modifier.height(12.dp))
            if (failed) {
                Text(
                    "Sign-in failed, denied or expired. Check the client ID/secret and try again.",
                    color = MaterialTheme.colorScheme.error,
                )
                Spacer(Modifier.height(8.dp))
            }
            userCode?.let { code ->
                Text(
                    "Enter this code at google.com/device:",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(code, style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(8.dp))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        busy = true
                        failed = false
                        userCode = null
                        state.beginGoogleLogin()
                        state.googleLogin(
                            onUserCode = { code, url ->
                                userCode = code
                                openUrl(url)
                            },
                        ) { ok ->
                            busy = false
                            failed = !ok
                            if (ok) userCode = null
                        }
                    },
                    enabled = !busy && clientId.isNotBlank() && clientSecret.isNotBlank(),
                ) {
                    Text(if (busy) "Waiting for approval…" else "Sign in with Google")
                }
                if (busy) {
                    TextButton(onClick = {
                        state.cancelGoogleLogin()
                        busy = false
                        userCode = null
                    }) { Text("Cancel") }
                }
            }
        }
    }
}
