package nixietube.sys

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import nixietube.player.PlayerState
import java.io.File
import java.net.UnixDomainSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.SocketChannel
import java.util.Properties
import java.util.UUID

private val DISCORD_SQUARE_SIZE_RE = Regex("""=w\d+-h\d+[^?]*""")
private val DISCORD_URL_SIZE_RE = Regex("""=w(\d+)-h(\d+)(?:\D|$)""")
/** Rewrites a YouTube Music artwork URL to a 540px square crop for Discord. */
private fun squareDiscordArtwork(url: String): String =
    DISCORD_SQUARE_SIZE_RE.replace(url, "=w540-h540-l90-rj")

/** Returns the lowercase host of a URL, or an empty string when absent. */
private fun artworkHost(url: String): String =
    url.substringAfter("://", "").substringBefore("/").lowercase()

// YouTube Music artwork lives on googleusercontent hosts (yt3/lh3) with
// square =w…-h… size parameters. Plain YouTube video thumbnails
// (i.ytimg.com) are 4:3/16:9 and must never be sent as the square cover.
/** Returns true for YouTube Music artwork (googleusercontent, never ytimg thumbnails). */
private fun String.isYouTubeMusicArtwork(): Boolean {
    val host = artworkHost(this)
    return host.isNotBlank() && "googleusercontent.com" in host && "ytimg" !in host
}

/** Returns true when the URL's =w/-h size parameters describe a square image. */
private fun String.isSquareArtworkUrl(): Boolean {
    val match = DISCORD_URL_SIZE_RE.find(this) ?: return false
    val w = match.groupValues[1].toIntOrNull()
    val h = match.groupValues[2].toIntOrNull()
    return w != null && w > 0 && w == h
}

/** Returns true when thumbnail dimensions (or its URL size params) are square. */
private fun nixietube.innertube.Thumbnail.isSquareArtwork(): Boolean {
    if (width > 0 && height > 0) return width == height
    return url.isSquareArtworkUrl()
}

/** Returns true for square YouTube Music artwork suitable as Discord cover art. */
private fun nixietube.innertube.Thumbnail.isYouTubeMusicSquareArtwork(): Boolean =
    url.isYouTubeMusicArtwork() && isSquareArtwork()

/**
 * Selects which text is shown as the Discord activity name.
 *
 * @param key Stable config key persisted in [SysConfig.discordStatusText].
 * @param label Human-readable label shown in Settings.
 */
enum class DiscordStatusText(val key: String, val label: String) {
    /** Shows the app name ("NixieTube"). */
    APP("app", "App name"),
    /** Shows the current song title. */
    SONG("song", "Song title"),
    /** Shows the current track's artists. */
    ARTISTS("artists", "Artists"),
    ;

    companion object {
        /**
         * Resolves a stored key to its mode, defaulting to [APP].
         *
         * @param value Stored key, possibly unknown or null.
         * @return The matching mode, or [APP] when unmatched.
         */
        fun fromKey(value: String?): DiscordStatusText =
            values().firstOrNull { it.key == value } ?: APP
    }
}

// ~/.config/nixietube/config.properties backing store.
/**
 * `~/.config/nixietube/config.properties` backing store for desktop integration settings.
 *
 * Each property is loaded and saved on every access; failures are swallowed
 * and reads fall back to defaults.
 */
object SysConfig {
    private fun file(): File =
        File(System.getProperty("user.home"), ".config/nixietube/config.properties")

    private fun load(): Properties {
        val p = Properties()
        try {
            file().inputStream().use { p.load(it) }
        } catch (_: Exception) {
        }
        return p
    }

    private fun save(p: Properties) {
        try {
            file().parentFile.mkdirs()
            file().outputStream().use { p.store(it, null) }
        } catch (_: Exception) {
        }
    }

    /**
     * Built-in Discord application ID used when the user hasn't set a custom one.
     *
     * Registered at discord.com/developers/applications; allows Rich Presence
     * to work out of the box. Users may override it in Settings.
     */
    const val DEFAULT_DISCORD_APP_ID = "1552404006498869318"

    /** Raw stored override; empty falls back to [DEFAULT_DISCORD_APP_ID] in [discordAppId]. */
    val discordAppIdRaw: String
        get() = load().getProperty("discord.appId").orEmpty()

    /** Discord application ID used for the Rich Presence handshake. */
    var discordAppId: String
        get() = discordAppIdRaw.takeIf { it.isNotBlank() } ?: DEFAULT_DISCORD_APP_ID
        set(v) {
            val p = load(); p.setProperty("discord.appId", v); save(p)
        }

