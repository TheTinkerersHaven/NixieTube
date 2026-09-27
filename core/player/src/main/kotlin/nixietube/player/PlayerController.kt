package nixietube.player

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import nixietube.innertube.AlbumRef
import nixietube.innertube.ArtistRef
import nixietube.innertube.InnerTube
import nixietube.innertube.StreamResolver
import nixietube.innertube.Thumbnail
import nixietube.innertube.RatingStatus
import nixietube.innertube.Track

/** Mid-stream resume attempts before surfacing the error. */
private const val MAX_STREAM_RETRIES = 2

/** Position ticker cadence while playing. */
private const val TICKER_INTERVAL_MS = 500L

/** Below this position, previous restarts the track instead of going back. */
private const val PREVIOUS_RESTART_THRESHOLD_MS = 3000L

/** How long a seek target is held before the engine position wins. */
private const val SEEK_SETTLE_TIMEOUT_NS = 6_000_000_000L

/** Engine positions within this window count as arrived after a seek. */
private const val SEEK_ARRIVAL_TOLERANCE_MS = 1000L

/**
 * Queue repeat behavior.
 */
enum class RepeatMode {
    /** No repeat; playback stops (or continues radio) at the queue end. */
    OFF,
    /** Loops the whole queue from the start. */
    ALL,
    /** Repeats the current track. */
    ONE
}

/** Serializable snapshot of queue/index/position persisted across restarts. */
@Serializable
private data class SessionData(
    val version: Int = 1,
    val queue: List<Track> = emptyList(),
    val index: Int = -1,
    val positionMs: Long = 0L,
    val volume: Int = 80,
)

