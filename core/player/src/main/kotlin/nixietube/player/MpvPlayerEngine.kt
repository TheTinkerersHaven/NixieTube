package nixietube.player

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.BufferedReader
import java.io.BufferedWriter
import java.net.UnixDomainSocketAddress
import java.nio.channels.Channels
import java.nio.channels.SocketChannel
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

// Headless mpv backend over a single reusable mpv subprocess driven via
// its JSON IPC socket (--idle keeps it alive across tracks).
//
// Why a subprocess instead of an in-JVM library: decoding/native memory
// lives outside the JVM (smaller app RSS), and control uses only JDK APIs
// (ProcessBuilder + Unix-domain sockets + JSON) — no JNA/JNI, which keeps
// this backend viable for jlink-trimmed runtimes and, later, GraalVM.
// Implements the same PlayerEngine contract, so queue, session, retry,
// MPRIS and Discord logic in PlayerController is untouched.
/**
 * Headless mpv backend over a single reusable mpv subprocess driven via its JSON IPC socket.
 *
 * The subprocess is started with `--idle` so it stays alive across tracks; control
 * commands (loadfile, seek, pause, volume) are sent as JSON IPC messages.
 *
 * @param audioOutput Value for mpv `--ao` (e.g. "null" for headless CI runs); null uses real audio output.
 */
