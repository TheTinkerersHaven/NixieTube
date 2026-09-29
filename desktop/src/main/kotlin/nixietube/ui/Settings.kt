@file:Suppress("FunctionName")
// Composables conventionally use UpperCamelCase (Kotlin coding conventions);
// the generic function-name rule does not know that.
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
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
@Composable
fun SettingsScreen(state: AppState) {
    val account by state.account.collectAsState()
    Column(
        Modifier.fillMaxSize().padding(ScreenPadding)
            .verticalScroll(rememberScrollState()),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))
        Text("Account", style = MaterialTheme.typography.headlineSmall)
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
        ListeningHistoryCard()
        Spacer(Modifier.height(24.dp))
        state.sys?.let { LastFmCard(it) }
        Spacer(Modifier.height(24.dp))
        Text(
            "NixieTube • build ${nixietube.BUILD_TAG}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}


/**
 * Renders the MPRIS and Discord Rich Presence toggles.
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
                    Text(
                        "Optional, leave empty for the built-in ID, " +
                            "or paste your own from discord.com/developers/applications",
                    )
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
                "Requires the Discord desktop client running.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Renders the listening-history opt-in: reporting playback to YouTube so it
 * feeds recaps and history.
 */
@Composable
fun ListeningHistoryCard() {
    var reportPlayback by remember { mutableStateOf(nixietube.sys.SysConfig.reportPlayback) }

    Text("Listening history", style = MaterialTheme.typography.headlineSmall)
    Spacer(Modifier.height(8.dp))
    Card(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Sync with YouTube Music")
                Text(
                    "Report played tracks so your YouTube Music history and recaps stay in sync with this app.",
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

/**
 * Renders the Last.fm scrobbling card: credentials, enable toggle, and the browser-approval login.
 *
 * @param sys system handles exposing the Last.fm client and persistence.
 */
@Composable
fun LastFmCard(sys: nixietube.sys.SysHandles) {
    val status by sys.lastfmStatus.collectAsState()
    var enabled by remember { mutableStateOf(nixietube.sys.SysConfig.lastfmEnabled) }
    var apiKey by remember { mutableStateOf(nixietube.sys.SysConfig.lastfmApiKey) }
    var secret by remember { mutableStateOf(nixietube.sys.SysConfig.lastfmSecret) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var token by remember { mutableStateOf<String?>(null) }
    val signedIn = status.startsWith("signed in as")

    Text("Last.fm scrobbling", style = MaterialTheme.typography.headlineSmall)
    Spacer(Modifier.height(8.dp))
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            LastFmHeaderRow(
                enabled = enabled,
                status = status,
                onToggle = {
                    enabled = it
                    sys.saveLastFm(apiKey, secret, it)
                },
            )
            Spacer(Modifier.height(8.dp))
            LastFmCredentialsFields(
                apiKey = apiKey,
                secret = secret,
                onApiKeyChange = {
                    apiKey = it.trim()
                    sys.saveLastFm(apiKey, secret, enabled)
                },
                onSecretChange = {
                    secret = it.trim()
                    sys.saveLastFm(apiKey, secret, enabled)
                },
            )
            Spacer(Modifier.height(12.dp))
            if (failed) {
                Text(
                    "Sign-in failed or was denied. Check the key/secret and try again.",
                    color = MaterialTheme.colorScheme.error,
                )
                Spacer(Modifier.height(8.dp))
            }
            if (signedIn) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { sys.logoutLastFm() }) {
                        Text("Sign out")
                    }
                }
            } else {
                LastFmAuthActions(
                    sys = sys,
                    token = token,
                    busy = busy,
                    apiKeyReady = apiKey.isNotBlank() && secret.isNotBlank(),
                    onStart = {
                        failed = false
                        busy = true
                    },
                    onToken = { token = it },
                    onBusyChange = { busy = it },
                    onFailed = { failed = true },
                    onSignedIn = { token = null },
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "Scrobbles tracks over 30 seconds once half played or 4 minutes pass; " +
                    "now-playing shows on track start.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Renders the Last.fm card header: title, live status, and enable toggle.
 *
 * @param enabled Whether scrobbling is on.
 * @param status Human-readable client state.
 * @param onToggle Invoked with the new toggle value.
 */
@Composable
private fun LastFmHeaderRow(
    enabled: Boolean,
    status: String,
    onToggle: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Scrobble plays")
            Text(
                "Status: $status",
                style = MaterialTheme.typography.bodySmall,
                color = if (status.startsWith("error")) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        }
        Switch(
            checked = enabled,
            onCheckedChange = onToggle,
        )
    }
}

/**
 * Renders the Last.fm API key/secret fields, persisting on every change.
 *
 * @param apiKey Current API key text.
 * @param secret Current shared-secret text.
 * @param onApiKeyChange Invoked with the trimmed key.
 * @param onSecretChange Invoked with the trimmed secret.
 */
@Composable
private fun LastFmCredentialsFields(
    apiKey: String,
    secret: String,
    onApiKeyChange: (String) -> Unit,
    onSecretChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = apiKey,
        onValueChange = { onApiKeyChange(it.trim()) },
        label = { Text("Last.fm API key") },
        supportingText = {
            Text("From a last.fm/api application you create")
        },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = secret,
        onValueChange = { onSecretChange(it.trim()) },
        label = { Text("Last.fm shared secret") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
}

/**
 * Renders the Last.fm browser-approval flow: connect, confirm, or reopen.
 *
 * @param sys System handles exposing the Last.fm client.
 * @param token Pending request token, or null before requesting one.
 * @param busy True while a network step runs.
 * @param apiKeyReady True when key and secret are filled in.
 * @param onStart Begins a step: clears errors and marks busy.
 * @param onToken Stores a fresh request token (null clears it).
 * @param onBusyChange Tracks network activity.
 * @param onFailed Reports a failed step.
 * @param onSignedIn Clears the token after a completed handshake.
 */
@Composable
private fun LastFmAuthActions(
    sys: nixietube.sys.SysHandles,
    token: String?,
    busy: Boolean,
    apiKeyReady: Boolean,
    onStart: () -> Unit,
    onToken: (String?) -> Unit,
    onBusyChange: (Boolean) -> Unit,
    onFailed: () -> Unit,
    onSignedIn: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    if (token == null) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = {
                    onStart()
                    scope.launch {
                        val fresh = sys.lastfm.requestToken()
                        if (fresh != null) {
                            onToken(fresh)
                            openUrl(sys.lastfm.authorizeUrl(fresh))
                        } else {
                            onFailed()
                        }
                        onBusyChange(false)
                    }
                },
                enabled = !busy && apiKeyReady,
            ) {
                Text(if (busy) "Requesting…" else "Connect with last.fm")
            }
        }
        return
    }
    Text(
        "Approve NixieTube in the browser tab, then continue here.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            onClick = {
                onStart()
                scope.launch {
                    if (sys.lastfm.completeAuth(token)) {
                        onSignedIn()
                    } else {
                        onFailed()
                    }
                    onBusyChange(false)
                }
            },
            enabled = !busy,
        ) {
            Text(if (busy) "Verifying…" else "I've authorized it")
        }
        TextButton(onClick = { openUrl(sys.lastfm.authorizeUrl(token)) }) {
            Text("Reopen browser")
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
                ?: "Sign-in failed: the cookie needs a SAPISID value from a logged-in session. Try copying it again.",
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
 * Renders the Google OAuth sign-in card with client-ID fields and browser login.
 *
 * @param state shared app state driving the browser login handshake.
 */
@Composable
fun GoogleSignInCard(state: AppState) {
    var clientId by remember { mutableStateOf(nixietube.sys.SysConfig.googleClientId) }
    var clientSecret by remember { mutableStateOf(nixietube.sys.SysConfig.googleClientSecret) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Sign in with Google", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(4.dp))
            Text(
                "Uses a Desktop-type OAuth client from Google Cloud Console. " +
                    "Approval happens in the browser on this machine, " +
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
                label = { Text("OAuth client ID (Desktop type)") },
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
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        busy = true
                        failed = false
                        state.beginGoogleLogin()
                        state.googleBrowserLogin(
                            onBrowse = { openUrl(it) },
                        ) { ok ->
                            busy = false
                            failed = !ok
                        }
                    },
                    enabled = !busy && clientId.isNotBlank() && clientSecret.isNotBlank(),
                ) {
                    Text(if (busy) "Waiting for browser…" else "Sign in with Google")
                }
                if (busy) {
                    TextButton(onClick = {
                        state.cancelGoogleLogin()
                        busy = false
                    }) { Text("Cancel") }
                }
            }
        }
    }
}