    /** Whether Discord Rich Presence is enabled. */
    var discordEnabled: Boolean
        get() = load().getProperty("discord.enabled")?.toBoolean() ?: false
        set(v) {
            val p = load(); p.setProperty("discord.enabled", v.toString()); save(p)
        }

    /** Stored [DiscordStatusText] key selecting the activity name mode. */
    var discordStatusText: String
        get() = DiscordStatusText.fromKey(load().getProperty("discord.statusText")).key
        set(v) {
            val p = load()
            p.setProperty("discord.statusText", DiscordStatusText.fromKey(v).key)
            save(p)
        }

    /** Whether the MPRIS D-Bus service should run (default true). */
    var mprisEnabled: Boolean
        get() = load().getProperty("mpris.enabled")?.toBoolean() ?: true
        set(v) {
            val p = load(); p.setProperty("mpris.enabled", v.toString()); save(p)
        }

    /** Stored Google TV-device OAuth client ID. */
    var googleClientId: String
        get() = load().getProperty("google.clientId").orEmpty()
        set(v) {
            val p = load(); p.setProperty("google.clientId", v); save(p)
        }

    /** Stored Google TV-device OAuth client secret. */
    var googleClientSecret: String
        get() = load().getProperty("google.clientSecret").orEmpty()
        set(v) {
            val p = load(); p.setProperty("google.clientSecret", v); save(p)
        }

    /**
     * Opt-in flag for reporting playback to YouTube's stats/watchtime beacons.
     *
     * When true, listening history feeds into recaps (Year in Review, Most
     * Listened To, etc.). Default false.
     */
    // When true, playback is reported to YouTube's stats/watchtime
    // beacons so listening history feeds into recaps (Year in Review,
    // Most Listened To, etc.). Default false — opt-in only.
    var reportPlayback: Boolean
        get() = load().getProperty("reportPlayback")?.toBoolean() ?: false
        set(v) {
            val p = load(); p.setProperty("reportPlayback", v.toString()); save(p)
        }
}

// Discord Rich Presence over the local RPC socket — the same transport
// Discord's Social SDK docs prescribe for presence-only desktop use
// (no auth, no native SDK needed). Requires a Discord application ID
// (https://discord.com/developers/applications) and a running client.
/**
 * Discord Rich Presence over the local RPC socket — the same transport Discord's
 * Social SDK docs prescribe for presence-only desktop use (no auth, no native SDK).
 *
 * Connects to a `discord-ipc-N` Unix socket, handshakes with the configured app ID,
 * and pushes a type-2 (listening) activity per player state. Only square YouTube
 * Music artwork is ever sent as cover art; duplicate states are deduplicated via
 * a change key that includes the playing flag so pause/resume always re-pings.
 *
 * @param scope Scope for connection I/O and activity sends.
 * @param resolveSquareArtwork Fallback resolver (e.g. via up-next) for cover art
 * when the current track carries no square Music thumbnail.
 */