class MpvPlayerEngine(
    // e.g. "null" for headless CI/smoke runs. Null = real audio output.
    private val audioOutput: String? = null,
) : PlayerEngine {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val listeners = CopyOnWriteArrayList<PlayerEngine.Listener>()
    /** Futures for in-flight IPC requests, keyed by request id. */
    private val pending = ConcurrentHashMap<Int, CompletableFuture<JsonObject>>()
    /** Monotonic IPC request id source. */
    private val nextId = AtomicInteger(1)

    private val startLock = Any()
    private val ioLock = Any()
    private var process: Process? = null
    private var channel: SocketChannel? = null
    private var reader: BufferedReader? = null
    private var writer: BufferedWriter? = null

    // Last observed mpv state (property-change events + optimistic
    // control updates). Reads are lock-free for the 500ms ticker.
    @Volatile private var timePosSec: Double? = null
    @Volatile private var durationSec: Double? = null
    @Volatile private var paused = false
    @Volatile private var eofReached = false
    @Volatile private var loaded = false
    @Volatile private var dead = true
    @Volatile private var released = false
    @Volatile private var volume = 80

    /**
     * Loads [url] with `loadfile replace` and unpauses; starts the subprocess on demand.
     *
     * @param url Direct stream URL to play.
     * @return True if mpv accepted the load command.
     */
    override fun play(url: String): Boolean {
        if (released || !ensureStarted()) return false
        eofReached = false
        timePosSec = null
        if (!send(listOf("loadfile", url, "replace"), 10_000)) return false
        loaded = true
        send(listOf("set_property", "pause", false), 2_000)
        paused = false
        return true
    }

    /** Pauses mpv via the `pause` property. */
    override fun pause() {
        if (!isAlive()) return
        send(listOf("set_property", "pause", true), 1_000)
        paused = true
    }

    /** Unpauses mpv via the `pause` property. */
    override fun resume() {
        if (!isAlive()) return
        send(listOf("set_property", "pause", false), 1_000)
        paused = false
    }

    /** Stops the current file; the resulting end-file "stop" event is ignored,
     * as mpv's `stop` never fires "finished" — same semantics as a hard skip.
     */
    override fun stop() {
        if (!isAlive()) {
            loaded = false
            timePosSec = null
            eofReached = false
            return
        }
        send(listOf("stop"), 1_000)
        loaded = false
        timePosSec = null
        eofReached = false
    }

    /**
     * Seeks to an absolute position using `seek <sec> absolute+exact`.
     *
     * @param ms Target position in milliseconds.
     */
    override fun seekTo(ms: Long) {
        if (!isAlive()) return
        val sec = ms.coerceAtLeast(0L) / 1000.0
        send(listOf("seek", sec, "absolute+exact"), 1_000)
        timePosSec = sec
    }

    /**
     * Sets mpv's `volume` property, clamped to 0..100.
     *
     * @param volume0to100 Volume level from 0 to 100.
     */
    override fun setVolume(volume0to100: Int) {
        volume = volume0to100.coerceIn(0, 100)
        if (!isAlive()) return
        send(listOf("set_property", "volume", volume), 1_000)
    }

    /**
     * Returns the last observed playback position.
     *
     * @return Position in milliseconds, or 0 when unknown.
     */
    override fun positionMs(): Long =
        ((timePosSec ?: return 0L) * 1000).toLong().coerceAtLeast(0L)

    /**
     * Returns the last observed media duration.
     *
     * @return Duration in milliseconds, or 0 when unknown.
     */
    override fun durationMs(): Long =
        ((durationSec ?: return 0L) * 1000).toLong().coerceAtLeast(0L)

    /**
     * Reports whether mpv has loaded media and is neither paused nor at EOF.
     *
     * @return True while playback is in progress.
     */
    override fun isPlaying(): Boolean = loaded && !paused && !eofReached

    /** Sends `quit` and destroys the subprocess, sockets, and pending requests. */
    override fun release() {
        synchronized(startLock) {
            released = true
            try {
                send(listOf("quit"), 500)
            } catch (_: Exception) {
            }
            killLocked()
        }
    }

    /**
     * Registers a playback [listener] for finish/error events.
     *
     * @param listener Listener to add.
     */
    override fun addListener(listener: PlayerEngine.Listener) {
        listeners.add(listener)
    }

    // ---------- lifecycle ----------

    /** Resolves the Unix-domain socket path for the mpv IPC server. */
    private fun socketPath(): Path {
        val runtimeDir = System.getenv("XDG_RUNTIME_DIR")?.takeIf { it.isNotBlank() }
            ?: System.getProperty("java.io.tmpdir")
        return Paths.get(runtimeDir, "nixietube-mpv.sock")
    }

    /** Checks that the subprocess is alive and the IPC channel is open. */
    private fun isAlive(): Boolean {
        val p = process ?: return false
        return p.isAlive && !dead && channel?.isOpen == true
    }

    /** Starts the subprocess if needed; serialized so concurrent plays start it once. */
    private fun ensureStarted(): Boolean {
        if (isAlive()) return true
        synchronized(startLock) {
            if (isAlive()) return true
            return try {
                startLocked()
            } catch (_: Exception) {
                false
            }
        }
    }

    /** Spawns the idle mpv subprocess and connects the IPC socket (up to ~8s). */
    private fun startLocked(): Boolean {
        killLocked()
        val sock = socketPath()
        try {
            Files.deleteIfExists(sock)
        } catch (_: Exception) {
        }
        val cmd = mutableListOf(
            "mpv", "--idle=yes", "--keep-open=no", "--no-video", "--audio-display=no",
            "--no-terminal", "--msg-level=all=no", "--network-timeout=30",
            "--input-ipc-server=$sock",
        )
        audioOutput?.let { cmd += "--ao=$it" }
        val pb = ProcessBuilder(cmd)
        pb.redirectOutput(ProcessBuilder.Redirect.DISCARD)
        pb.redirectError(ProcessBuilder.Redirect.DISCARD)
        val proc = try {
            pb.start()
        } catch (_: Exception) {
            return false // mpv binary missing
        }
        process = proc
        var connected = false
        var waited = 0
        while (waited < 8000) {
            if (!proc.isAlive) {
                killLocked()
                return false
            }
            if (Files.exists(sock)) {
                try {
                    channel = SocketChannel.open(UnixDomainSocketAddress.of(sock))
                    connected = true
                    break
                } catch (_: Exception) {
                    // Socket file exists but mpv isn't accepting yet.
                }
            }
            Thread.sleep(100)
            waited += 100
        }
        if (!connected) {
            killLocked()
            return false
        }
        val ch = channel ?: return false
        reader = BufferedReader(Channels.newReader(ch, StandardCharsets.UTF_8))
        writer = BufferedWriter(Channels.newWriter(ch, StandardCharsets.UTF_8))
        dead = false
        startReaderThread()
        // Prime the state cache: mpv answers each observe with the
        // current value immediately.
        send(listOf("observe_property", nextId.getAndIncrement(), "time-pos"), 2_000)
        send(listOf("observe_property", nextId.getAndIncrement(), "duration"), 2_000)
        send(listOf("observe_property", nextId.getAndIncrement(), "pause"), 2_000)
        send(listOf("observe_property", nextId.getAndIncrement(), "eof-reached"), 2_000)
        send(listOf("set_property", "volume", volume), 2_000)
        return true
    }

    /** Tears down the subprocess, channel, and pending requests; safe to call repeatedly. */
    private fun killLocked() {
        dead = true
        pending.entries.forEach { (id, f) ->
            pending.remove(id)?.complete(
                JsonObject(mapOf("error" to JsonPrimitive("closed"))),
            )
        }
        try {
            writer?.close()
        } catch (_: Exception) {
        }
        try {
            channel?.close()
        } catch (_: Exception) {
        }
        writer = null
        reader = null
        channel = null
        try {
            process?.destroy()
            if (process?.waitFor(2, TimeUnit.SECONDS) != true) {
                process?.destroyForcibly()
            }
        } catch (_: Exception) {
        }
        process = null
        try {
            Files.deleteIfExists(socketPath())
        } catch (_: Exception) {
        }
    }

    // ---------- protocol ----------

    /** Sends one JSON IPC command and waits up to [timeoutMs] for its "success" reply. */
    private fun send(parts: List<Any>, timeoutMs: Long): Boolean {
        val id = nextId.getAndIncrement()
        val line = buildJsonObject {
            put("command", buildJsonArray {
                parts.forEach {
                    when (it) {
                        // NB: numbers must stay numeric — JsonPrimitive(str)
                        // would send them as strings and mpv rejects the
                        // command (this silently killed property observers).
                        is String -> add(JsonPrimitive(it))
                        is Int -> add(JsonPrimitive(it))
                        is Long -> add(JsonPrimitive(it))
                        is Double -> add(JsonPrimitive(it))
                        is Float -> add(JsonPrimitive(it))
                        is Boolean -> add(JsonPrimitive(it))
                        is Number -> add(JsonPrimitive(it.toDouble()))
                        else -> add(JsonPrimitive(it.toString()))
                    }
                }
            })
            put("request_id", id)
        }.toString()
        val fut = CompletableFuture<JsonObject>()
        pending[id] = fut
        synchronized(ioLock) {
            val w = writer
            if (w == null || dead) {
                pending.remove(id)
                return false
            }
            try {
                w.write(line)
                w.newLine()
                w.flush()
            } catch (_: Exception) {
                pending.remove(id)
                markDead()
                return false
            }
        }
        return try {
            val resp = fut.get(timeoutMs, TimeUnit.MILLISECONDS)
            resp["error"]?.jsonPrimitive?.contentOrNull == "success"
        } catch (_: Exception) {
            pending.remove(id)
            false
        }
    }

    /** Starts the daemon thread that reads IPC events/responses line by line. */
    private fun startReaderThread() {
        val r = reader ?: return
        thread(name = "mpv-ipc", isDaemon = true) {
            try {
                while (true) {
                    val line = try {
                        r.readLine()
                    } catch (_: Exception) {
                        null
                    } ?: break
                    if (line.isBlank()) continue
                    try {
                        handleLine(line)
                    } catch (_: Exception) {
                    }
                }
            } finally {
                markDead()
            }
        }
    }

    /** Routes one IPC line to a pending request or to property-change/end-file handling. */
    private fun handleLine(line: String) {
        val obj = try {
            json.parseToJsonElement(line) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return
        (obj["request_id"] as? JsonPrimitive)?.intOrNull?.let { id ->
            pending.remove(id)?.complete(obj)
            return
        }
        if (obj["event"]?.jsonPrimitive?.contentOrNull != "property-change" &&
            obj["event"]?.jsonPrimitive?.contentOrNull != "end-file"
        ) {
            return
        }
        when (obj["event"]?.jsonPrimitive?.contentOrNull) {
            "property-change" -> {
                val data = obj["data"] as? JsonPrimitive
                when (obj["name"]?.jsonPrimitive?.contentOrNull) {
                    "time-pos" -> timePosSec = data?.doubleOrNull
                    "duration" -> durationSec = data?.doubleOrNull
                    "pause" -> data?.booleanOrNull?.let { paused = it }
                    // Fallback finish signal: with --keep-open=yes (mpv
                    // forces it under --idle, and user mpv.conf can too)
                    // no end-file event is ever sent — the player just
                    // sits paused at EOF with eof-reached=true. Treat
                    // that as a natural finish. Guarded by `loaded` so
                    // it fires once; the end-file path below clears the
                    // same flag, so the two cannot double-fire.
                    "eof-reached" -> {
                        val reached = data?.booleanOrNull
                        if (reached != null) eofReached = reached
                        if (reached == true && loaded) {
                            loaded = false
                            listeners.toList().forEach {
                                try {
                                    it.onFinished()
                                } catch (_: Exception) {
                                }
                            }
                        }
                    }
                }
            }
            "end-file" -> {
                when (obj["reason"]?.jsonPrimitive?.contentOrNull) {
                    "eof" -> {
                        loaded = false
                        listeners.toList().forEach {
                            try {
                                it.onFinished()
                            } catch (_: Exception) {
                            }
                        }
                    }
                    "error" -> {
                        val msg = obj["error"]?.jsonPrimitive?.contentOrNull
                            ?.takeIf { it.isNotBlank() } ?: "mpv playback error"
                        listeners.toList().forEach {
                            try {
                                it.onError(msg)
                            } catch (_: Exception) {
                            }
                        }
                    }
                    // "stop"/"quit"/"redirect": user- or controller-
                    // initiated, never a finish or an error.
                }
            }
        }
    }

    /** Marks the subprocess dead and surfaces mid-track death as an engine error for retry. */
    private fun markDead() {
        val wasLoaded = loaded
        dead = true
        loaded = false
        pending.entries.forEach { (id, f) ->
            pending.remove(id)?.complete(
                JsonObject(mapOf("error" to JsonPrimitive("closed"))),
            )
        }
        // A dead subprocess mid-track surfaces as an engine error so
        // PlayerController's retry path (fresh process on next play)
        // kicks in. Silent after release() or when idle.
        if (!released && wasLoaded) {
            listeners.toList().forEach {
                try {
                    it.onError("mpv process died")
                } catch (_: Exception) {
                }
            }
        }
    }

    companion object {
        /**
         * Probes for an `mpv` binary on PATH.
         *
         * @return True if `mpv --version` exits 0 within 5 seconds.
         */
        fun isAvailable(): Boolean {
            return try {
                val p = ProcessBuilder("mpv", "--version")
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start()
                val done = p.waitFor(5, TimeUnit.SECONDS)
                if (!done) p.destroyForcibly()
                done && p.exitValue() == 0
            } catch (_: Exception) {
                false
            }
        }
    }
}