/** Normalizes artist/album names for case- and punctuation-insensitive comparison. */
private fun canonicalPlayerMetadata(value: String): String =
    value.lowercase()
        .replace(Regex("[^a-z0-9]+"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

/** Best-effort file debug logger for resolve/retry diagnostics. */
internal object PlayerDebug {
    /**
     * Appends [line] to the player debug log, swallowing I/O errors.
     *
     * @param line Log line without timestamp.
     */
    fun log(line: String) {
        try {
            java.io.File("/tmp/nixietube-player-debug.log")
                .appendText(java.time.Instant.now().toString() + " " + line + "\n")
        } catch (_: Exception) {
        }
    }
}

/**
 * Observable playback snapshot emitted by [PlayerController].
 *
 * @property current Currently loaded track, if any.
 * @property playing True while audio is playing.
 * @property stopped True after an explicit stop (session cleared).
 * @property loading True while the next stream URL is resolving/starting.
 * @property positionMs Current playback position in milliseconds.
 * @property seekEpoch Incremented on every seek so sliders can re-anchor.
 * @property durationMs Track duration in milliseconds (catalog value until the engine reports).
 * @property volume Output volume from 0 to 100.
 * @property queue Ordered playback queue.
 * @property index Position of the current track within [queue].
 * @property shuffle Whether shuffle is enabled.
 * @property repeat Queue repeat behavior.
 * @property autoplay Whether queue exhaustion continues via radio up-next.
 * @property error Last error message, if any.
 */
data class PlayerState(
    val current: Track? = null,
    val playing: Boolean = false,
    val stopped: Boolean = false,
    val loading: Boolean = false,
    val positionMs: Long = 0L,
    val seekEpoch: Long = 0L,
    val durationMs: Long = 0L,
    val volume: Int = 80,
    val queue: List<Track> = emptyList(),
    val index: Int = -1,
    val shuffle: Boolean = false,
    val repeat: RepeatMode = RepeatMode.OFF,
    val autoplay: Boolean = true,
    val error: String? = null,
)

// Queue + state ownership. No UI imports: safe to reuse under any frontend.
/**
 * Owns the playback queue and exposes it as a [PlayerState] flow.
 *
 * Resolves stream URLs, drives the [PlayerEngine], polls position via a ticker,
 * retries dying streams with a bounded budget, and persists/restores sessions.
 * Stale async work is fenced by an incrementing play token.
 *
 * @param engine Backend that performs actual audio playback.
 * @param tube API used for radio up-next continuation.
 * @param scope Coroutine scope for resolve/ticker/error work.
 */
class PlayerController(
    private val engine: PlayerEngine,
    private val tube: InnerTube,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val _state = MutableStateFlow(PlayerState())
    /** Observable playback snapshot. */
    val state: StateFlow<PlayerState> = _state.asStateFlow()

    private var ticker: Job? = null
    /** Fencing token: stale resolve/ticker work aborts when it no longer matches. */
    @Volatile
    private var playToken = 0
    private var lastSessionSaveMs = 0L
    private val sessionJson = Json { ignoreUnknownKeys = true }
    // Video id the engine actually has loaded. A restored session sets
    // player state without touching the engine, so resume must detect the
    // mismatch and start fresh instead of resuming an empty engine.
    @Volatile
    private var loadedVideoId: String? = null
    // Retry budget for dying streams (fresh URL, same position).
    /** Consecutive mid-stream retry attempts for the current track (max 2). */
    @Volatile
    private var streamRetries = 0
    /** Most recent seek target, held until the engine position demonstrably arrives. */
    @Volatile
    private var pendingSeekTargetMs: Long? = null
    /** Time the pending seek was issued, for the 6s settle timeout. */
    @Volatile
    private var pendingSeekAtNanos: Long = 0L

    init {
        engine.setVolume(80)
        engine.addListener(object : PlayerEngine.Listener {
            override fun onFinished() = scope.launch { onTrackFinished() }.let { }
            override fun onError(message: String) {
                scope.launch { handleEngineError(message) }.let { }
            }
        })
    }

    /** Retries a dying stream with a fresh URL, else surfaces [message] as state error. */
    private suspend fun handleEngineError(message: String) {
        val failed = _state.value
        val track = failed.current
        val resumeAt = failed.positionMs
        // Expiring URLs and flaky streams die mid-playback; mint a fresh
        // URL and resume where we left off. Bounded retries: a permanently
        // unplayable track still surfaces its error.
        val retrySameTrack = track != null && !failed.stopped && streamRetries < MAX_STREAM_RETRIES &&
            _state.value.current?.videoId == track.videoId
        if (track != null && retrySameTrack) {
            streamRetries++
            PlayerDebug.log(
                "stream retry #${streamRetries} videoId=${track.videoId} at=${resumeAt}ms " +
                    "cause=${message.take(120)}",
            )
            val stream = StreamResolver.resolve(track.videoId)
            val now = _state.value
            if (stream != null && now.current?.videoId == track.videoId && !now.stopped) {
                _state.update { it.copy(loading = true, error = null) }
                if (engine.play(stream.url)) {
                    engine.seekTo(resumeAt)
                    loadedVideoId = track.videoId
                    _state.update { it.copy(loading = false, playing = true) }
                    startTicker()
                    return
                }
            }
        }
        streamRetries = 0
        PlayerDebug.log("engine error: $message current=${track?.videoId}")
        _state.update { it.copy(playing = false, loading = false, error = message) }
    }

    /**
     * Replaces the queue with [tracks] and starts at [startIndex].
     *
     * @param tracks New queue contents; ignored when empty.
     * @param startIndex Index to start playback at.
     */
    fun playTracks(tracks: List<Track>, startIndex: Int = 0) {
        if (tracks.isEmpty()) return
        _state.update { it.copy(queue = tracks, index = startIndex.coerceIn(tracks.indices)) }
        startCurrent()
    }

    /**
     * Inserts [track] immediately after the current index.
     *
     * @param track Track to play next.
     */
    fun enqueueNext(track: Track) {
        _state.update {
            val q = it.queue.toMutableList()
            val at = (it.index + 1).coerceAtMost(q.size)
            q.add(at, track)
            it.copy(queue = q)
        }
    }

    /**
     * Appends [track] to the end of the queue.
     *
     * @param track Track to append.
     */
    fun enqueueLast(track: Track) {
        _state.update { it.copy(queue = it.queue + track) }
    }

    /**
     * Jumps to the queue entry at [index] and starts it.
     *
     * @param index Queue index to play; ignored when out of bounds.
     */
    fun playAt(index: Int) {
        val q = _state.value.queue
        if (index in q.indices) {
            _state.update { it.copy(index = index) }
            startCurrent()
        }
    }

    /** Toggles between pause and resume; restarts when stopped or the engine holds another track. */
    fun togglePlayPause() {
        val s = _state.value
        if (s.current == null || s.loading) return
        if (s.stopped || loadedVideoId != s.current.videoId) {
            startCurrent()
            return
        }
        if (s.playing) {
            engine.pause()
            _state.update { it.copy(playing = false) }
            saveSession()
        } else {
            engine.resume()
            _state.update { it.copy(playing = true, stopped = false, error = null) }
            startTicker()
        }
    }

    /** Resumes playback; restarts the current track when stopped or not loaded in the engine. */
    fun play() {
        val s = _state.value
        if (s.current == null || s.playing || s.loading) return
        if (s.stopped || loadedVideoId != s.current.videoId) {
            startCurrent()
            return
        }
        engine.resume()
        _state.update { it.copy(playing = true, stopped = false, error = null) }
        startTicker()
    }

    /** Stops playback, invalidates in-flight work, and deletes the persisted session. */
    fun stop() {
        playToken++
        ticker?.cancel()
        ticker = null
        engine.stop()
        loadedVideoId = null
        pendingSeekTargetMs = null
        pendingSeekAtNanos = 0L
        _state.update {
            it.copy(playing = false, stopped = true, loading = false, positionMs = 0)
        }
        // Explicit stop forgets the session; quitting any other way resumes it.
        try {
            sessionFile().delete()
        } catch (_: Exception) {
        }
    }

    // Persists queue/index/position so relaunching restores the session
    // instead of resetting to 0:00. Skipped while stopped (see stop()).
    /** Persists queue, index, position, and volume; skipped while stopped or empty. */
    fun saveSession() {
        try {
            val s = _state.value
            if (s.current == null || s.stopped) return
            if (s.queue.isEmpty() || s.index !in s.queue.indices) return
            sessionFile().writeText(
                sessionJson.encodeToString(
                    SessionData(
                        queue = s.queue,
                        index = s.index,
                        positionMs = s.positionMs.coerceAtLeast(0L),
                        volume = s.volume,
                    ),
                ),
            )
            lastSessionSaveMs = System.currentTimeMillis()
        } catch (_: Exception) {
        }
    }

    // Restores a saved session paused at its position. Never autoplays:
    // streams are re-resolved on play, so no stale URLs are kept.
    /**
     * Restores the persisted session paused at its saved position without autoplaying.
     *
     * @return True if a valid session was restored.
     */
    fun restoreSession(): Boolean {
        return try {
            val f = sessionFile()
            val data = if (f.exists()) {
                sessionJson.decodeFromString<SessionData>(f.readText())
            } else {
                null
            }
            if (data == null || data.queue.isEmpty() || data.index !in data.queue.indices) return false
            val track = data.queue[data.index]
            val catalogMs = track.durationSec * 1000L
            val pos = data.positionMs.coerceIn(0L, if (catalogMs > 0L) catalogMs else Long.MAX_VALUE)
            engine.setVolume(data.volume.coerceIn(0, 100))
            _state.update {
                it.copy(
                    queue = data.queue,
                    index = data.index,
                    current = track,
                    playing = false,
                    stopped = false,
                    loading = false,
                    positionMs = pos,
                    durationMs = catalogMs,
                    volume = data.volume.coerceIn(0, 100),
                    error = null,
                )
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Resolves the playback-session JSON file under ~/.config/nixietube. */
    private fun sessionFile(): java.io.File {
        val dir = java.io.File(System.getProperty("user.home"), ".config/nixietube")
            .also { it.mkdirs() }
        return java.io.File(dir, "playback-session.json")
    }

    /**
     * Advances to the next track, honoring repeat and radio autoplay at the queue end.
     *
     * @param manual True for user presses; automatic finishes replay the track under RepeatMode.ONE.
     */
    fun next(manual: Boolean = true) {
        val s = _state.value
        if (s.repeat == RepeatMode.ONE && !manual) {
            startCurrent()
            return
        }
        val nextIndex = s.index + 1
        if (nextIndex in s.queue.indices) {
            _state.update { it.copy(index = nextIndex) }
            startCurrent()
        } else if (s.repeat == RepeatMode.ALL && s.queue.isNotEmpty()) {
            _state.update { it.copy(index = 0) }
            startCurrent()
        } else if (s.autoplay) {
            // Queue exhausted: continue the station via up-next when possible.
            scope.launch { continueRadio() }
        } else {
            _state.update { it.copy(playing = false) }
        }
    }

    /** Goes to the previous track, or restarts when past 3s or at the queue head. */
    fun previous() {
        val s = _state.value
        if (s.positionMs > PREVIOUS_RESTART_THRESHOLD_MS || s.index <= 0) {
            seekTo(0)
        } else {
            _state.update { it.copy(index = s.index - 1) }
            startCurrent()
        }
    }

    /**
     * Seeks to [ms], clamped to the known duration, and holds the target until the engine settles.
     *
     * @param ms Target position in milliseconds.
     */
    fun seekTo(ms: Long) {
        val duration = _state.value.durationMs
        val target = ms.coerceAtLeast(0L).let {
            if (duration > 0L) it.coerceAtMost(duration) else it
        }
        engine.seekTo(target)
        pendingSeekTargetMs = target
        pendingSeekAtNanos = System.nanoTime()
        _state.update {
            it.copy(positionMs = target, seekEpoch = it.seekEpoch + 1L)
        }
    }

    /**
     * Sets engine and state volume, clamped to 0..100.
     *
     * @param v Volume level from 0 to 100.
     */
    fun setVolume(v: Int) {
        engine.setVolume(v)
        _state.update { it.copy(volume = v.coerceIn(0, 100)) }
    }

    /** Flips the shuffle flag. */
    fun toggleShuffle() = _state.update { it.copy(shuffle = !it.shuffle) }

    /**
     * Sets the shuffle flag to [v].
     *
     * @param v New shuffle value.
     */
    fun setShuffle(v: Boolean) = _state.update { it.copy(shuffle = v) }

    // Fills missing release metadata in place (from LRCLIB or InnerTube) so
    // downstream consumers (Discord, MPRIS) pick it up reactively.
    /**
     * Merges late-arriving release metadata into the matching queue/current track.
     *
     * @param videoId Track to update.
     * @param artists Incoming artist refs; replace only when they add information.
     * @param album Incoming album ref, if known.
     * @param thumbnails Additional thumbnails to merge by URL.
     * @param title Corrected title, if known.
     */
    fun updateTrackMetadata(
        videoId: String,
        artists: List<ArtistRef> = emptyList(),
        album: AlbumRef? = null,
        thumbnails: List<Thumbnail> = emptyList(),
        title: String? = null,
    ) {
        val incomingAlbum: AlbumRef? = album
        val incomingTitle = title?.trim()?.takeIf { it.isNotBlank() }
        val hasNoUpdates = artists.isEmpty() && incomingAlbum == null &&
            thumbnails.isEmpty() && incomingTitle == null
        if (hasNoUpdates) return
        _state.update { s ->
            fun fix(t: Track): Track {
                if (t.videoId != videoId) return t
                val existingArtistKeys = t.artists.map { canonicalPlayerMetadata(it.name) }.toSet()
                val incomingAddsArtist = artists.any {
                    canonicalPlayerMetadata(it.name) !in existingArtistKeys
                }
                val incomingAddsIdentity = artists.any { incoming ->
                    val key = canonicalPlayerMetadata(incoming.name)
                    t.artists.any { existing ->
                        canonicalPlayerMetadata(existing.name) == key &&
                            existing.browseId.isNullOrBlank() && !incoming.browseId.isNullOrBlank()
                    }
                }
                val replaceArtist = t.artists.isEmpty() ||
                    t.artistNames.trim().equals("Release", ignoreCase = true) ||
                    artists.size > t.artists.size || incomingAddsArtist || incomingAddsIdentity
                val existingAlbum = t.album
                val knownArtists = t.artists + artists
                val existingAlbumIsUnlinkedArtist = existingAlbum != null &&
                    existingAlbum.browseId.isNullOrBlank() && existingAlbum.kind == null &&
                    knownArtists.any {
                        canonicalPlayerMetadata(it.name) == canonicalPlayerMetadata(existingAlbum.name)
                    }
                val mergedAlbum = when {
                    incomingAlbum == null && existingAlbumIsUnlinkedArtist -> null
                    incomingAlbum == null -> existingAlbum
                    existingAlbum == null -> incomingAlbum
                    existingAlbum.name.trim().equals("Release", ignoreCase = true) -> incomingAlbum
                    existingAlbumIsUnlinkedArtist -> incomingAlbum
                    existingAlbum.browseId == null && incomingAlbum.browseId != null -> incomingAlbum
                    existingAlbum.kind == null && incomingAlbum.kind != null -> existingAlbum.copy(
                        name = incomingAlbum.name.ifBlank { existingAlbum.name },
                        browseId = incomingAlbum.browseId ?: existingAlbum.browseId,
                        kind = incomingAlbum.kind,
                    )
                    else -> existingAlbum
                }
                // Year arrives later than the rest (extra album-page fetch
                // in enrichTrack): fill it in even when the album ref
                // itself was already resolved and kept above.
                val mergedYear = mergedAlbum?.year?.takeIf { it.isNotBlank() }
                    ?: incomingAlbum?.year?.takeIf { it.isNotBlank() }.orEmpty()
                val finalAlbum = if (mergedAlbum != null && mergedAlbum.year.isBlank() &&
                    mergedYear.isNotBlank()
                ) {
                    mergedAlbum.copy(year = mergedYear)
                } else {
                    mergedAlbum
                }
                // InnerTube may discover the canonical cover only after
                // playback starts. Merge it into the live track so Discord
                // and MPRIS receive a state emission instead of retaining a
                // missing/stale image for the rest of the session.
                val mergedThumbnails = (t.thumbnails + thumbnails)
                    .distinctBy { it.url }
                return t.copy(
                    title = incomingTitle ?: t.title,
                    artists = if (replaceArtist && artists.isNotEmpty()) artists else t.artists,
                    album = finalAlbum,
                    thumbnails = mergedThumbnails,
                )
            }
            s.copy(
                current = s.current?.let(::fix),
                queue = s.queue.map(::fix),
            )
        }
    }

    /**
     * Updates the rating of the track with [videoId] in queue and current state.
     *
     * @param videoId Track to update.
     * @param rating New rating status.
     */
    fun updateTrackRating(videoId: String, rating: RatingStatus) {
        _state.update { state ->
            fun update(track: Track): Track =
                if (track.videoId == videoId) track.copy(rating = rating) else track
            state.copy(
                current = state.current?.let(::update),
                queue = state.queue.map(::update),
            )
        }
    }

    // Public counters from the stream resolver (-1 = unknown, never
    // overwrites a known value with unknown).
    /**
     * Updates like/dislike counters; -1 values never overwrite known counts.
     *
     * @param videoId Track to update.
     * @param likeCount New like count, or -1 when unknown.
     * @param dislikeCount New dislike count, or -1 when unknown.
     */
    fun updateTrackStats(videoId: String, likeCount: Long, dislikeCount: Long) {
        if (likeCount < 0 && dislikeCount < 0) return
        _state.update { state ->
            fun update(track: Track): Track {
                if (track.videoId != videoId) return track
                return track.copy(
                    likeCount = if (likeCount >= 0) likeCount else track.likeCount,
                    dislikeCount = if (dislikeCount >= 0) dislikeCount else track.dislikeCount,
                )
            }
            state.copy(
                current = state.current?.let(::update),
                queue = state.queue.map(::update),
            )
        }
    }

    /**
     * Sets the album name of the track with [videoId]; blank names are ignored.
     *
     * @param videoId Track to update.
     * @param albumName New album name.
     */
    fun updateTrackAlbum(videoId: String, albumName: String) {
        if (albumName.isBlank()) return
        updateTrackMetadata(videoId, album = AlbumRef(albumName))
    }

    /** Cycles repeat mode OFF -> ALL -> ONE -> OFF. */
    fun cycleRepeat() = _state.update {
        it.copy(repeat = when (it.repeat) {
            RepeatMode.OFF -> RepeatMode.ALL
            RepeatMode.ALL -> RepeatMode.ONE
            RepeatMode.ONE -> RepeatMode.OFF
        })
    }

    /**
     * Sets the repeat [mode].
     *
     * @param mode New repeat mode.
     */
    fun setRepeat(mode: RepeatMode) = _state.update { it.copy(repeat = mode) }

    /** Flips the autoplay flag for radio continuation. */
    fun toggleAutoplay() = _state.update { it.copy(autoplay = !it.autoplay) }

    /** Clears the current error message. */
    fun clearError() = _state.update { it.copy(error = null) }

    /** Resolves the current track's stream URL and starts engine playback under a fresh token. */
    private fun startCurrent() {
        val track = _state.value.queue.getOrNull(_state.value.index) ?: return
        val token = ++playToken
        streamRetries = 0
        loadedVideoId = null
        // A previous track's ticker must not publish its old engine position
        // while the next stream is resolving.
        ticker?.cancel()
        ticker = null
        engine.stop()
        pendingSeekTargetMs = null
        pendingSeekAtNanos = 0L
        _state.update {
            it.copy(
                current = track,
                loading = true,
                playing = false,
                stopped = false,
                positionMs = 0,
                durationMs = (track.durationSec * 1000).toLong(),
                error = null,
            )
        }
        saveSession()
        scope.launch {
            val stream = StreamResolver.resolve(track.videoId)
            if (token != playToken) return@launch
            if (stream == null) {
                PlayerDebug.log("resolve FAILED videoId=${track.videoId} title=${track.title}")
                _state.update { it.copy(loading = false, error = "No playable stream (region/age restriction?)") }
                return@launch
            }
            PlayerDebug.log("resolve ok videoId=${track.videoId} bitrate=${stream.bitrate} codec=${stream.codec}")
            val ok = engine.play(stream.url)
            PlayerDebug.log("engine.play -> $ok videoId=${track.videoId}")
            if (token != playToken) return@launch
            if (!ok) {
                _state.update { it.copy(loading = false, error = "Playback failed to start") }
                return@launch
            }
            if (token == playToken) loadedVideoId = track.videoId
            _state.update { it.copy(loading = false, playing = true) }
            updateTrackStats(track.videoId, stream.likes, stream.dislikes)
            startTicker()
        }
    }

    /** Advances on natural finish unless explicitly stopped. */
    private suspend fun onTrackFinished() {
        if (_state.value.stopped) return
        next(manual = false)
    }

    /** Appends unseen up-next tracks and starts the first one to continue the station. */
    private suspend fun continueRadio() {
        val current = _state.value.current ?: run {
            _state.update { it.copy(playing = false) }
            return
        }
        val radioId = current.radioPlaylistId
        val upcoming = try {
            tube.upNext(current.videoId, radioId)
        } catch (_: Exception) {
            emptyList()
        }.filter { t -> _state.value.queue.none { q -> q.videoId == t.videoId } }
        if (upcoming.isEmpty()) {
            _state.update { it.copy(playing = false) }
            return
        }
        _state.update { it.copy(queue = it.queue + upcoming, index = it.queue.size) }
        startCurrent()
    }

    /** Polls engine position/duration every 500ms, masking slow seeks and persisting the session. */
    private fun startTicker() {
        ticker?.cancel()
        val token = playToken
        ticker = scope.launch {
            while (isActive && token == playToken) {
                delay(TICKER_INTERVAL_MS)
                if (token != playToken) return@launch
                val rawPos = engine.positionMs().let { if (it < 0) 0 else it }
                val target = pendingSeekTargetMs
                // Network-stream seeks routinely take seconds (buffer flush +
                // re-request). Snapping back to the engine position too early
                // is exactly what desyncs sliders after a jump: report the
                // target until the engine demonstrably arrives (1s window)
                // or a generous timeout elapses.
                val seekAgeNanos = if (target != null) System.nanoTime() - pendingSeekAtNanos else 0L
                val pos = if (target != null && seekAgeNanos in 0..SEEK_SETTLE_TIMEOUT_NS &&
                    kotlin.math.abs(rawPos - target) > SEEK_ARRIVAL_TOLERANCE_MS
                ) {
                    target
                } else {
                    if (target != null && kotlin.math.abs(rawPos - target) <= SEEK_ARRIVAL_TOLERANCE_MS) {
                        pendingSeekTargetMs = null
                        pendingSeekAtNanos = 0L
                    } else if (target != null && seekAgeNanos >= SEEK_SETTLE_TIMEOUT_NS) {
                        pendingSeekTargetMs = null
                        pendingSeekAtNanos = 0L
                    }
                    rawPos
                }
                val len = engine.durationMs()
                val playing = engine.isPlaying()
                _state.update { state ->
                    if (token != playToken) {
                        state
                    } else {
                        state.copy(
                            positionMs = pos,
                            durationMs = if (len > 0) len else state.durationMs,
                            playing = playing || state.loading,
                        )
                    }
                }
                if (playing && System.currentTimeMillis() - lastSessionSaveMs > 15_000) {
                    saveSession()
                }
            }
        }
    }
}