class DiscordPresence(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val resolveSquareArtwork: suspend (String) -> String? = { null },
) {
    @Volatile
    private var channel: SocketChannel? = null
    @Volatile
    private var lastKey: String? = null

    /** Human-readable connection state: "disabled", "idle", "active", or "error: …". */
    @Volatile
    var status: String = "disabled"
        private set

    /**
     * Pushes the given player state to Discord, connecting first if needed.
     *
     * No-op deduplicated by change key; transitions to "disabled"/"idle" clear
     * or shut down the connection as appropriate.
     *
     * @param state Current player snapshot to publish.
     */
    fun update(state: PlayerState) {
        val appId = SysConfig.discordAppId
        if (!SysConfig.discordEnabled || appId.isBlank()) {
            if (status != "disabled") {
                status = "disabled"
                shutdown()
            }
            return
        }
        val track = state.current
        if (track == null) {
            if (status != "idle") {
                status = "idle"
                scope.launch {
                    try {
                        ensureConnected(appId)
                        clearActivity()
                    } catch (_: Exception) {
                    }
                }
            }
            lastKey = "idle"
            return
        }
        val album = track.album?.name?.trim()?.takeIf { it.isNotBlank() }
        val statusMode = DiscordStatusText.fromKey(SysConfig.discordStatusText)
        val statusName = when (statusMode) {
            DiscordStatusText.APP -> "NixieTube"
            DiscordStatusText.SONG -> track.title.trim().take(128).ifBlank { "Unknown song" }
            DiscordStatusText.ARTISTS -> track.artistNames.trim().take(128).ifBlank { "Unknown artist" }
        }
        // Prefer a true 1:1 YouTube Music thumbnail (yt3/lh3). Plain
        // YouTube video thumbnails are never square, so there is no
        // YouTube fallback here: when the track carries no square Music
        // art, the up-next resolver below is tried instead.
        val squareArtwork = track.thumbnails
            .filter { it.isYouTubeMusicSquareArtwork() }
            .maxByOrNull { it.width }
            ?.url
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        val artwork = squareArtwork?.let(::squareDiscordArtwork)
        // state.playing is part of the key so every pause/resume pings a
        // fresh activity instead of being swallowed as a duplicate.
        val key = listOf(
            state.playing,
            track.videoId,
            track.title,
            track.artistNames,
            album,
            artwork,
            statusMode.key,
        ).joinToString("\u0000")
        if (key == lastKey && channel?.isOpen == true) return
        lastKey = key
        scope.launch {
            try {
                ensureConnected(appId)
                // Only ever send square YouTube Music art. When the track
                // itself has none, resolve it via up-next; otherwise send
                // no image (Discord renders the album text alone) rather
                // than a stretched YouTube video thumbnail.
                val resolvedArtwork = if (squareArtwork != null) {
                    artwork
                } else {
                    val resolved = try {
                        resolveSquareArtwork(track.videoId)?.trim()
                    } catch (_: Exception) {
                        null
                    }?.takeIf {
                        it.isNotBlank() && it.isYouTubeMusicArtwork() && it.isSquareArtworkUrl() &&
                            (it.startsWith("https://", ignoreCase = true) ||
                                it.startsWith("http://", ignoreCase = true))
                    }
                    resolved?.let(::squareDiscordArtwork)
                }
                val start = System.currentTimeMillis() / 1000 - state.positionMs / 1000
                // Discord's music activity structure is:
                // name = configurable status text, details = song,
                // state = artist, assets.large_text = album,
                // assets.large_image = cover art. Keep the existing pause
                // marker/state behavior while allowing the name/status text
                // to be selected in Settings.
                val song = track.title.trim().take(128).ifBlank { "Unknown song" }
                val artist = track.artistNames.trim().take(128).ifBlank { "Unknown artist" }
                val stateLine = if (state.playing) artist else "⏸ $artist"
                sendActivity(
                    type = 2,
                    name = statusName,
                    details = song,
                    stateText = stateLine,
                    startEpochSec = start,
                    endEpochSec = if (state.playing && state.durationMs > 0) {
                        start + state.durationMs / 1000
                    } else {
                        null
                    },
                    largeImage = resolvedArtwork,
                    largeText = album?.take(128),
                    buttons = listOf(
                        "Listen on YouTube Music" to "https://music.youtube.com/watch?v=${track.videoId}",
                    ),
                )
                status = "active"
            } catch (e: Exception) {
                status = "error: ${e.message?.take(80)}"
                shutdown()
            }
        }
    }

    /** Clears the dedup key so the next [update] re-sends even if unchanged. */
    fun invalidate() {
        lastKey = null
    }

    /** Closes the IPC socket, dropping the current connection. */
    fun shutdown() {
        try {
            channel?.close()
        } catch (_: Exception) {
        }
        channel = null
    }

    /** Connects to the first reachable `discord-ipc-N` socket and handshakes with [appId]. */
    private fun ensureConnected(appId: String) {
        if (channel?.isOpen == true) return
        shutdown()
        val runtimeDir = System.getenv("XDG_RUNTIME_DIR")?.takeIf { it.isNotBlank() } ?: "/tmp"
        var lastError: Exception? = null
        for (i in 0..9) {
            for (dir in listOf(runtimeDir, "/tmp")) {
                try {
                    val addr = UnixDomainSocketAddress.of("$dir/discord-ipc-$i")
                    val ch = SocketChannel.open(addr)
                    ch.configureBlocking(true)
                    handshake(ch, appId)
                    channel = ch
                    scope.launch { readLoop(ch) }
                    scope.launch { pingLoop(ch) }
                    return
                } catch (e: Exception) {
                    lastError = e
                }
            }
        }
        throw lastError ?: IllegalStateException("no Discord IPC socket")
    }

    /** Performs the opcode-0 handshake and rejects error replies. */
    private fun handshake(ch: SocketChannel, appId: String) {
        val payload = buildJsonObject {
            put("v", 1)
            put("client_id", appId)
        }.toString()
        writeFrame(ch, OP_HANDSHAKE, payload)
        val (op, text) = readFrame(ch)
        if (op == OP_CLOSE || text.contains("\"ERROR\"") || text.contains("error")) {
            throw IllegalStateException("handshake rejected")
        }
    }

    /** Sends a SET_ACTIVITY frame describing the current track. */
    private fun sendActivity(
        type: Int,
        name: String,
        details: String,
        stateText: String,
        startEpochSec: Long,
        endEpochSec: Long?,
        largeImage: String?,
        largeText: String?,
        buttons: List<Pair<String, String>>,
    ) {
        val ch = channel ?: return
        val activity = buildJsonObject {
            put("type", type)
            put("name", name)
            put("details", details)
            put("state", stateText)
            put("timestamps", buildJsonObject {
                put("start", startEpochSec)
                if (endEpochSec != null) put("end", endEpochSec)
            })
            if (largeImage != null || largeText != null) {
                put("assets", buildJsonObject {
                    // The desktop IPC accepts a public external URL directly.
                    // Prefixing a raw URL with `mp:` makes Discord treat it
                    // as an already-proxied asset and the image vanishes.
                    // Keep an already-proxied value intact for callers that
                    // obtained one from Discord's media proxy.
                    if (largeImage != null) {
                        put("large_image", largeImage)
                    }
                    if (largeText != null) put("large_text", largeText)
                })
            }
            if (buttons.isNotEmpty()) {
                put("buttons", kotlinx.serialization.json.buildJsonArray {
                    buttons.take(2).forEach { (label, url) ->
                        add(buildJsonObject {
                            put("label", label.take(32))
                            put("url", url)
                        })
                    }
                })
            }
        }
        val payload = buildJsonObject {
            put("cmd", "SET_ACTIVITY")
            put("nonce", UUID.randomUUID().toString())
            put("args", buildJsonObject {
                put("pid", ProcessHandle.current().pid().toInt())
                put("activity", activity)
            })
        }.toString()
        writeFrame(ch, OP_FRAME, payload)
    }

    /** Sends a SET_ACTIVITY frame with no activity, clearing Rich Presence. */
    private fun clearActivity() {
        val ch = channel ?: return
        try {
            val payload = buildJsonObject {
                put("cmd", "SET_ACTIVITY")
                put("nonce", UUID.randomUUID().toString())
                put("args", buildJsonObject {
                    put("pid", ProcessHandle.current().pid().toInt())
                })
            }.toString()
            writeFrame(ch, OP_FRAME, payload)
        } catch (_: Exception) {
        }
    }

    /** Drains inbound frames until close; tears down the connection on exit. */
    private fun readLoop(ch: SocketChannel) {
        try {
            while (ch.isOpen && scope.isActive) {
                val (op, _) = readFrame(ch)
                if (op == OP_CLOSE) break
            }
        } catch (_: Exception) {
        } finally {
            if (channel == ch) shutdown()
        }
    }

    /** Sends a PING every 20s to keep the IPC connection alive. */
    private suspend fun pingLoop(ch: SocketChannel) {
        try {
            while (ch.isOpen && scope.isActive) {
                delay(20_000)
                writeFrame(ch, OP_PING, """{"cmd":"PING"}""")
            }
        } catch (_: Exception) {
        }
    }

    /** Writes one little-endian (opcode, length, payload) IPC frame. */
    private fun writeFrame(ch: SocketChannel, op: Int, payload: String) {
        val bytes = payload.toByteArray(Charsets.UTF_8)
        val buf = ByteBuffer.allocate(8 + bytes.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(op)
        buf.putInt(bytes.size)
        buf.put(bytes)
        buf.flip()
        while (buf.hasRemaining()) ch.write(buf)
    }

    /** Reads one IPC frame, throwing when the socket closes or the length is invalid. */
    private fun readFrame(ch: SocketChannel): Pair<Int, String> {
        val header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        while (header.hasRemaining()) {
            if (ch.read(header) < 0) throw IllegalStateException("closed")
        }
        header.flip()
        val op = header.int
        val len = header.int
        if (len < 0 || len > 8 * 1024 * 1024) throw IllegalStateException("bad frame len $len")
        val body = ByteBuffer.allocate(len)
        while (body.hasRemaining()) {
            if (ch.read(body) < 0) throw IllegalStateException("closed")
        }
        return op to String(body.array(), Charsets.UTF_8)
    }

    companion object {
        /** Opcode for the initial handshake frame. */
        const val OP_HANDSHAKE = 0
        /** Opcode for regular command/event frames. */
        const val OP_FRAME = 1
        /** Opcode signalling connection close. */
        const val OP_CLOSE = 2
        /** Opcode for keepalive pings. */
        const val OP_PING = 3
    }
}
