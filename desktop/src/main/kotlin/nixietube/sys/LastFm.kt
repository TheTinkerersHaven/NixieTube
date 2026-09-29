package nixietube.sys

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.forms.submitForm
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.parameters
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import nixietube.player.PlayerState
import java.security.MessageDigest

/** Last.fm API endpoint for all signed calls. */
private const val LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/"

/** Browser URL where the user approves a request token. */
private const val LASTFM_AUTH_URL = "https://www.last.fm/api/auth/"

/** Minimum track length worth scrobbling, in seconds (Last.fm rule). */
private const val MIN_SCROBBLE_DURATION_SEC = 30

/** Scrobble once playback passes this many seconds regardless of track length. */
private const val SCROBBLE_CAP_SEC = 240

/** Milliseconds per second for threshold math. */
private const val MS_PER_SECOND = 1000L

/** Backward seek that counts as a restarted play rather than a position update. */
private const val SEEK_BACK_TOLERANCE_MS = 2000L

/** Max characters of an error message kept in status text. */
private const val ERROR_SNIPPET_LEN = 80

/** User-Agent sent with Last.fm API calls. */
private const val LASTFM_USER_AGENT = "NixieTube/1.0"

// Last.fm scrobbling over the ws.audioscrobbler.com API: session auth
// (request token approved in the browser), MD5-signed calls, now-playing
// updates on track start, and scrobbles once the standard playback
// threshold is reached (half the track or 4 minutes, tracks over 30s).
// Credentials live in SysConfig; nothing is sent when disabled or logged out.
/**
 * Last.fm client: web-auth handshake, now-playing updates, and scrobbles.
 *
 * API key/secret come from the user's own last.fm/api application stored in
 * [SysConfig]; the session key persists there after the browser approval.
 * All network use is opt-in via [SysConfig.lastfmEnabled].
 *
 * @param scope Scope for the playback watcher.
 */
