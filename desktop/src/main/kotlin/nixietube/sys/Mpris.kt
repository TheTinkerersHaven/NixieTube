package nixietube.sys

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.freedesktop.dbus.DBusPath
import org.freedesktop.dbus.annotations.DBusBoundProperty
import org.freedesktop.dbus.annotations.DBusInterfaceName
import org.freedesktop.dbus.annotations.DBusMemberName
import org.freedesktop.dbus.annotations.DBusProperty.Access
import org.freedesktop.dbus.annotations.PropertiesEmitsChangedSignal.EmitChangeSignal
import org.freedesktop.dbus.connections.IDisconnectCallback
import org.freedesktop.dbus.connections.impl.DBusConnection
import org.freedesktop.dbus.connections.impl.DBusConnectionBuilder
import org.freedesktop.dbus.interfaces.DBusInterface
import org.freedesktop.dbus.interfaces.Properties.PropertiesChanged
import org.freedesktop.dbus.messages.DBusSignal
import org.freedesktop.dbus.types.UInt64
import org.freedesktop.dbus.types.Variant
import nixietube.art.ArtworkStore
import nixietube.innertube.Track
import nixietube.player.PlayerController
import nixietube.player.PlayerState
import nixietube.player.RepeatMode

private const val MAX_DBUS_TEXT = 4096

/** LRU cache of per-track stabilized durations so Metadata stays frozen once measured. */
private val stableLengths = object : LinkedHashMap<String, Long>(32, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>): Boolean = size > 100
}

/** Strips NULs and truncates D-Bus text to [limit] characters. */
private fun cleanText(value: String, limit: Int = MAX_DBUS_TEXT): String =
    value.replace('\u0000', ' ').take(limit)

/** Hex-encodes a video ID into a reversible, D-Bus object-path-safe element. */
private fun safeVideoId(value: String): String {
    // D-Bus object-path elements allow only ASCII letters, digits and '_';
    // YouTube IDs commonly contain '-', which otherwise makes the whole
    // PropertiesChanged reply invalid and the bus drops the connection.
    // Hex-encoding the ID keeps the mapping reversible and avoids collisions
    // between (for example) "a-b" and "a_b".
    val bytes = value.ifBlank { "unknown" }.toByteArray(Charsets.UTF_8)
    return buildString {
        append('t')
        for (byte in bytes) {
            append("%02x".format(byte.toInt() and 0xff))
        }
    }.take(200)
}

/** Returns the D-Bus object path identifying the given track. */
private fun trackPath(videoId: String): String =
    "${MprisService.OBJECT_PATH}/Track/${safeVideoId(videoId)}"

/** Prefers the cached local artwork file, falling back to the remote URL while downloading. */
private fun artworkUrl(track: Track): String? {
    val remote = track.displayArtwork?.takeIf { it.isNotBlank() } ?: return null
    return try {
        // Prefer the cropped local file once it is ready. During the short
        // download window the remote URL still gives clients something to
        // render; a later state emission switches it to file://.
        ArtworkStore.cachedFile(remote)?.toURI()?.toString() ?: remote
    } catch (_: Exception) {
        remote
    }
}

/** Returns the app-slider duration, freezing the first engine-measured value per track. */
private fun metadataLengthMs(s: PlayerState): Long {
    val track = s.current ?: return 0L
    // Use the same duration the app slider uses. The app duration comes from
    // the catalog metadata; keeping this as the authoritative length avoids
    // MPRIS seeming to seek against a different track timeline.
    val appDuration = s.durationMs.coerceAtLeast(0L)
    if (appDuration <= 0L) {
        return (track.durationSec.toLong() * 1000L).coerceAtLeast(0L)
    }
    // Before the first engine tick, durationMs is only the catalog estimate.
    // Once playback has advanced, freeze the first useful measurement so
    // the complete Metadata map is not resent on every ticker update.
    if (s.positionMs <= 0L) return appDuration
    synchronized(stableLengths) {
        stableLengths[track.videoId]?.let { return it }
        stableLengths[track.videoId] = appDuration
        return appDuration
    }
}

/** Returns the stabilized track length in microseconds, saturating on overflow. */
private fun metadataLengthUs(s: PlayerState): Long {
    val ms = metadataLengthMs(s)
    return if (ms > Long.MAX_VALUE / 1000L) Long.MAX_VALUE else ms * 1000L
}

/** Returns the playback position in microseconds, clamped to the track length. */
private fun positionUs(s: PlayerState): Long {
    val lengthMs = metadataLengthMs(s)
    val rawMs = s.positionMs.coerceAtLeast(0L)
    val ms = if (lengthMs > 0L) rawMs.coerceAtMost(lengthMs) else rawMs
    return if (ms > Long.MAX_VALUE / 1000L) Long.MAX_VALUE else ms * 1000L
}

/** Returns true when a next track exists in-queue or via autoplay. */
private fun canGoNext(s: PlayerState): Boolean =
    (s.index in s.queue.indices && s.index + 1 < s.queue.size) ||
        (s.autoplay && s.current != null)

/**
 * MPRIS (org.mpris.MediaPlayer2) service for Linux desktop integration:
 * playerctl, GNOME/KDE media controls and hardware media keys.
 *
 * dbus-java deliberately uses a private connection for this service. Its lifecycle
 * is explicit: a failed request/export never leaks a connected socket, [stop] never
 * leaves an old state collector behind, and a broken reader/sender thread results
 * in a fresh connection rather than a dead well-known name. A single state
 * collector runs for the whole service lifetime; restarts only replace the
 * connection. Lost connections trigger exponential-backoff reconnects while
 * the service is desired to run.
 *
 * @param controller Player backend receiving MPRIS commands and emitting state.
 * @param onQuit Callback invoked when a client calls Quit.
 * @param scope Scope for the state collector, reconnect loop, and teardown work.
 */