class LastFm(
    internal val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val http = HttpClient(CIO)
    private val json = Json { ignoreUnknownKeys = true }

    /** Human-readable state: "disabled", "signed in as …", "signed out", or "error: …". */
    @Volatile
    var status: String = "disabled"
        private set

    /** Currently linked Last.fm username, or empty when logged out. */
    val username: String get() = SysConfig.lastfmUsername

    /** True when scrobbling can run: enabled, keyed, and holding a session. */
    internal fun ready(): Boolean =
        SysConfig.lastfmEnabled &&
            SysConfig.lastfmApiKey.isNotBlank() &&
            SysConfig.lastfmSecret.isNotBlank() &&
            SysConfig.lastfmSessionKey.isNotBlank()

    /**
     * Requests a fresh auth token for the browser approval step.
     *
     * @return The token, or null when the key/secret are missing or rejected.
     */
    suspend fun requestToken(): String? {
        val key = SysConfig.lastfmApiKey.trim()
        val secret = SysConfig.lastfmSecret.trim()
        if (key.isBlank() || secret.isBlank()) {
            status = "error: API key and secret are required"
            return null
        }
        return try {
            val el = signedCall(
                mapOf("method" to "auth.getToken", "api_key" to key),
                secret,
            )
            el.jsonObject["token"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
                ?: run {
                    status = "error: ${lastfmError(el)}"
                    null
                }
        } catch (e: Exception) {
            status = "error: ${e.message?.take(ERROR_SNIPPET_LEN) ?: "request failed"}"
            null
        }
    }

    /**
     * Browser URL where the user approves a request token.
     *
     * @param token Token from [requestToken].
     */
    fun authorizeUrl(token: String): String =
        "$LASTFM_AUTH_URL?api_key=${SysConfig.lastfmApiKey.trim()}&token=$token"

    /**
     * Exchanges an approved request token for a session, persisting it.
     *
     * @param token Token the user already approved in the browser.
     * @return True when a session was stored.
     */
    suspend fun completeAuth(token: String): Boolean {
        val key = SysConfig.lastfmApiKey.trim()
        val secret = SysConfig.lastfmSecret.trim()
        if (key.isBlank() || secret.isBlank() || token.isBlank()) {
            status = "error: API key and secret are required"
            return false
        }
        return try {
            val el = signedCall(
                mapOf("method" to "auth.getSession", "api_key" to key, "token" to token),
                secret,
            )
            val session = el.jsonObject["session"]?.jsonObject
            val sessionKey = session?.get("key")?.jsonPrimitive?.contentOrNull.orEmpty()
            val name = session?.get("name")?.jsonPrimitive?.contentOrNull.orEmpty()
            if (sessionKey.isBlank() || name.isBlank()) {
                status = "error: ${lastfmError(el)}"
                false
            } else {
                SysConfig.lastfmSessionKey = sessionKey
                SysConfig.lastfmUsername = name
                refreshStatus()
                true
            }
        } catch (e: Exception) {
            status = "error: ${e.message?.take(ERROR_SNIPPET_LEN) ?: "request failed"}"
            false
        }
    }

    /** Clears the stored session, keeping key/secret for the next login. */
    fun logout() {
        SysConfig.lastfmSessionKey = ""
        SysConfig.lastfmUsername = ""
        status = "signed out"
    }

    /** Refreshes [status] from the current credentials. */
    fun refreshStatus() {
        status = when {
            !SysConfig.lastfmEnabled -> "disabled"
            SysConfig.lastfmApiKey.isBlank() || SysConfig.lastfmSecret.isBlank() -> "signed out"
            SysConfig.lastfmSessionKey.isBlank() -> "signed out"
            else -> "signed in as ${SysConfig.lastfmUsername}"
        }
    }

    /**
     * Publishes a now-playing update; failures only surface via [status].
     *
     * @param artist Primary artist name.
     * @param track Track title.
     * @param album Album title, or null.
     * @param durationSec Length in seconds, 0 when unknown.
     */
    suspend fun updateNowPlaying(artist: String, track: String, album: String?, durationSec: Int) {
        if (!ready() || artist.isBlank() || track.isBlank()) return
        runCatching {
            val el = signedCall(
                trackParams("track.updateNowPlaying", artist, track, null, album, durationSec),
                SysConfig.lastfmSecret.trim(),
            )
            val error = el.jsonObject["error"]?.jsonPrimitive?.contentOrNull
            if (error != null) status = "error: ${lastfmError(el)}"
        }.onFailure { e ->
            status = "error: ${e.message?.take(ERROR_SNIPPET_LEN) ?: "request failed"}"
        }
    }

    /**
     * Scrobbles one play; failures only surface via [status].
     *
     * @param artist Primary artist name.
     * @param track Track title.
     * @param timestampSec Unix time playback started.
     * @param album Album title, or null.
     * @param durationSec Length in seconds.
     */
    suspend fun scrobble(artist: String, track: String, timestampSec: Long, album: String?, durationSec: Int) {
        if (!ready() || artist.isBlank() || track.isBlank()) return
        runCatching {
            val el = signedCall(
                trackParams("track.scrobble", artist, track, timestampSec, album, durationSec),
                SysConfig.lastfmSecret.trim(),
            )
            val error = el.jsonObject["error"]?.jsonPrimitive?.contentOrNull
            if (error != null) {
                status = "error: ${lastfmError(el)}"
            } else {
                status = "signed in as ${SysConfig.lastfmUsername}"
            }
        }.onFailure { e ->
            status = "error: ${e.message?.take(ERROR_SNIPPET_LEN) ?: "request failed"}"
        }
    }

    /** Track params shared by now-playing and scrobble calls. */
    private fun trackParams(
        method: String,
        artist: String,
        track: String,
        timestampSec: Long?,
        album: String?,
        durationSec: Int,
    ): Map<String, String> =
        buildMap {
            put("method", method)
            put("api_key", SysConfig.lastfmApiKey.trim())
            put("sk", SysConfig.lastfmSessionKey)
            put("artist", artist)
            put("track", track)
            timestampSec?.let { put("timestamp", it.toString()) }
            put("album", album.orEmpty())
            if (durationSec > 0) put("duration", durationSec.toString())
        }

    /** Short human-readable Last.fm API error, or "request rejected". */
    private fun lastfmError(el: kotlinx.serialization.json.JsonElement): String =
        el.jsonObject["message"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
            ?: "request rejected"

    /**
     * POSTs a signed API call and returns the decoded JSON body.
     *
     * @param params Unsigned params including method and api_key.
     * @param secret Shared secret used for api_sig.
     */
    private suspend fun signedCall(
        params: Map<String, String>,
        secret: String,
    ): kotlinx.serialization.json.JsonElement {
        val sig = params.toSortedMap()
            .entries.joinToString("") { (k, v) -> "$k$v" }
            .let { "$it$secret" }
            .let { md5Hex(it) }
        val text = http.submitForm(
            url = LASTFM_API_URL,
            formParameters = parameters {
                params.forEach { (k, v) -> append(k, v) }
                append("api_sig", sig)
                append("format", "json")
            },
        ) {
            header("User-Agent", LASTFM_USER_AGENT)
        }.bodyAsText()
        lastfmLog("${params["method"]} artist=${params["artist"]} track=${params["track"]} -> ${scrubSecrets(text).take(200)}")
        return json.parseToJsonElement(text)
    }

    /** Redacts tokens and session keys before anything hits the debug log. */
    private fun scrubSecrets(text: String): String =
        text.replace(Regex(""""(key|token)"\s*:\s*"[^"]*"""")) { match ->
            "\"${match.groupValues[1]}\":\"[REDACTED]\""
        }

    /** Appends one API call summary to the debug log for scrobble forensics. */
    internal fun lastfmLog(line: String) {
        try {
            java.io.File("/tmp/nixietube-lastfm.log")
                .appendText(java.time.Instant.now().toString() + " " + line + "\n")
        } catch (_: Exception) {
        }
    }
}

/** Lowercase hex MD5 digest of [s], used for Last.fm api_sig. */
private fun md5Hex(s: String): String =
    MessageDigest.getInstance("MD5")
        .digest(s.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xFF) }

/** Primary artist name, falling back to the joined credit line. */
private fun nixietube.innertube.Track.artistName(): String =
    artists.firstOrNull()?.name?.takeIf { it.isNotBlank() } ?: artistNames

/** One play's scrobble bookkeeping, reset on every new track or restart. */
private class ScrobbleProgress {
    var videoId: String? = null
    var startEpochSec: Long = 0
    var lastPositionMs: Long = 0
    var scrobbled: Boolean = false
}

/**
 * Watches player states: now-playing on each new track, one scrobble per
 * play once the standard threshold passes.
 *
 * @param states Player state flow to observe.
 */
fun LastFm.watch(states: StateFlow<PlayerState>) {
    scope.launch {
        val progress = ScrobbleProgress()
        states.collect { handleState(it, progress) }
    }
}

/** Routes one player emission to a track start or a progress update. */
private suspend fun LastFm.handleState(s: PlayerState, progress: ScrobbleProgress) {
    val track = s.current
    val videoId = track?.videoId
    if (videoId == null || videoId != progress.videoId) {
        progress.videoId = videoId
        progress.startEpochSec = System.currentTimeMillis() / MS_PER_SECOND
        progress.lastPositionMs = 0L
        progress.scrobbled = false
        if (videoId != null && track != null && ready()) {
            lastfmLog("now-playing ${track.artistName()} - ${track.title}")
            updateNowPlaying(track.artistName(), track.title, track.album?.name, track.durationSec)
        }
        return
    }
    if (track != null && ready() && !progress.scrobbled) {
        handleProgress(s, track, progress)
    }
    progress.lastPositionMs = s.positionMs
}

/** Resets the play on backward seeks and scrobbles once past threshold. */
private suspend fun LastFm.handleProgress(
    s: PlayerState,
    track: nixietube.innertube.Track,
    progress: ScrobbleProgress,
) {
    if (s.positionMs < progress.lastPositionMs - SEEK_BACK_TOLERANCE_MS) {
        // Seek back past tolerance (or repeat-one restart): new play.
        progress.startEpochSec = System.currentTimeMillis() / MS_PER_SECOND
        progress.scrobbled = false
        if (s.playing) {
            updateNowPlaying(track.artistName(), track.title, track.album?.name, track.durationSec)
        }
        return
    }
    val durationSec = track.durationSec.takeIf { it > 0 }
        ?: (s.durationMs / MS_PER_SECOND).toInt().takeIf { it > 0 }
        ?: return
    if (durationSec <= MIN_SCROBBLE_DURATION_SEC) return
    val thresholdMs = minOf(durationSec * MS_PER_SECOND / 2, SCROBBLE_CAP_SEC * MS_PER_SECOND)
    if (s.playing && s.positionMs >= thresholdMs) {
        progress.scrobbled = true
        lastfmLog("scrobble ${track.artistName()} - ${track.title} @${progress.startEpochSec}")
        scrobble(track.artistName(), track.title, progress.startEpochSec, track.album?.name, durationSec)
    }
}