// MPRIS (org.mpris.MediaPlayer2) service for Linux desktop integration:
// playerctl, GNOME/KDE media controls and hardware media keys.
//
// dbus-java deliberately uses a private connection for this service.  Keep
// its lifecycle explicit: a failed request/export must not leak a connected
// socket, a stop must not leave an old state collector behind, and a broken
// reader/sender thread must result in a fresh connection rather than a dead
// well-known name.
class MprisService(
    private val controller: PlayerController,
    private val onQuit: () -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val lifecycleLock = Any()
    private val signalLock = Any()

    @Volatile
    private var connection: DBusConnection? = null

    @Volatile
    private var connected = false

    @Volatile
    private var desiredRunning = false

    /** Last lifecycle/connection error, or null when healthy. */
    @Volatile
    var lastError: String? = null
        private set

    /** Observable service liveness for the settings UI. */
    private val _activeState = MutableStateFlow(false)
    val activeState: StateFlow<Boolean> = _activeState.asStateFlow()

    private var reconnectJob: Job? = null
    private var lastSent: Map<String, Any?> = emptyMap()
    private var lastArtworkKey: String? = null
    private var lastSeekEpoch: Long? = null
    private var lastSeekTrackId: String? = null
    private var lastPositionSentMs = 0L
    private var lastPositionTrack: String? = null

    /** Clears the diff snapshot and seek/artwork tracking ahead of a fresh connection. */
    private fun resetSignalState() {
        lastSent = emptyMap()
        lastSeekEpoch = null
        lastSeekTrackId = null
        lastArtworkKey = null
    }

    private val uncaughtHandlerInstalled = AtomicBoolean(false)

    /** True when connected and the underlying D-Bus socket is open. */
    val active: Boolean
        get() = connected && connection?.isConnected == true

    init {
        installDbusUncaughtHandler()
        // One collector for the whole service lifetime.  Restarting MPRIS
        // replaces the connection, it does not create a second collector.
        scope.launch {
            controller.state.collect { state ->
                try {
                    onState(state)
                } catch (t: Throwable) {
                    log("onState FAILED: ${t.javaClass.simpleName}: ${t.message}".take(400))
                }
            }
        }
    }

    /** Appends a timestamped line to the MPRIS debug log, ignoring I/O failures. */
    private fun log(line: String) {
        try {
            java.io.File("/tmp/nixietube-mpris.log")
                .appendText("${java.time.Instant.now()} $line\n")
        } catch (_: Exception) {
        }
    }

    /** Installs a handler that rebuilds the service when a dbus-java thread dies uncaught. */
    private fun installDbusUncaughtHandler() {
        if (!uncaughtHandlerInstalled.compareAndSet(false, true)) return
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            // dbus-java's reader catches only a small set of DBusException
            // types.  A malformed/edge-case incoming message can therefore
            // kill its reader thread without notifying the owner.  Treat that
            // exactly like a lost connection and rebuild the service.
            if (thread.name.startsWith("DBusConnection") ||
                thread.name.contains("DBus Sender Thread")
            ) {
                log("uncaught ${thread.name}: ${error.javaClass.simpleName}: ${error.message}".take(500))
                connection?.let { conn -> onConnectionLost(conn, "uncaught DBus thread failure") }
            }
            if (previous != null) {
                previous.uncaughtException(thread, error)
            } else {
                error.printStackTrace()
            }
        }
    }

    /**
     * Connects, exports the object, claims the bus name, and publishes an initial snapshot.
     *
     * The export happens before the name claim so monitors never observe an empty
     * player, and name ownership is verified after claiming to detect stale owners.
     *
     * @return True when the service is up (or was already up).
     */
    fun start(): Boolean {
        synchronized(lifecycleLock) {
            desiredRunning = true
            val old = connection
            if (old != null && connected && old.isConnected) return true

            if (old != null) {
                connection = null
                connected = false
                _activeState.value = false
                resetSignalState()
                closeConnection(old)
            }

            val connRef = AtomicReference<DBusConnection?>()
            var conn: DBusConnection? = null
            return try {
                val callback = object : IDisconnectCallback {
                    override fun disconnectOnError(error: IOException) {
                        connRef.get()?.let {
                            onConnectionLost(it, "disconnectOnError: ${error.message}")
                        }
                    }
                }
                conn = DBusConnectionBuilder.forSessionBus()
                    .withShared(false)
                    .withDisconnectCallback(callback)
                    .build()
                connRef.set(conn)

                // Export before claiming the well-known name.  A media
                // monitor can discover a name between RequestName and
                // exportObject; if it probes during that window it may cache
                // a dead/empty player for the rest of the session.
                val created = conn
                conn.exportObject(
                    MprisObject(
                        controller = controller,
                        onQuit = onQuit,
                        lengthUs = ::metadataLengthUs,
                    ),
                )
                log("object exported; requesting bus name")
                conn.requestBusName(BUS_NAME)
                log("bus name acquired")

                // RequestName is synchronous, but verify ownership after the
                // object is ready: a competing stale instance must not leave
                // us reporting a service that is actually unreachable.
                val unique = runCatching { conn.uniqueName }.getOrNull()
                val owner = runCatching { conn.getDBusOwnerName(BUS_NAME) }.getOrNull()
                if (owner != null && unique != null && owner != unique) {
                    throw IllegalStateException("MPRIS name is owned by $owner, not $unique")
                }

                connection = created
                connected = true
                _activeState.value = true
                resetSignalState()
                lastError = null
                log("started, name=$BUS_NAME unique=${unique ?: "?"} owner=${owner ?: "?"}")

                // Publish the initial snapshot immediately after the name is
                // visible; deferring this lets desktop media monitors observe
                // the new name before they receive any state at startup.
                onState(controller.state.value)
                true
            } catch (t: Throwable) {
                conn?.let { closeConnection(it) }
                connection = null
                connected = false
                _activeState.value = false
                lastError = "${t.javaClass.simpleName}: ${t.message}".take(300)
                log("start FAILED: $lastError")
                false
            }
        }
    }

    /** Marks the service undesired, cancels reconnects, and disconnects the bus connection. */
    fun stop() {
        val old = synchronized(lifecycleLock) {
            desiredRunning = false
            reconnectJob?.cancel()
            reconnectJob = null
            val current = connection
            connection = null
            connected = false
            _activeState.value = false
            resetSignalState()
            current
        }
        old?.let { closeConnection(it) }
        log("stopped")
    }

    /** Disconnects a bus connection, logging rather than throwing on failure. */
    private fun closeConnection(conn: DBusConnection) {
        try {
            conn.disconnect()
        } catch (t: Throwable) {
            log("disconnect failed: ${t.javaClass.simpleName}: ${t.message}".take(300))
        }
    }

    /** Tears down a lost connection off-thread and schedules a reconnect when still desired. */
    private fun onConnectionLost(conn: DBusConnection, reason: String) {
        val retry = synchronized(lifecycleLock) {
            if (connection !== conn) return
            connection = null
            connected = false
            _activeState.value = false
            resetSignalState()
            desiredRunning
        }
        lastError = "Connection lost: ${reason.take(160)}"
        log("connection lost (${reason.take(180)})")
        // Never call disconnect from dbus-java's reader/callback thread: its
        // disconnect path joins the very executor that is reporting failure.
        scope.launch { closeConnection(conn) }
        if (retry) scheduleReconnect()
    }

    /** Retries [start] with exponential backoff (1s→5s, 60 attempts) while desired. */
    private fun scheduleReconnect() {
        synchronized(lifecycleLock) {
            if (!desiredRunning || reconnectJob?.isActive == true) return
            reconnectJob = scope.launch {
                // Always cool down before rebuilding.  Without this, a
                // connection that fails during its first signal can create
                // hundreds of replacement sockets in a few hundred ms.
                var waitMs = 1_000L
                repeat(60) {
                    if (!desiredRunning) return@launch
                    delay(waitMs)
                    if (!desiredRunning) return@launch
                    if (start()) return@launch
                    waitMs = (waitMs * 2).coerceAtMost(5_000L)
                }
                if (desiredRunning) {
                    lastError = (lastError ?: "MPRIS reconnect attempts exhausted")
                    log("reconnect attempts exhausted")
                }
            }
        }
    }

    /** Emits a spec-compliant Seeked signal for the given position. */
    private fun sendSeeked(conn: DBusConnection, positionMicros: Long) {
        try {
            synchronized(signalLock) {
                if (connection !== conn || !connected) return
                conn.sendMessage(MprisPlayerIface.SeekedSignal(OBJECT_PATH, positionMicros))
            }
        } catch (t: Throwable) {
            log("Seeked send failed: ${t.javaClass.simpleName}: ${t.message}".take(300))
            onConnectionLost(conn, "Seeked send failed")
        }
    }

    /** Diffs player state into PropertiesChanged signals plus a Seeked signal on controller seeks. */
    private fun onState(s: PlayerState) {
        val conn = connection ?: return
        if (!connected || !conn.isConnected) {
            onConnectionLost(conn, "connection is not healthy")
            return
        }

        // PlayerController owns all seeks (UI, keyboard, and MPRIS). Emit a
        // spec-compliant Seeked signal when its seek epoch changes. Position
        // itself is still folded into PropertiesChanged, but throttled:
        // cache-based clients (e.g. Plasma) only resync from signals, so
        // without this they resume counting from a stale value.
        var seekPositionUs: Long? = null
        var includePosition = false
        synchronized(signalLock) {
            val previousEpoch = lastSeekEpoch
            val trackId = s.current?.videoId
            val seeked = previousEpoch != null &&
                s.seekEpoch != previousEpoch &&
                trackId != null && trackId == lastSeekTrackId
            if (seeked) {
                seekPositionUs = positionUs(s)
            }
            lastSeekEpoch = s.seekEpoch
            lastSeekTrackId = trackId
            val nowMs = System.currentTimeMillis()
            val trackChanged = trackId != lastPositionTrack
            val positionStale = trackChanged || seekPositionUs != null ||
                (s.playing && nowMs - lastPositionSentMs >= 2_000)
            if (s.current != null && positionStale) {
                includePosition = true
                lastPositionSentMs = nowMs
                lastPositionTrack = trackId
            }
        }
        val seekPosition = seekPositionUs
        if (seekPosition != null) {
            sendSeeked(conn, seekPosition)
            if (connection !== conn || !connected) return
        }

        val artwork = s.current?.displayArtwork?.takeIf { it.isNotBlank() }
        var warmArtwork: String? = null
        synchronized(signalLock) {
            if (artwork != lastArtworkKey) {
                lastArtworkKey = artwork
                warmArtwork = artwork
            }
        }
        if (warmArtwork != null) {
            val url = warmArtwork
            scope.launch {
                try {
                    if (ArtworkStore.file(url) != null) {
                        // Publish the local file:// artwork once it exists;
                        // otherwise the first signal would keep the remote URL
                        // forever because no player state change follows.
                        onState(controller.state.value)
                    }
                } catch (t: Throwable) {
                    log("artwork warm failed: ${t.javaClass.simpleName}: ${t.message}".take(250))
                }
            }
        }

        val current = try {
            val props = playerProps(s)
            if (includePosition) props + ("Position" to positionUs(s)) else props
        } catch (t: Throwable) {
            log("properties failed: ${t.javaClass.simpleName}: ${t.message}".take(300))
            return
        }

        var failure: Throwable? = null
        synchronized(signalLock) {
            val changed = current.filter { (key, value) -> lastSent[key] != value }
            if (changed.isNotEmpty()) {
                try {
                    conn.sendMessage(
                        PropertiesChanged(
                            OBJECT_PATH,
                            PLAYER_IFACE,
                            changed.mapValues { (key, value) -> wireProperty(key, value) },
                            emptyList(),
                        ),
                    )
                    // sendMessage() only enqueues on dbus-java's sender
                    // executor.  Mark the snapshot after enqueueing, never
                    // before, so a synchronous failure can be retried.
                    lastSent = current
                } catch (t: Throwable) {
                    failure = t
                }
            }
        }
        failure?.let { onConnectionLost(conn, "signal send failed: ${it.message}") }
    }

    /** Wraps a property value in an explicitly-signed D-Bus variant. */
    private fun wireProperty(key: String, value: Any?): Variant<*> {
        if (key == "Metadata" && value is Map<*, *>) {
            @Suppress("UNCHECKED_CAST")
            return wireMetadata(value as Map<String, Any?>)
        }
        return when (value) {
            is String -> Variant(value, "s")
            is Boolean -> Variant(value, "b")
            is Double -> Variant(value, "d")
            is Int -> Variant(value, "i")
            else -> Variant(value)
        }
    }

    // Pre-wrap every metadata value with an explicit signature.  In
    // particular, an erased Kotlin List is not reliably inferred as "as" by
    // dbus-java; a bad conversion there can invalidate the whole signal.
    /** Wraps a metadata map as an "a{sv}" variant with explicit per-value signatures. */
    private fun wireMetadata(raw: Map<String, Any?>): Variant<*> {
        val wired = linkedMapOf<String, Any?>()
        for ((key, value) in raw) {
            wired[key] = when {
                key == "xesam:artist" && value is List<*> ->
                    Variant(value.map { cleanText(it?.toString().orEmpty(), 512) }, "as")
                value is String -> Variant(cleanText(value), "s")
                value is DBusPath -> Variant(value)
                value is UInt64 -> Variant(value)
                else -> value
            }
        }
        return Variant(wired, "a{sv}")
    }

    /** Builds the full Player-interface property snapshot for a state. */
    private fun playerProps(s: PlayerState): Map<String, Any?> {
        val status = when {
            s.current == null || s.stopped -> "Stopped"
            s.playing -> "Playing"
            else -> "Paused"
        }
        return mapOf(
            "PlaybackStatus" to status,
            "Metadata" to metadataOf(s),
            "Volume" to s.volume / 100.0,
            "LoopStatus" to when (s.repeat) {
                RepeatMode.OFF -> "None"
                RepeatMode.ONE -> "Track"
                RepeatMode.ALL -> "Playlist"
            },
            "Shuffle" to s.shuffle,
            "CanGoNext" to canGoNext(s),
            "CanGoPrevious" to (s.index > 0),
            "CanPlay" to (s.current != null),
            "CanPause" to (s.current != null),
            "CanSeek" to (s.current != null),
            "CanControl" to true,
            "Rate" to 1.0,
            "MinimumRate" to 1.0,
            "MaximumRate" to 1.0,
        )
    }

    /** Builds the MPRIS metadata map (trackid, length, title, artist, album, art, URL). */
    private fun metadataOf(s: PlayerState): Map<String, Any?> {
        val track = s.current ?: return emptyMap()
        return buildMap {
            put("mpris:trackid", DBusPath(trackPath(track.videoId)))
            put("mpris:length", UInt64(metadataLengthUs(s)))
            put("xesam:title", cleanText(track.title))
            put(
                "xesam:artist",
                track.artists.map { cleanText(it.name, 512) }.filter { it.isNotBlank() },
            )
            put("xesam:album", cleanText(track.album?.name.orEmpty()))
            artworkUrl(track)?.let { put("mpris:artUrl", cleanText(it)) }
            put("xesam:url", "https://music.youtube.com/watch?v=${track.videoId}")
        }
    }

    companion object {
        /** Well-known bus name claimed by this player. */
        const val BUS_NAME = "org.mpris.MediaPlayer2.nixietube"
        /** Object path of the exported root/player object. */
        const val OBJECT_PATH = "/org/mpris/MediaPlayer2"
        /** D-Bus interface name of the root (MediaPlayer2) interface. */
        const val ROOT_IFACE = "org.mpris.MediaPlayer2"
        /** D-Bus interface name of the Player interface. */
        const val PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
    }
}

/**
 * MPRIS root interface (`org.mpris.MediaPlayer2`): application identity and lifecycle.
 */
@DBusInterfaceName(MprisService.ROOT_IFACE)
interface MprisRootIface : DBusInterface {
    /** Brings the application window forward (no-op: single-window app). */
    fun Raise()
    /** Quits the application via the [MprisService] quit callback. */
    fun Quit()

    /** Application identity string ("NixieTube"). */
    @DBusBoundProperty(access = Access.READ, name = "Identity")
    fun getIdentity(): String

    /** Desktop-entry name used by shells to resolve the player entry. */
    @DBusBoundProperty(access = Access.READ, name = "DesktopEntry")
    fun getDesktopEntry(): String

    /** URI schemes the player can open. */
    @DBusBoundProperty(access = Access.READ, name = "SupportedUriSchemes")
    fun getSupportedUriSchemes(): List<String>

    /** MIME types the player can handle. */
    @DBusBoundProperty(access = Access.READ, name = "SupportedMimeTypes")
    fun getSupportedMimeTypes(): List<String>

    /** Whether the player supports [Quit]. */
    @DBusBoundProperty(access = Access.READ, name = "CanQuit")
    fun getCanQuit(): Boolean

    /** Whether the player supports [Raise]. */
    @DBusBoundProperty(access = Access.READ, name = "CanRaise")
    fun getCanRaise(): Boolean

    /** Whether a track-list interface is provided (always false). */
    @DBusBoundProperty(access = Access.READ, name = "HasTrackList")
    fun getHasTrackList(): Boolean

    /** Whether fullscreen can be set via MPRIS (always false). */
    @DBusBoundProperty(access = Access.READ, name = "CanSetFullscreen")
    fun getCanSetFullscreen(): Boolean
}

/**
 * MPRIS Player interface (`org.mpris.MediaPlayer2.Player`): transport control,
 * seek handling, and property accessors backed by [PlayerController].
 */
@DBusInterfaceName(MprisService.PLAYER_IFACE)
interface MprisPlayerIface : DBusInterface {
    /** Skips to the next track. */
    fun Next()
    /** Skips to the previous track. */
    fun Previous()
    /** Pauses playback. */
    fun Pause()
    /** Toggles between playing and paused. */
    fun PlayPause()
    /** Stops playback. */
    fun Stop()
    /** Starts or resumes playback. */
    fun Play()
    /**
     * Seeks relative to the current position.
     *
     * @param offsetMicros Signed seek offset in microseconds.
     */
    fun Seek(offsetMicros: Long)
    /**
     * Seeks to an absolute position within a track.
     *
     * @param trackId D-Bus path of the track; ignored unless it matches the current track.
     * @param positionMicros Absolute position in microseconds.
     */
    fun SetPosition(trackId: DBusPath, positionMicros: Long)
    /**
     * Opens a URI (accepted for spec compliance; no-op).
     *
     * @param uri URI the client asks to open.
     */
    fun OpenUri(uri: String)

    /** Current playback status ("Playing", "Paused", or "Stopped"). */
    @DBusBoundProperty(access = Access.READ, name = "PlaybackStatus")
    fun getPlaybackStatus(): String

    /** Current track metadata map. */
    @DBusBoundProperty(access = Access.READ, name = "Metadata")
    fun getMetadata(): Map<String, Variant<*>>

    /**
     * Current position in microseconds.
     *
     * Excluded from change signals; clients learn it via Seeked/PropertiesChanged instead.
     */
    @DBusBoundProperty(
        access = Access.READ,
        name = "Position",
        emitChangeSignal = EmitChangeSignal.FALSE,
    )
    fun getPosition(): Long

    /** Playback rate (fixed 1.0). */
    @DBusBoundProperty(access = Access.READ, name = "Rate")
    fun getRate(): Double

    /** Minimum supported rate (fixed 1.0). */
    @DBusBoundProperty(access = Access.READ, name = "MinimumRate")
    fun getMinimumRate(): Double

    /** Maximum supported rate (fixed 1.0). */
    @DBusBoundProperty(access = Access.READ, name = "MaximumRate")
    fun getMaximumRate(): Double

    /** Whether a next track is available. */
    @DBusBoundProperty(access = Access.READ, name = "CanGoNext")
    fun getCanGoNext(): Boolean

    /** Whether a previous track is available. */
    @DBusBoundProperty(access = Access.READ, name = "CanGoPrevious")
    fun getCanGoPrevious(): Boolean

    /** Whether playback can start. */
    @DBusBoundProperty(access = Access.READ, name = "CanPlay")
    fun getCanPlay(): Boolean

    /** Whether playback can pause. */
    @DBusBoundProperty(access = Access.READ, name = "CanPause")
    fun getCanPause(): Boolean

    /** Whether seeking is supported. */
    @DBusBoundProperty(access = Access.READ, name = "CanSeek")
    fun getCanSeek(): Boolean

    /** Whether the player accepts external control (always true). */
    @DBusBoundProperty(access = Access.READ, name = "CanControl")
    fun getCanControl(): Boolean

    /** Loop mode ("None", "Track", or "Playlist"). */
    @DBusBoundProperty(access = Access.READ, name = "LoopStatus")
    fun getLoopStatus(): String

    /**
     * Sets the loop mode.
     *
     * @param value "Track", "Playlist", or anything else for off.
     */
    @DBusBoundProperty(access = Access.WRITE, name = "LoopStatus")
    fun setLoopStatus(value: String)

    /** Volume as a 0.0 to 1.0 fraction. */
    @DBusBoundProperty(access = Access.READ, name = "Volume")
    fun getVolume(): Double

    /**
     * Sets the volume.
     *
     * @param value Volume as a 0.0 to 1.0 fraction.
     */
    @DBusBoundProperty(access = Access.WRITE, name = "Volume")
    fun setVolume(value: Double)

    /** Whether shuffle is enabled. */
    @DBusBoundProperty(access = Access.READ, name = "Shuffle")
    fun getShuffle(): Boolean

    /**
     * Sets shuffle mode.
     *
     * @param value Whether shuffle should be enabled.
     */
    @DBusBoundProperty(access = Access.WRITE, name = "Shuffle")
    fun setShuffle(value: Boolean)

    /**
     * Seek notification signal emitted when the controller performs a seek.
     *
     * @param path Object path emitting the signal.
     * @param positionMicros New position in microseconds.
     */
    @DBusMemberName("Seeked")
    class SeekedSignal(path: String, positionMicros: Long) : DBusSignal(path, positionMicros)
}

/**
 * D-Bus object exported at [MprisService.OBJECT_PATH], implementing both MPRIS interfaces.
 *
 * Delegates transport and property reads to [PlayerController]; all seeks funnel
 * through the controller so UI, keyboard, and MPRIS stay on one timeline.
 *
 * @param controller Player backend receiving commands and providing state.
 * @param onQuit Callback invoked when a client calls Quit.
 * @param lengthUs Length provider used for `mpris:length` (stabilized duration).
 */
class MprisObject(
    private val controller: PlayerController,
    private val onQuit: () -> Unit,
    private val lengthUs: (PlayerState) -> Long = ::metadataLengthUs,
) : MprisRootIface, MprisPlayerIface {
    /** D-Bus object path this instance is exported at. */
    override fun getObjectPath(): String = MprisService.OBJECT_PATH

    private val s get() = controller.state.value

    // ---- Root ----
    /** No-op: the single window cannot be raised on demand. */
    override fun Raise() = Unit
    /** Quits the application. */
    override fun Quit() = onQuit()
    /** @return The application identity ("NixieTube"). */
    override fun getIdentity(): String = "NixieTube"
    /** @return The desktop-entry name ("nixietube"). */
    override fun getDesktopEntry(): String = "nixietube"
    /** @return URI schemes the player can open. */
    override fun getSupportedUriSchemes(): List<String> = listOf("https")
    /** @return MIME types the player can handle. */
    override fun getSupportedMimeTypes(): List<String> =
        listOf("audio/webm", "audio/mpeg", "audio/mp4")
    /** @return True: quitting via MPRIS is supported. */
    override fun getCanQuit(): Boolean = true
    /** @return False: raising is not supported. */
    override fun getCanRaise(): Boolean = false
    /** @return False: no track list is provided. */
    override fun getHasTrackList(): Boolean = false
    /** @return False: fullscreen cannot be set via MPRIS. */
    override fun getCanSetFullscreen(): Boolean = false

    // ---- Player ----
    /** Skips to the next track. */
    override fun Next() = controller.next()
    /** Skips to the previous track. */
    override fun Previous() = controller.previous()
    /** Pauses when currently playing. */
    override fun Pause() {
        if (s.playing) controller.togglePlayPause()
    }
    /** Starts playback when a track is loaded. */
    override fun Play() {
        if (s.current != null) controller.play()
    }
    /** Toggles play/pause when a track is loaded. */
    override fun PlayPause() {
        if (s.current != null) controller.togglePlayPause()
    }
    /** Stops playback when a track is loaded. */
    override fun Stop() {
        if (s.current != null) controller.stop()
    }
    /**
     * Seeks relative to the current position, advancing to next on overrun.
     *
     * @param offsetMicros Signed seek offset in microseconds.
     */
    override fun Seek(offsetMicros: Long) {
        val state = s
        if (state.current == null || !getCanSeek()) return
        val lengthMs = metadataLengthMs(state)
        val target = try {
            Math.addExact(state.positionMs, offsetMicros / 1000L)
        } catch (_: ArithmeticException) {
            if (offsetMicros > 0L) Long.MAX_VALUE else Long.MIN_VALUE
        }
        if (lengthMs > 0L && target > lengthMs) {
            controller.next()
            return
        }
        controller.seekTo(target)
    }
    /**
     * Seeks to an absolute position, ignoring mismatched tracks and out-of-range values per spec.
     *
     * @param trackId D-Bus path of the track; ignored unless it matches the current track.
     * @param positionMicros Absolute position in microseconds.
     */
    override fun SetPosition(trackId: DBusPath, positionMicros: Long) {
        // Spec: ignore when the id does not match the current track or the
        // requested absolute position is outside the track.
        val state = s
        val current = state.current ?: return
        if (trackId.path != trackPath(current.videoId)) return
        if (positionMicros < 0L) return
        val target = positionMicros / 1000L
        val lengthMs = metadataLengthMs(state)
        if (lengthMs > 0L && target > lengthMs) return
        controller.seekTo(target)
    }
    /**
     * Accepted for spec compliance; URIs are not opened.
     *
     * @param uri URI the client asks to open.
     */
    override fun OpenUri(uri: String) = Unit

    /** @return "Playing", "Paused", or "Stopped" for the current state. */
    override fun getPlaybackStatus(): String = when {
        s.current == null || s.stopped -> "Stopped"
        s.playing -> "Playing"
        else -> "Paused"
    }

    /**
     * Returns the current track metadata with path-safe trackid and stabilized length.
     *
     * @return Metadata map, or empty when nothing is loaded.
     */
    override fun getMetadata(): Map<String, Variant<*>> {
        val state = s
        val track = state.current ?: return emptyMap()
        return linkedMapOf<String, Variant<*>>(
            "mpris:trackid" to Variant(DBusPath(trackPath(track.videoId))),
            "mpris:length" to Variant(UInt64(lengthUs(state))),
            "xesam:title" to Variant(cleanText(track.title)),
            "xesam:artist" to Variant(
                track.artists.map { cleanText(it.name, 512) }.filter { it.isNotBlank() },
                "as",
            ),
            "xesam:album" to Variant(cleanText(track.album?.name.orEmpty())),
        ).also { metadata ->
            artworkUrl(track)?.let { metadata["mpris:artUrl"] = Variant(cleanText(it)) }
            metadata["xesam:url"] =
                Variant("https://music.youtube.com/watch?v=${track.videoId}")
        }
    }

    /** @return Current position in microseconds, clamped to the track length. */
    override fun getPosition(): Long = positionUs(s)
    /** @return Fixed 1.0 rate. */
    override fun getRate(): Double = 1.0
    /** @return Fixed 1.0 minimum rate. */
    override fun getMinimumRate(): Double = 1.0
    /** @return Fixed 1.0 maximum rate. */
    override fun getMaximumRate(): Double = 1.0
    /** @return True when a next track exists in-queue or via autoplay. */
    override fun getCanGoNext(): Boolean = canGoNext(s)
    /** @return True when a previous track exists. */
    override fun getCanGoPrevious(): Boolean = s.index > 0
    /** @return True when a track is loaded. */
    override fun getCanPlay(): Boolean = s.current != null
    /** @return True when a track is loaded. */
    override fun getCanPause(): Boolean = s.current != null
    /** @return True when a track is loaded. */
    override fun getCanSeek(): Boolean = s.current != null
    /** @return True: external control is always accepted. */
    override fun getCanControl(): Boolean = true

    /** @return Loop mode mapped to "None", "Track", or "Playlist". */
    override fun getLoopStatus(): String = when (s.repeat) {
        RepeatMode.OFF -> "None"
        RepeatMode.ONE -> "Track"
        RepeatMode.ALL -> "Playlist"
    }

    /**
     * Maps an MPRIS loop value onto the player repeat mode.
     *
     * @param value "Track", "Playlist", or anything else for off.
     */
    override fun setLoopStatus(value: String) {
        controller.setRepeat(
            when (value) {
                "Track" -> RepeatMode.ONE
                "Playlist" -> RepeatMode.ALL
                else -> RepeatMode.OFF
            },
        )
    }

    /** @return Volume as a 0.0 to 1.0 fraction. */
    override fun getVolume(): Double = s.volume / 100.0
    /**
     * Sets the player volume.
     *
     * @param value Volume as a 0.0 to 1.0 fraction.
     */
    override fun setVolume(value: Double) {
        controller.setVolume((value * 100).toInt())
    }

    /** @return Whether shuffle is enabled. */
    override fun getShuffle(): Boolean = s.shuffle
    /**
     * Sets shuffle mode on the player.
     *
     * @param value Whether shuffle should be enabled.
     */
    override fun setShuffle(value: Boolean) = controller.setShuffle(value)
}
