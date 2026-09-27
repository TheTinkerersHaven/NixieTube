package nixietube.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import nixietube.innertube.AlbumDetail
import nixietube.innertube.AlbumRef
import nixietube.innertube.ArtistDetail
import nixietube.innertube.ArtistRef
import nixietube.innertube.Thumbnail
import nixietube.innertube.AuthSession
import nixietube.innertube.GDataApi
import nixietube.innertube.InnerTube
import nixietube.innertube.LyricLine
import nixietube.innertube.isSquare
import nixietube.innertube.PlaylistDetail
import nixietube.innertube.RatingStatus
import nixietube.innertube.Shelf
import nixietube.innertube.ShelfItem
import nixietube.innertube.Track
import nixietube.player.PlayerController
import nixietube.sys.GoogleOAuth
import nixietube.sys.SysConfig
import nixietube.sys.SysHandles
import java.io.File
import java.util.ArrayDeque
import java.util.Collections
import java.util.Properties

/** Re-verification cadence for the cookie session behind watchtime beacons. */
private const val LOGIN_CHECK_INTERVAL_MS = 300_000L

/** Progress-heartbeat cadence for playback reporting while playing. */
private const val REPORT_HEARTBEAT_MS = 10_000L

/** Navigation destinations for the single-window app, with [Detail] carrying a browse item. */
sealed interface Screen {
    /** Home shelves feed. */
    data object Home : Screen
    /** Search results for the last submitted query. */
    data object Search : Screen
    /** Account library (playlists, artists, liked songs). */
    data object Library : Screen
    /** Account, playback and integration settings. */
    data object Settings : Screen
    /**
     * Album/artist/playlist detail page.
     *
     * @property item the browsed shelf item identifying the page to load.
     */
    data class Detail(val item: ShelfItem.Browse) : Screen
}

/** Normalizes a name for navigation matching by lowercasing and collapsing separators. */
private fun navigationName(value: String): String =
    value.lowercase()
        .replace(Regex("[^a-z0-9]+"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

/** Returns true when two artist/album names match after normalization. */
private fun sameNavigationName(left: String, right: String): Boolean {
    if (left.equals(right, ignoreCase = true)) return true
    val normalizedLeft = navigationName(left)
    return normalizedLeft.isNotBlank() && normalizedLeft == navigationName(right)
}

/**
 * Loaded state of the current detail page.
 *
 * @property loading true while the page fetch is in flight.
 * @property album loaded album, when the page is an album.
 * @property artist loaded artist, when the page is an artist.
 * @property playlist loaded playlist, when the page is a playlist.
 * @property error failure message, or null on success.
 */
data class DetailState(
    val loading: Boolean = true,
    val album: AlbumDetail? = null,
    val artist: ArtistDetail? = null,
    val playlist: PlaylistDetail? = null,
    val error: String? = null,
)

/**
 * Central UI state holder wiring navigation, content, library, ratings and playback reporting.
 *
 * Owns the screen back-stack, exposes one [StateFlow] per UI surface, and launches all
 * InnerTube/Data API fetches on its coroutine scope.
 *
 * @param tube authenticated InnerTube client.
 * @param player playback controller observed for queue, ratings and reporting.
 * @param sys optional system handles for desktop integrations.
 * @param oauth optional Google OAuth session backing the Data API.
 * @param scope coroutine scope for background fetches.
 */
class AppState(
    val tube: InnerTube,
    val player: PlayerController,
    val sys: SysHandles? = null,
    val oauth: GoogleOAuth? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val _screen = MutableStateFlow<Screen>(Screen.Home)
    /** Currently visible navigation destination. */
    val screen: StateFlow<Screen> = _screen.asStateFlow()
    private val history = ArrayDeque<Screen>()
    private val historyLock = Any()
    private val _canGoBack = MutableStateFlow(false)
    /** True when the navigation back-stack is non-empty. */
    val canGoBack: StateFlow<Boolean> = _canGoBack.asStateFlow()

    private val _home = MutableStateFlow(HomeUiState())
    /** Home shelves content with loading/error state. */
    val home: StateFlow<HomeUiState> = _home.asStateFlow()

    private val _search = MutableStateFlow(SearchUiState())
    /** Search sections for the last submitted query. */
    val search: StateFlow<SearchUiState> = _search.asStateFlow()

    private val _detail = MutableStateFlow(DetailState())
    /** Loaded state of the current detail page. */
    val detail: StateFlow<DetailState> = _detail.asStateFlow()
    private var detailJob: Job? = null
    private var searchJob: Job? = null

    // Playback reporting state: tracks last reported video and
    // previous playing/stopped state to detect transitions.
    private var lastReportedVideoId: String? = null
    private var previousPlaying = false
    private var previousStopped = false
    private var lastProgressMs = 0L
    private var lastReportedPositionMs = 0L
    private var lastWatchCpn: String? = null
    private var lastWatchSegmentStartSec = 0.0
    private var lastWatchDurationSec = 0.0
    private var lastWatchPlaylistId: String? = null
    // Client playback nonce for watchtime beacons: 16 URL-safe chars,
    // stable for one track playback (YouTube ties a watch to its cpn).
    /** Generates a 16-char URL-safe client playback nonce for one track's watch beacons. */
    private fun newWatchCpn(): String {
        val chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        return CharArray(16) { chars.random() }.concatToString()
    }
    // Login validity cache: re-check cookie expiry every ~5 min so
    // expired LOGIN_INFO is detected without spamming browse requests.
    private var loginCheckedAt = 0L
    private var loginValid = true
    // Watchtime beacon wrapper with failure logging (successes are
    // silent; only exceptions, total failures, and expired-cookie
    // warnings are logged — see callers). Log lives at /tmp/nixietube-watchtime.log.
    /** Sends one watchtime beacon for [videoId], logging failures to the watchtime log file. */
    private suspend fun sendWatchtime(
        videoId: String,
        cpn: String,
        startSec: Double,
        currentSec: Double,
        state: String,
        durationSec: Double = 0.0,
        playlistId: String? = null,
    ) {
        // Verify the cookie session is still valid (cached for 5 min).
        // stats/* beacons return 204 (blind ack) regardless of auth,
        // so without this check we'd silently fail when LOGIN_INFO expires.
        val now = System.currentTimeMillis()
        if (now - loginCheckedAt > LOGIN_CHECK_INTERVAL_MS) {
            loginCheckedAt = now
            loginValid = try { tube.verifyLogin() } catch (_: Exception) { false }
            if (!loginValid) {
                try {
                    java.io.File("/tmp/nixietube-watchtime.log")
                        .appendText("${java.time.Instant.now()} WARNING LOGIN_INFO expired (logged_in=0) — " +
                            "stats/* beacons will not record history. Re-authenticate in Settings → Integrations.\n")
                } catch (_: Exception) { }
            }
        }

        val ok = try {
            tube.reportWatchtime(videoId, cpn, startSec, currentSec, state, durationSec, playlistId)
        } catch (e: Exception) {
            try {
                java.io.File("/tmp/nixietube-watchtime.log")
                    .appendText("${java.time.Instant.now()} EXCEPTION $state $videoId ${e.javaClass.simpleName}\n")
            } catch (_: Exception) {
            }
            return
        }
        if (!ok) {
            try {
                val cookieSession = tube.auth
                val oauthSession = try { tube.authProvider?.invoke() } catch (_: Exception) { null }
                val cookiePresent = !cookieSession.cookie.isNullOrBlank()
                val bearerPresent = !oauthSession?.accessToken.isNullOrBlank()
                val tokenPresent = !cookieSession.sessionToken.isNullOrBlank()
                val tag = when {
                    bearerPresent && !cookiePresent -> "BEARER_ONLY"
                    cookiePresent && !bearerPresent -> "COOKIE_ONLY"
                    cookiePresent && bearerPresent -> "BOTH"
                    else -> "ANONYMOUS"
                }
                val tokenTag = if (tokenPresent) "TOKEN_YES" else "TOKEN_NO"
                java.io.File("/tmp/nixietube-watchtime.log")
                    .appendText(
                        "${java.time.Instant.now()} FAILED $state $videoId cmt=$currentSec auth=$tag $tokenTag\n",
                    )
            } catch (_: Exception) {
            }
        }
    }

    private val _account = MutableStateFlow<String?>(null)
    /** Signed-in channel name, or null when logged out. */
    val account: StateFlow<String?> = _account.asStateFlow()

    // True with a cookie session (full InnerTube access: mixes,
    // personalized home, complete like-state). OAuth-only logins unlock
    // the Data API but YouTube rejects their tokens on InnerTube.
    // Read during composition: every auth change pairs with an account
    // change, which recomposes observers anyway.
    /** True when a cookie session unlocks full InnerTube access (mixes, personalization, like-state). */
    val innerTubeAuthed: Boolean
        get() = !tube.auth.cookie.isNullOrBlank() && !tube.auth.sapisidHash.isNullOrBlank()

    private val _accountAvatar = MutableStateFlow<String?>(null)
    /** Signed-in channel avatar URL, or null when unknown. */
    val accountAvatar: StateFlow<String?> = _accountAvatar.asStateFlow()

    /** Refreshes the account avatar from the Data API in the background. */
    private fun refreshAccountAvatar() {
        scope.launch {
            _accountAvatar.value = runCatching { gdata?.channelAvatar() }.getOrNull()
        }
    }

    // Author avatar URLs by artist/channel browse id (null = looked up and
    // missing), backing the profile pictures in collection headers.
    private val authorAvatarCache: MutableMap<String, String?> =
        Collections.synchronizedMap(mutableMapOf())

    // Whether a browse id opens a real artist page. Playlist owners are
    // often plain user channels, which must not be clickable.
    private val artistPageCache: MutableMap<String, Boolean> =
        Collections.synchronizedMap(mutableMapOf())

    // Signed-in channel id (null = unknown or logged out), so author rows
    // never link to yourself.
    private var ownChannelId: String? = null
    private var ownChannelIdLoaded = false

    /**
     * Returns true when [browseId] opens a real artist page.
     *
     * Results are cached per session; transient failures read as false
     * until the view is revisited.
     *
     * @param browseId artist/channel browse id (UC…).
     */
    suspend fun isArtistPage(browseId: String): Boolean {
        if (browseId.isBlank() || !browseId.startsWith("UC")) return false
        synchronized(artistPageCache) {
            artistPageCache[browseId]?.let { return it }
        }
        val ok = runCatching { tube.artist(browseId) }.getOrNull() != null
        synchronized(artistPageCache) { artistPageCache[browseId] = ok }
        return ok
    }

    /**
     * Whether an author row may link out: never yourself, otherwise only
     * verified artist pages (plain user channels stay inert text).
     *
     * @param browseId author channel browse id (UC…).
     */
    suspend fun isAuthorClickable(browseId: String): Boolean {
        if (browseId.isBlank() || !browseId.startsWith("UC")) return false
        if (!ownChannelIdLoaded) {
            ownChannelIdLoaded = true
            ownChannelId = runCatching { gdata?.ownChannelId() }.getOrNull()
        }
        if (!ownChannelId.isNullOrBlank() && browseId == ownChannelId) return false
        return isArtistPage(browseId)
    }

    /**
     * Resolves a profile avatar for an artist/channel id, caching misses too.
     *
     * Prefers the Data API channel thumbnail (true square avatar) and falls
     * back to InnerTube artist imagery (square preferred, largest otherwise).
     *
     * @param browseId artist/channel browse id (UC…).
     * @return avatar URL, or null when none resolves.
     */
    suspend fun resolveAuthorAvatar(browseId: String): String? {
        if (browseId.isBlank()) return null
        synchronized(authorAvatarCache) {
            if (authorAvatarCache.containsKey(browseId)) return authorAvatarCache[browseId]
        }
        val api = gdata
        var avatar = if (api != null) {
            runCatching { api.channelAvatars(listOf(browseId))[browseId] }.getOrNull()
        } else {
            null
        }
        if (avatar.isNullOrBlank()) {
            val thumbs = runCatching { tube.artist(browseId) }.getOrNull()?.thumbnails.orEmpty()
            avatar = thumbs.filter { it.isSquare() }.maxByOrNull { it.width }?.url
                ?: thumbs.maxByOrNull { it.width }?.url
        }
        synchronized(authorAvatarCache) { authorAvatarCache[browseId] = avatar }
        return avatar
    }

    private val _lyrics = MutableStateFlow<List<LyricLine>>(emptyList())
    /** Lyric lines for the currently playing track, empty when none were found. */
    val lyrics: StateFlow<List<LyricLine>> = _lyrics.asStateFlow()

    /** Data API client backed by the OAuth session, or null when logged out. */
    val gdata: GDataApi? = oauth?.let { o -> GDataApi { o.accessToken() } }

    private val _playlists = MutableStateFlow<List<GDataApi.GPlaylist>>(emptyList())
    /** Account playlists, headed by the synthetic "Liked songs" entry. */
    val playlists: StateFlow<List<GDataApi.GPlaylist>> = _playlists.asStateFlow()

    private val _liked = MutableStateFlow<List<Track>>(emptyList())
    /** Liked songs, previewed first then completed in the background. */
    val liked: StateFlow<List<Track>> = _liked.asStateFlow()

    private val _artists = MutableStateFlow<List<ShelfItem.Browse>>(emptyList())
    /** Followed artists from channel subscriptions. */
    val artists: StateFlow<List<ShelfItem.Browse>> = _artists.asStateFlow()

    private val _openPlaylist = MutableStateFlow<Pair<GDataApi.GPlaylist, List<Track>>?>(null)
    /** Currently opened playlist with its tracks, or null when browsing the library root. */
    val openPlaylist: StateFlow<Pair<GDataApi.GPlaylist, List<Track>>?> = _openPlaylist.asStateFlow()

    private val _libraryLoading = MutableStateFlow(false)
    /** True while library or playlist content is being fetched. */
    val libraryLoading: StateFlow<Boolean> = _libraryLoading.asStateFlow()

    private val _activity = MutableStateFlow<List<Track>>(emptyList())
    /** Recent listening activity backing the personal home rows. */
    val activity: StateFlow<List<Track>> = _activity.asStateFlow()

    private val _discover = MutableStateFlow<List<Track>>(emptyList())
    /** Suggested songs mixed from recent and liked seeds, excluding already-known tracks. */
    val discover: StateFlow<List<Track>> = _discover.asStateFlow()
    private var discoverJob: Job? = null

    // Suggested songs from your history: mix stations seeded from recent
    // + liked tracks (Data API, requires OAuth), or from the InnerTube
    // home page ("Listen again" shelf, available with a cookie).
    // Anything already known is excluded so the mix stays fresh.
    /**
     * Loads fresh song suggestions from recent/liked seeds via mix stations.
     *
     * Falls back to InnerTube home shelves when the Data API history is unavailable.
     */
    fun loadDiscover() {
        discoverJob?.cancel()
        discoverJob = scope.launch {
            // Seeds from Data API (OAuth) or from InnerTube home (cookie).
            val seeds = runCatching {
                (_activity.value.distinctBy { it.videoId }.take(3) +
                    _liked.value.shuffled().take(2)).distinctBy { it.videoId }.take(5)
            }.getOrNull()?.takeIf { it.isNotEmpty() } ?: runCatching {
                // Fallback: first songs from home shelves (cookie).
                val homeSeeds = mutableListOf<Track>()
                tube.home().forEach { shelf ->
                    if (homeSeeds.size >= 5) return@runCatching homeSeeds
                    homeSeeds += shelf.items.filterIsInstance<ShelfItem.Song>()
                        .map { it.track }.take(5 - homeSeeds.size)
                }
                homeSeeds.ifEmpty { return@runCatching emptyList() }
                    .distinctBy { it.videoId }.take(5)
            }.getOrNull()?.ifEmpty { return@launch } ?: return@launch
            val known = (seeds.map { it.videoId } +
                _activity.value.map { it.videoId } +
                _liked.value.map { it.videoId }).toSet()
            val mixed = coroutineScope {
                seeds.map { seed ->
                    async {
                        runCatching {
                            val radioId = seed.radioPlaylistId?.takeIf { it.isNotBlank() }
                                ?: ("RDAMVM" + seed.videoId)
                            tube.upNext(seed.videoId, radioId)
                        }.getOrDefault(emptyList())
                    }
                }.awaitAll()
            }.flatten()
                .filter { it.videoId !in known }
                .distinctBy { it.videoId }
                .take(20)
            if (!isActive || mixed.isEmpty()) return@launch
            _discover.value = mixed
        }
    }

    private val _recentArtists = MutableStateFlow<List<ShelfItem.Browse>>(emptyList())
    /** Artists derived from recent activity, one entry per channel id. */
    val recentArtists: StateFlow<List<ShelfItem.Browse>> = _recentArtists.asStateFlow()

    /** Rebuilds the recent-artists list from activity credits, then resolves real avatars. */
    private fun refreshRecentArtists() {
        val seen = linkedMapOf<String, ShelfItem.Browse>()
        for (t in _activity.value) {
            for (artist in t.artists) {
                artistEntry(artist, t.thumbnails)?.let { (id, entry) -> seen.putIfAbsent(id, entry) }
            }
        }
        _recentArtists.value = seen.values.take(20)
        enrichRecentArtistArtwork()
    }

    /** Channel-linked artist credit as a library entry, or null when unlinked/nameless. */
    private fun artistEntry(artist: ArtistRef, thumbnails: List<Thumbnail>): Pair<String, ShelfItem.Browse>? {
        val id = artist.browseId?.takeIf { it.startsWith("UC") } ?: return null
        val name = artist.name.trim().takeIf { it.isNotBlank() } ?: return null
        return id to ShelfItem.Browse(name, "Artist", id, thumbnails)
    }

    private val artistAvatarCache = mutableMapOf<String, List<Thumbnail>>()
    private var artistAvatarJob: Job? = null

    // Swaps the placeholder track art on recent artists for their real
    // channel avatars. InnerTube artist pages only expose the wide header
    // banner, so avatars come from one batched Data API channels call per
    // 50 ids. Results (including misses) are cached per session.
    /** Replaces placeholder track art on recent artists with batched Data API channel avatars. */
    private fun enrichRecentArtistArtwork() {
        val api = gdata
        artistAvatarJob?.cancel()
        artistAvatarJob = scope.launch {
            val ids = _recentArtists.value.mapNotNull { it.browseId }.distinct()
                .filter { id ->
                    synchronized(artistAvatarCache) { !artistAvatarCache.containsKey(id) }
                }
            if (ids.isEmpty() || api == null) return@launch
            ids.chunked(50).forEach { chunk ->
                val fetched = runCatching { api.channelAvatars(chunk) }.getOrDefault(emptyMap())
                synchronized(artistAvatarCache) {
                    chunk.forEach { id ->
                        artistAvatarCache[id] = fetched[id]?.let { listOf(Thumbnail(it)) }.orEmpty()
                    }
                }
                if (!isActive) return@launch
                _recentArtists.update { list ->
                    list.map { artist ->
                        val cached = artist.browseId.let { id ->
                            synchronized(artistAvatarCache) { artistAvatarCache[id] }
                        }
                        val avatar = cached.takeIf { !it.isNullOrEmpty() }
                        if (avatar != null) artist.copy(thumbnails = avatar) else artist
                    }
                }
            }
        }
    }

    private var lastLyricKey: String? = null
    private var lastRatingVideoId: String? = null
    private var lastRatingQueueKey: String? = null
    private var lastEnrichQueueKey: String? = null
    // Video IDs the account liked (Data API). Marks like-state where
    // InnerTube personalization is unavailable and primes the rating cache.
    @Volatile
    private var likedIds: Set<String> = emptySet()
    private val ratingCache = mutableMapOf<String, RatingStatus>()
    private val ratingRequests = mutableSetOf<String>()
    private val ratingWaiters = mutableMapOf<String, MutableList<(Map<String, RatingStatus>) -> Unit>>()
    private var detailRatingToken = 0L

    /** True when like-state can be fetched (signed in via OAuth or cookie session). */
    private fun ratingsAvailable(): Boolean =
        account.value != null || tube.auth != AuthSession.Anonymous

    /**
     * Resolves like-state for [tracks], serving the cache first and batching one fetch for the rest.
     *
     * @param tracks tracks needing ratings.
     * @param force refetch even when the track already carries a non-unknown rating.
     * @param onComplete invoked with immediately-known states and again with fetched states.
     */
    private fun requestTrackRatings(
        tracks: List<Track>,
        force: Boolean = false,
        onComplete: ((Map<String, RatingStatus>) -> Unit)? = null,
    ) {
        if (tracks.isEmpty()) return
        val immediate = linkedMapOf<String, RatingStatus>()
        val pending = mutableListOf<String>()
        val canFetch = ratingsAvailable()
        synchronized(ratingCache) {
            tracks.forEach { track ->
                val id = track.videoId
                val cached = ratingCache[id]
                if (cached != null) {
                    immediate[id] = cached
                } else if (track.rating != RatingStatus.UNKNOWN && (!canFetch || !force)) {
                    immediate[id] = track.rating
                } else if (canFetch && id.isNotBlank() && ratingRequests.add(id)) {
                    pending += id
                }
                val awaitingFetch = canFetch && id.isNotBlank() && ratingRequests.contains(id)
                if (awaitingFetch && onComplete != null) {
                    ratingWaiters.getOrPut(id) { mutableListOf() } += onComplete
                }
            }
        }
        if (immediate.isNotEmpty()) onComplete?.invoke(immediate)
        if (!canFetch || pending.isEmpty()) return
        scope.launch {
            val fetched = runCatching { tube.ratings(pending) }.getOrDefault(emptyMap())
            val callbacks = synchronized(ratingCache) {
                val result = mutableListOf<(Map<String, RatingStatus>) -> Unit>()
                pending.forEach { id ->
                    ratingRequests.remove(id)
                    ratingWaiters.remove(id)?.let { result.addAll(it) }
                }
                ratingCache.putAll(fetched)
                result.distinct()
            }
            if (fetched.isNotEmpty()) callbacks.forEach { it(fetched) }
        }
    }

    /** Pushes [track]'s known rating to the player and force-refreshes it from the network. */
    private fun requestTrackRating(track: Track) {
        if (track.videoId == lastRatingVideoId) return
        lastRatingVideoId = track.videoId
        val known = if (_liked.value.any { it.videoId == track.videoId }) {
            RatingStatus.LIKE
        } else {
            track.rating
        }
        if (known != RatingStatus.UNKNOWN) {
            player.updateTrackRating(track.videoId, known)
        }
        requestTrackRatings(
            tracks = listOf(track),
            onComplete = { statuses ->
                statuses.forEach { (videoId, status) -> player.updateTrackRating(videoId, status) }
            },
            force = true,
        )
    }

    /** Clears cached ratings and re-resolves like-state for the player, detail and open playlist. */
    private fun refreshCurrentRating() {
        lastRatingVideoId = null
        synchronized(ratingCache) {
            ratingCache.clear()
            ratingRequests.clear()
            ratingWaiters.clear()
        }
        player.state.value.current?.let(::requestTrackRating)
        requestTrackRatings(
            tracks = player.state.value.queue,
            onComplete = { statuses ->
                statuses.forEach { (videoId, status) -> player.updateTrackRating(videoId, status) }
            },
            force = true,
        )
        val detailTracks = _detail.value.album?.tracks ?: _detail.value.playlist?.tracks.orEmpty()
        if (detailTracks.isNotEmpty()) {
            requestTrackRatings(
                tracks = detailTracks,
                onComplete = { statuses ->
                    val detail = _detail.value
                    fun List<Track>.applyRatings(): List<Track> = map { track ->
                        statuses[track.videoId]?.let { track.copy(rating = it) } ?: track
                    }
                    _detail.value = when {
                        detail.album != null -> detail.copy(
                            album = detail.album.copy(tracks = detail.album.tracks.applyRatings()),
                        )
                        detail.playlist != null -> detail.copy(
                            playlist = detail.playlist.copy(tracks = detail.playlist.tracks.applyRatings()),
                        )
                        else -> detail
                    }
                },
                force = true,
            )
        }
        val opened = _openPlaylist.value
        if (opened != null) {
            requestTrackRatings(
                tracks = opened.second,
                onComplete = { statuses ->
                    val current = _openPlaylist.value
                    if (current != null && current.first.id == opened.first.id) {
                        _openPlaylist.value = current.first to current.second.map { track ->
                            statuses[track.videoId]?.let { track.copy(rating = it) } ?: track
                        }
                    }
                },
                force = true,
            )
        }
    }

    /** Stamps liked ids onto search song rows so liked tracks render as liked. */
    private fun stampSearchSections(
        sections: Map<String, List<ShelfItem>>,
    ): Map<String, List<ShelfItem>> =
        sections.mapValues { (_, items) ->
            items.map { item ->
                if (item is ShelfItem.Song) {
                    ShelfItem.Song(stampLikedIds(listOf(item.track)).first())
                } else {
                    item
                }
            }
        }

    // Marks UNKNOWN-rated tracks the account liked. Never overrides an
    // explicit state (e.g. DISLIKE resolved elsewhere).
    /** Marks unknown-rated liked tracks as liked without overriding explicit states. */
    private fun stampLikedIds(tracks: List<Track>): List<Track> {
        val ids = likedIds
        if (ids.isEmpty()) return tracks
        var changed = false
        val out = tracks.map { track ->
            if (track.rating == RatingStatus.UNKNOWN && track.videoId in ids) {
                changed = true
                track.copy(rating = RatingStatus.LIKE)
            } else {
                track
            }
        }
        return if (changed) out else tracks
    }

    /**
     * Refreshes the liked video id set from the Data API and re-stamps all visible surfaces.
     *
     * Primes the rating cache so InnerTube fetches are skipped where personalization is unavailable.
     */
    fun refreshLikedIds() {
        val api = gdata ?: return
        scope.launch {
            val ids = runCatching { api.likedVideoIds() }.getOrDefault(emptySet())
            if (ids.isEmpty()) return@launch
            val old = likedIds
            likedIds = ids
            synchronized(ratingCache) {
                ids.forEach { id ->
                    if (ratingCache[id] == null) ratingCache[id] = RatingStatus.LIKE
                }
                old.forEach { id ->
                    if (id !in ids && ratingCache[id] == RatingStatus.LIKE) ratingCache.remove(id)
                }
            }
            // Re-stamp visible surfaces with the fresh set.
            _search.update { state -> state.copy(sections = stampSearchSections(state.sections)) }
            _detail.update { current ->
                when {
                    current.album != null -> current.copy(
                        album = current.album.copy(tracks = stampLikedIds(current.album.tracks)),
                    )
                    current.playlist != null -> current.copy(
                        playlist = current.playlist.copy(tracks = stampLikedIds(current.playlist.tracks)),
                    )
                    current.artist != null -> current.copy(
                        artist = current.artist.copy(topSongs = stampLikedIds(current.artist.topSongs)),
                    )
                    else -> current
                }
            }
            _openPlaylist.update { opened ->
                opened?.let { (pl, tracks) -> pl to stampLikedIds(tracks) }
            }
            val s = player.state.value
            (s.queue + listOfNotNull(s.current)).distinctBy { it.videoId }
                .filter { it.rating == RatingStatus.UNKNOWN && it.videoId in ids }
                .forEach { player.updateTrackRating(it.videoId, RatingStatus.LIKE) }
        }
    }

    init {
        // Keep InnerTube authenticated with the same renewable OAuth session
        // used by the Data API. This is also required for personalized
        // like/dislike state and private playlist artwork.
        oauth?.let { tube.authProvider = { it.validSession() } }
        loadAuth()
        loadHome()
        oauth?.let { o ->
            scope.launch {
                // Silent re-login: OAuth tokens work via the Data API.
                val name = try {
                    gdata?.channelName()
                } catch (_: Exception) {
                    null
                }
                if (name != null) {
                    _account.value = name
                    refreshAccountAvatar()
                    refreshCurrentRating()
                    loadLibrary()
                    refreshLikedIds()
                }
            }
        }
        scope.launch {
            player.state.collect { s ->
                val track = s.current
                val key = track?.videoId
                if (track != null) requestTrackRating(track) else lastRatingVideoId = null
                val queueKey = s.queue.joinToString("\u0000") { it.videoId }
                // Tracks missing metadata resolve it (plus like-state) via
                // the enrich pass below, so the ratings pass skips them:
                // one watch-next call per track instead of two.
                fun sparseIdsOf(queue: List<Track>): Set<String> =
                    queue.filter { track ->
                        track.artists.isEmpty() || track.album == null || track.thumbnails.isEmpty()
                    }.distinctBy { it.videoId }.map { it.videoId }.toSet()
                if (queueKey != lastRatingQueueKey) {
                    lastRatingQueueKey = queueKey
                    val sparseIds = sparseIdsOf(s.queue)
                    requestTrackRatings(s.queue.filter { it.videoId !in sparseIds }) { statuses ->
                        statuses.forEach { (videoId, status) -> player.updateTrackRating(videoId, status) }
                    }
                }
                // Fill in artists/album/artwork for queued tracks that lack
                // them, so the queue is correct before anything is played.
                // (Their like-state arrives from the same enrich pass.)
                if (queueKey != lastEnrichQueueKey) {
                    lastEnrichQueueKey = queueKey
                    val targets = s.queue.filter { it.videoId in sparseIdsOf(s.queue) }
                        .distinctBy { it.videoId }
                    if (targets.isNotEmpty()) {
                        scope.launch {
                            val enriched = runCatching { tube.enrichTracks(targets) }.getOrDefault(targets)
                            enriched.forEach { resolved ->
                                val original = targets.firstOrNull { it.videoId == resolved.videoId }
                                    ?: return@forEach
                                val metadataChanged = resolved.artists != original.artists ||
                                    resolved.album != original.album ||
                                    resolved.thumbnails != original.thumbnails ||
                                    resolved.title != original.title
                                if (metadataChanged) {
                                    player.updateTrackMetadata(
                                        resolved.videoId,
                                        artists = resolved.artists,
                                        album = resolved.album,
                                        thumbnails = resolved.thumbnails,
                                        title = resolved.title,
                                    )
                                }
                                if (resolved.rating != RatingStatus.UNKNOWN && resolved.rating != original.rating) {
                                    player.updateTrackRating(resolved.videoId, resolved.rating)
                                    synchronized(ratingCache) {
                                        ratingCache[resolved.videoId] = resolved.rating
                                    }
                                }
                            }
                        }
                    }
                }
                if (key != null && key != lastLyricKey) {
                    lastLyricKey = key
                    _lyrics.value = emptyList()
                    val activeTrack = track
                    scope.launch {
                        // Data API tracks often have a distributor channel and
                        // no release metadata. Resolve the canonical
                        // artist/album/kind in the background while lyrics
                        // load independently.
                        scope.launch {
                            runCatching { tube.enrichTrack(activeTrack) }
                                .getOrNull()
                                ?.let {
                                    player.updateTrackMetadata(
                                        videoId = key,
                                        artists = it.artists,
                                        album = it.album,
                                        thumbnails = it.thumbnails,
                                        title = it.title,
                                    )
                                }
                        }
                        val (lines, album) = fetchLyricsAndAlbum(
                            activeTrack.artistNames, activeTrack.title,
                            activeTrack.album?.name.orEmpty(), activeTrack.durationSec,
                        )
                        _lyrics.value = lines
                        if (!album.isNullOrBlank()) {
                            player.updateTrackAlbum(key, album)
                        }
                    }
                }
                // Playback reporting to YouTube's stats/watchtime beacons
                // (opt-in via SysConfig.reportPlayback) — the pipeline
                // official clients use to record listening history.
                if (SysConfig.reportPlayback) {
                    val prevVid = lastReportedVideoId
                    val prevPlay = previousPlaying
                    val prevStop = previousStopped
                    val progMs = lastProgressMs
                    val prevPosMs = lastReportedPositionMs
                    val prevCpn = lastWatchCpn
                    val prevSegStartSec = lastWatchSegmentStartSec
                    val prevDurSec = lastWatchDurationSec
                    val prevPlaylistId = lastWatchPlaylistId
                    scope.launch {
                        val st = s
                        val vid = st.current?.videoId
                        val posSec = st.positionMs / 1000.0
                        val durSec = st.durationMs / 1000.0
                        val playlistId = st.current?.playlistId
                        if (vid != null && vid != prevVid) {
                            if (prevVid != null && prevCpn != null && !st.stopped) {
                                // Report where the previous track actually
                                // stopped, not the new track's ~0 position.
                                sendWatchtime(
                                    prevVid, prevCpn, prevSegStartSec,
                                    prevPosMs / 1000.0, "paused", prevDurSec,
                                    prevPlaylistId,
                                )
                            }
                            val cpn = newWatchCpn()
                            lastReportedVideoId = vid
                            lastWatchCpn = cpn
                            lastWatchSegmentStartSec = 0.0
                            lastWatchDurationSec = durSec
                            lastWatchPlaylistId = playlistId
                            lastReportedPositionMs = st.positionMs
                            sendWatchtime(vid, cpn, 0.0, posSec, "playing", durSec, playlistId)
                        } else if (vid != null && prevVid == vid && prevCpn != null) {
                            if (st.playing && !prevPlay) {
                                lastWatchSegmentStartSec = prevPosMs / 1000.0
                                lastReportedPositionMs = st.positionMs
                                sendWatchtime(vid, prevCpn, prevSegStartSec, posSec, "playing", durSec, playlistId)
                            } else if (!st.playing && prevPlay && !st.stopped) {
                                lastReportedPositionMs = st.positionMs
                                sendWatchtime(vid, prevCpn, prevSegStartSec, posSec, "paused", durSec, playlistId)
                                lastWatchSegmentStartSec = posSec
                            } else if (st.stopped && !prevStop) {
                                lastReportedPositionMs = st.positionMs
                                sendWatchtime(vid, prevCpn, prevSegStartSec, posSec, "paused", durSec, playlistId)
                                lastWatchSegmentStartSec = posSec
                            } else if (st.playing) {
                                val now = System.currentTimeMillis()
                                if (now - progMs >= REPORT_HEARTBEAT_MS) {
                                    lastProgressMs = now
                                    lastReportedPositionMs = st.positionMs
                                    sendWatchtime(vid, prevCpn, prevSegStartSec, posSec, "playing", durSec, playlistId)
                                    lastWatchSegmentStartSec = posSec
                                } else {
                                    lastReportedPositionMs = st.positionMs
                                }
                            } else {
                                lastReportedPositionMs = st.positionMs
                            }
                        }
                        previousPlaying = st.playing
                        previousStopped = st.stopped
                    }
                }
            }
        }
    }

    /**
     * Navigates to [screen], pushing the current screen onto the back-stack.
     *
     * Detail screens trigger a detail load; leaving one cancels it.
     *
     * @param screen destination to show.
     */
    fun go(screen: Screen) {
        val current = _screen.value
        if (current != screen) {
            synchronized(historyLock) { history.addLast(current) }
        }
        _screen.value = screen
        if (screen is Screen.Detail) {
            loadDetail(screen.item)
        } else {
            detailJob?.cancel()
            detailRatingToken++
        }
        updateHistoryState()
    }

    /** Pops the navigation back-stack, reloading the detail page when returning to one. */
    fun goBack() {
        val previous = synchronized(historyLock) {
            if (history.isEmpty()) null else history.removeLast()
        } ?: return
        _screen.value = previous
        if (previous is Screen.Detail) {
            loadDetail(previous.item)
        } else {
            detailJob?.cancel()
            detailRatingToken++
        }
        updateHistoryState()
    }

    /** Publishes whether the navigation back-stack is non-empty. */
    private fun updateHistoryState() {
        _canGoBack.value = synchronized(historyLock) { history.isNotEmpty() }
    }

    /**
     * Opens an artist detail page, resolving the channel id via enrichment or search when missing.
     *
     * @param artist the artist reference to open.
     * @param track optional originating track used to verify and resolve the channel id.
     */
    fun openArtist(artist: ArtistRef, track: Track? = null) {
        val immediateTrackId = track?.let { currentTrack ->
            currentTrack.artistId?.takeIf {
                currentTrack.artists.firstOrNull()?.let { first ->
                    sameNavigationName(first.name, artist.name)
                } == true
            }
        }
        val browseId = artist.browseId ?: immediateTrackId
        if (!browseId.isNullOrBlank()) {
            go(
                Screen.Detail(
                    ShelfItem.Browse(
                        title = artist.name,
                        subtitle = "Artist",
                        browseId = browseId,
                        thumbnails = emptyList(),
                    ),
                ),
            )
            return
        }

        // Data API tracks often have no UC id. Enrich the exact track first;
        // this avoids opening an arbitrary artist from a broad search result.
        scope.launch {
            val enriched = track?.let { runCatching { tube.enrichTrack(it) }.getOrNull() }
            val enrichedMatch = enriched?.artists?.firstOrNull {
                sameNavigationName(it.name, artist.name)
            }
            var resolvedId = enrichedMatch?.browseId
            val fallbackId = track?.artistId
            if (resolvedId.isNullOrBlank() &&
                fallbackId != null &&
                track.artists.firstOrNull()?.let { sameNavigationName(it.name, artist.name) } == true
            ) {
                val verified = runCatching { tube.artist(fallbackId) }.getOrNull()
                if (verified != null && sameNavigationName(verified.name, artist.name)) {
                    resolvedId = fallbackId
                }
            }
            if (!resolvedId.isNullOrBlank()) {
                go(
                    Screen.Detail(
                        ShelfItem.Browse(
                            title = enrichedMatch?.name ?: artist.name,
                            subtitle = "Artist",
                            browseId = resolvedId,
                            thumbnails = emptyList(),
                        ),
                    ),
                )
                return@launch
            }

            val match = runCatching { tube.search(artist.name) }.getOrDefault(emptyMap())
                .values
                .flatten()
                .filterIsInstance<ShelfItem.Browse>()
                .firstOrNull {
                    it.browseId.startsWith("UC") && sameNavigationName(it.title, artist.name)
                }
            if (match != null) {
                go(Screen.Detail(match))
            } else {
                search(artist.name)
                go(Screen.Search)
            }
        }
    }

    /**
     * Opens an album detail page, resolving the album id via enrichment or search when missing.
     *
     * @param track the track carrying the album reference.
     * @param album the album reference to open.
     */
    fun openAlbum(track: Track, album: AlbumRef) {
        val browseId = album.browseId
        if (!browseId.isNullOrBlank()) {
            go(
                Screen.Detail(
                    ShelfItem.Browse(
                        title = album.name,
                        subtitle = "Album",
                        browseId = browseId,
                        thumbnails = emptyList(),
                    ),
                ),
            )
            return
        }

        val query = listOf(track.artistNames, album.name)
            .filter { it.isNotBlank() }
            .joinToString(" ")
        scope.launch {
            val enriched = runCatching { tube.enrichTrack(track) }.getOrNull()
            val resolvedAlbum = enriched?.album
            val resolvedBrowseId = resolvedAlbum?.browseId
            if (!resolvedBrowseId.isNullOrBlank()) {
                go(
                    Screen.Detail(
                        ShelfItem.Browse(
                            title = resolvedAlbum.name.ifBlank { album.name },
                            subtitle = "Album",
                            browseId = resolvedBrowseId,
                            thumbnails = emptyList(),
                        ),
                    ),
                )
                return@launch
            }

            val match = runCatching { tube.search(query) }.getOrDefault(emptyMap())
                .values
                .flatten()
                .filterIsInstance<ShelfItem.Browse>()
                .firstOrNull {
                    it.browseId.startsWith("MPRE") && sameNavigationName(it.title, album.name)
                }
            if (match != null) {
                go(Screen.Detail(match))
            } else {
                search(album.name)
                go(Screen.Search)
            }
        }
    }

    /** Reloads the home shelves feed from InnerTube. */
    fun loadHome() {
        scope.launch {
            _home.update { it.copy(loading = true, error = null) }
            try {
                _home.update { it.copy(loading = false, shelves = tube.home()) }
            } catch (e: Exception) {
                _home.update { it.copy(loading = false, error = e.message ?: "Home failed") }
            }
        }
    }

    private val searchHistoryFile: File
        get() = File(configDir(), "search-history.txt")

    private val _searchHistory = MutableStateFlow(loadSearchHistory())
    /** Recent search queries persisted under the config dir, most recent first. */
    val searchHistory: StateFlow<List<String>> = _searchHistory.asStateFlow()

    /** Loads persisted search history, newest distinct queries first. */
    private fun loadSearchHistory(): List<String> = try {
        searchHistoryFile.takeIf { it.exists() }
            ?.readLines()?.map { it.trim() }
            ?.filter { it.isNotBlank() }?.distinct()?.take(12)
            .orEmpty()
    } catch (_: Exception) {
        emptyList()
    }

    /** Records [query] at the head of the persisted search history. */
    private fun recordSearchHistory(query: String) {
        val updated = (listOf(query) + _searchHistory.value.filterNot { it.equals(query, ignoreCase = true) })
            .take(12)
        _searchHistory.value = updated
        try {
            searchHistoryFile.writeText(updated.joinToString("\n"))
        } catch (_: Exception) {
        }
    }

    /** Clears the in-memory and persisted search history. */
    fun clearSearchHistory() {
        _searchHistory.value = emptyList()
        try {
            if (searchHistoryFile.exists()) searchHistoryFile.delete()
        } catch (_: Exception) {
        }
    }

    /**
     * Runs a search and enriches song rows with canonical metadata and ratings.
     *
     * A newer query cancels the in-flight one, including its enrichment pass.
     *
     * @param query raw search text.
     */
    fun search(query: String) {
        val normalized = query.trim()
        if (normalized.isEmpty()) return
        recordSearchHistory(normalized)
        searchJob?.cancel()
        searchJob = scope.launch {
            _search.update { it.copy(loading = true, error = null, query = normalized) }
            try {
                val sections = tube.search(normalized)
                _search.update { it.copy(loading = false, sections = stampSearchSections(sections)) }
                // Resolve canonical artists/album/artwork/like-state for the
                // song rows up front, so opening a result doesn't change
                // what the list showed. Runs inside the search job, so a
                // newer query cancels it.
                val songs = sections["Songs"]
                    ?.filterIsInstance<ShelfItem.Song>()
                    ?.map { it.track }
                    .orEmpty()
                if (songs.isNotEmpty()) {
                    val enriched = tube.enrichTracks(songs)
                    if (!isActive || _search.value.query != normalized) return@launch
                    val byId = enriched.associateBy { it.videoId }
                    _search.update { state ->
                        state.copy(sections = stampSearchSections(state.sections.mapValues { (_, items) ->
                            items.map { item ->
                                if (item is ShelfItem.Song) {
                                    byId[item.track.videoId]?.let { ShelfItem.Song(it) } ?: item
                                } else {
                                    item
                                }
                            }
                        }))
                    }
                    // Prime the rating cache with freshly fetched states so
                    // queue/detail flows reuse them instead of refetching.
                    synchronized(ratingCache) {
                        enriched.forEach { track ->
                            if (track.rating != RatingStatus.UNKNOWN) {
                                ratingCache[track.videoId] = track.rating
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                if (isActive) {
                    _search.update { it.copy(loading = false, error = e.message ?: "Search failed") }
                }
            }
        }
    }

    /**
     * Runs [search] for [query] and navigates to the Search screen.
     *
     * @param query raw search text.
     */
    fun searchAndGo(query: String) {
        search(query)
        go(Screen.Search)
    }

    /** YTM-style mood shortcuts, each running a plain search. */
    val moods = listOf(
        "Relax", "Energia pura", "Festa", "Romantico", "Concentrazione",
        "Allenamento", "Viaggio", "Dormire", "Rock", "Jazz",
    )

    /**
     * Plays [songs] starting at [index].
     *
     * @param songs queue to play.
     * @param index position to start from.
     */
    fun playSongs(songs: List<Track>, index: Int) = player.playTracks(songs, index)

    /**
     * Plays [songs] in shuffled order.
     *
     * @param songs queue to shuffle and play.
     */
    fun playShuffled(songs: List<Track>) {
        if (songs.isEmpty()) return
        player.playTracks(songs.shuffled(), 0)
    }

    /**
     * Plays an artist's full top-songs playlist from the tapped song onward.
     *
     * Falls back to the preview rows when the full playlist is unavailable.
     *
     * @param artist artist whose top songs to play.
     * @param index tapped position within the preview rows.
     */
    fun playArtistTopSong(artist: ArtistDetail, index: Int) {
        val preview = artist.topSongs
        val tapped = preview.getOrNull(index) ?: return
        scope.launch {
            val full = runCatching {
                val pid = artist.songsPlaylistId
                if (pid != null) {
                    tube.playlist(pid, artist.songsPlaylistParams)?.tracks?.takeIf { it.isNotEmpty() }
                } else {
                    null
                }
            }.getOrNull()
            if (full != null) {
                playSongs(full, full.indexOfFirst { it.videoId == tapped.videoId }.coerceAtLeast(0))
            } else {
                playSongs(preview, index)
            }
        }
    }

    /**
     * Plays an artist's full top-songs playlist, optionally shuffled.
     *
     * Falls back to the preview rows when the full playlist is unavailable.
     *
     * @param artist artist whose top songs to play.
     * @param shuffled true to shuffle the resolved tracks.
     */
    fun playArtistSongs(artist: ArtistDetail, shuffled: Boolean) {
        scope.launch {
            val tracks = runCatching {
                val pid = artist.songsPlaylistId
                if (pid != null) {
                    tube.playlist(pid, artist.songsPlaylistParams)?.tracks?.takeIf { it.isNotEmpty() }
                } else {
                    null
                }
            }.getOrNull() ?: artist.topSongs
            if (tracks.isEmpty()) return@launch
            if (shuffled) playShuffled(tracks) else playSongs(tracks, 0)
        }
    }

    /**
     * Starts a song radio station from [track] plus its watch-next mix.
     *
     * @param track seed track for the station.
     */
    fun startRadio(track: Track) {
        scope.launch {
            val radioId = track.radioPlaylistId?.takeIf { it.isNotBlank() }
                ?: ("RDAMVM" + track.videoId)
            val upcoming = runCatching { tube.upNext(track.videoId, radioId) }
                .getOrDefault(emptyList())
                .filter { it.videoId != track.videoId }
                .distinctBy { it.videoId }
            player.playTracks(listOf(track) + upcoming, 0)
        }
    }

    /**
     * Starts an artist radio station seeded from the artist's top song.
     *
     * @param artist artist to seed the station from.
     */
    fun startArtistRadio(artist: ArtistDetail) {
        val seed = artist.topSongs.firstOrNull() ?: return
        startRadio(seed)
    }

    /** Loads the album/artist/playlist page for [item], enriching sparse rows and ratings. */
    private fun loadDetail(item: ShelfItem.Browse) {
        detailJob?.cancel()
        val ratingToken = ++detailRatingToken
        detailJob = scope.launch {
            _detail.value = DetailState()
            try {
                val loaded = when {
                    item.browseId.startsWith("UC") ->
                        tube.artist(item.browseId)?.let {
                            DetailState(loading = false, artist = it.copy(topSongs = stampLikedIds(it.topSongs)))
                        }
                    item.browseId.startsWith("MPRE") ->
                        tube.album(item.browseId)?.let { DetailState(loading = false, album = it) }
                    else ->
                        tube.playlist(item.browseId, item.browseParams)
                            ?.let { loaded ->
                                val withArtwork = loaded.copy(
                                    title = loaded.title.ifBlank { item.title },
                                    subtitle = loaded.subtitle.ifBlank { item.subtitle },
                                    thumbnails = loaded.thumbnails.ifEmpty { item.thumbnails },
                                )
                                DetailState(loading = false, playlist = withArtwork)
                            }
                }
                if (!isActive) return@launch
                if (loaded == null) {
                    _detail.value = DetailState(loading = false, error = "Not found")
                    return@launch
                }
                val stamped = when {
                    loaded.album != null -> loaded.copy(
                        album = loaded.album.copy(tracks = stampLikedIds(loaded.album.tracks)),
                    )
                    loaded.playlist != null -> loaded.copy(
                        playlist = loaded.playlist.copy(tracks = stampLikedIds(loaded.playlist.tracks)),
                    )
                    else -> loaded
                }
                _detail.value = stamped
                val tracks = stamped.album?.tracks ?: stamped.playlist?.tracks.orEmpty()
                if (tracks.isNotEmpty()) {
                    // Sparse rows resolve metadata (plus like-state) via the
                    // enrich pass, so the ratings pass skips them: one
                    // watch-next call per track instead of two.
                    val sparseIds = tracks.filter { track ->
                        track.artists.isEmpty() || track.thumbnails.isEmpty() || track.album == null
                    }.distinctBy { it.videoId }.map { it.videoId }.toSet()
                    requestTrackRatings(tracks.filter { it.videoId !in sparseIds }) { statuses ->
                        if (ratingToken == detailRatingToken) {
                            val current = _detail.value
                            fun List<Track>.applyRatings(): List<Track> = map { track ->
                                statuses[track.videoId]?.let { track.copy(rating = it) } ?: track
                            }
                            _detail.value = when {
                                current.album != null -> current.copy(
                                    album = current.album.copy(tracks = current.album.tracks.applyRatings()),
                                )
                                current.playlist != null -> current.copy(
                                    playlist = current.playlist.copy(tracks = current.playlist.tracks.applyRatings()),
                                )
                                else -> current
                            }
                        }
                    }
                    // Rows that arrived without artists/artwork (e.g. sparse
                    // album pages) get their canonical metadata from YouTube
                    // up front, instead of only after tapping them. Enriched
                    // like-states apply here (only over UNKNOWN, never over
                    // explicit states) and prime the rating cache.
                    val sparse = tracks.filter { it.videoId in sparseIds }.distinctBy { it.videoId }
                    if (sparse.isNotEmpty()) {
                        scope.launch {
                            val enriched = runCatching { tube.enrichTracks(sparse) }.getOrDefault(sparse)
                            if (!isActive || ratingToken != detailRatingToken) return@launch
                            val byId = enriched.associateBy { it.videoId }
                            synchronized(ratingCache) {
                                enriched.forEach { resolved ->
                                    if (resolved.rating != RatingStatus.UNKNOWN &&
                                        ratingCache[resolved.videoId] == null
                                    ) {
                                        ratingCache[resolved.videoId] = resolved.rating
                                    }
                                }
                            }
                            fun List<Track>.applyMetadata(): List<Track> = map { track ->
                                val resolved = byId[track.videoId] ?: return@map track
                                track.copy(
                                    artists = resolved.artists.ifEmpty { track.artists },
                                    album = resolved.album ?: track.album,
                                    thumbnails = if (track.thumbnails.isEmpty()) {
                                        resolved.thumbnails
                                    } else {
                                        (track.thumbnails + resolved.thumbnails).distinctBy { it.url }
                                    },
                                    rating = if (track.rating == RatingStatus.UNKNOWN) {
                                        resolved.rating
                                    } else {
                                        track.rating
                                    },
                                )
                            }
                            _detail.update { current ->
                                when {
                                    current.album != null -> current.copy(
                                        album = current.album.copy(tracks = current.album.tracks.applyMetadata()),
                                    )
                                    current.playlist != null -> current.copy(
                                        playlist = current.playlist.copy(
                                            tracks = current.playlist.tracks.applyMetadata(),
                                        ),
                                    )
                                    else -> current
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                if (isActive) {
                    _detail.value = DetailState(loading = false, error = e.message ?: "Load failed")
                }
            }
        }
    }

    private val _loginDetail = MutableStateFlow<String?>(null)
    /** Last sign-in failure detail for display, or null when idle or successful. */
    val loginDetail: StateFlow<String?> = _loginDetail.asStateFlow()

    /** True while the search text field holds focus (space must type, not toggle). */
    var searchFieldFocused by mutableStateOf(false)

    /**
     * Signs in with a browser cookie header, verifying it against YouTube before saving.
     *
     * @param cookie raw Cookie header value pasted from DevTools.
     * @param onDone invoked with true on success, false with [loginDetail] set on failure.
     */
    fun login(cookie: String, onDone: (Boolean) -> Unit) {
        scope.launch {
            if (cookie.contains('…') || cookie.contains("...")) {
                _loginDetail.value = "The pasted cookie looks TRUNCATED (it contains '…'). " +
                    "In DevTools, click 'view source' next to Request Headers and copy the full Cookie line — " +
                    "the pretty view cuts long values off."
                onDone(false)
                return@launch
            }
            val session = AuthSession.fromCookie(cookie)
            if (session == null) {
                val names = Regex("""([A-Za-z0-9_.$-]+)=""").findAll(cookie)
                    .map { it.groupValues[1] }.distinct().take(12).toList()
                _loginDetail.value = if (names.isEmpty()) {
                    "The pasted text contains no cookies at all — copy the whole 'Cookie' header value."
                } else {
                    "Found cookies: ${names.joinToString(", ")} — none is __Secure-3PAPISID/SAPISID. " +
                        "Copy the Cookie header of a music.youtube.com request while logged in."
                }
                onDone(false)
                return@launch
            }
            tube.auth = session
            // Forensics (local file only, never the cookie itself).
            val debug = InnerTube.AuthDebug()
            try {
                java.io.File("/tmp/nixietube-auth-debug.log").writeText("")
                val names = Regex("""([A-Za-z0-9_.$-]+)=""").findAll(cookie.replace(Regex("\\s+"), ""))
                    .map { it.groupValues[1] }.distinct().take(20).toList()
                debug.log("cookie names present: $names")
                debug.log("derived auth: ${session.sapisidHash}")
            } catch (_: Exception) {
            }
            val ok = try {
                tube.verifyLogin(debug)
            } catch (_: Exception) {
                false
            }
            if (ok) {
                val name = try {
                    tube.accountName()
                } catch (_: Exception) {
                    null
                }
                saveAuth(session.cookie.orEmpty(), session.sapisidHash.orEmpty())
                // Fetch XSRF-TOKEN (session_token) from the page HTML so
                // stats/* beacons record listening history.
                try {
                    tube.fetchSessionToken()?.let {
                        tube.auth = tube.auth.copy(sessionToken = it)
                        saveAuth(session.cookie.orEmpty(), session.sapisidHash.orEmpty(), it)
                    }
                } catch (_: Exception) {
                }
                _account.value = name ?: "YouTube Music account"
                onDone(true)
            } else {
                tube.auth = AuthSession.Anonymous
                _loginDetail.value =
                    "Cookie has SAPISID but YouTube rejected it — the browser session may be logged out or " +
                        "expired. Log in on music.youtube.com and copy a fresh Cookie header."
                onDone(false)
            }
        }
    }

    /** Replaces playlist covers with the authoritative InnerTube playlist-header artwork. */
    private fun enrichPlaylistArtwork(source: List<GDataApi.GPlaylist>) {
        val targets = source.filter { it.id != "__liked" }
        if (targets.isEmpty()) return
        scope.launch {
            targets.chunked(4).forEach { chunk ->
                val resolved = coroutineScope {
                    chunk.map { playlist ->
                        async {
                            val art = runCatching {
                                tube.playlistArtwork(playlist.id)
                            }.getOrDefault(emptyList())
                                .maxByOrNull { it.width }?.url
                            if (art.isNullOrBlank()) playlist else playlist.copy(art = art)
                        }
                    }.awaitAll()
                }
                val byId = resolved.associateBy { it.id }
                _playlists.value = _playlists.value.map { playlist ->
                    val replacement = byId[playlist.id]
                    if (replacement != null && replacement.art != playlist.art) {
                        playlist.copy(art = replacement.art, arts = playlist.arts)
                    } else {
                        playlist
                    }
                }
                _openPlaylist.value = _openPlaylist.value?.let { (open, tracks) ->
                    val replacement = byId[open.id]
                    if (replacement != null && replacement.art != open.art) {
                        replacement to tracks
                    } else {
                        open to tracks
                    }
                }
            }
        }
    }

    /**
     * Loads playlists, activity, subscriptions and liked songs concurrently.
     *
     * Shows a liked preview fast, then completes the full liked list in the background.
     */
    fun loadLibrary() {
        val api = gdata ?: return
        scope.launch {
            _libraryLoading.value = true
            // All library streams fetch concurrently: sequential awaits
            // used to park the personal home rows behind the slowest call
            // (a full liked-videos pagination). The liked preview is capped
            // so every personal row lands in about a second.
            coroutineScope {
                val playlistsDef = async { runCatching { api.playlists() }.getOrDefault(emptyList()) }
                val activityDef = async { runCatching { api.recentActivity() }.getOrDefault(emptyList()) }
                val artistsDef = async { runCatching { api.subscriptions() }.getOrDefault(emptyList()) }
                val likedPreviewDef = async { runCatching { api.likedVideos(max = 150) }.getOrDefault(emptyList()) }
                _playlists.value = playlistsDef.await()
                enrichPlaylistArtwork(_playlists.value)
                _activity.value = activityDef.await()
                refreshRecentArtists()
                _artists.value = artistsDef.await()
                _liked.value = likedPreviewDef.await()
                updateLikedPlaylistEntry()
            }
            _libraryLoading.value = false
            enrichActivityArtists()
            loadDiscover()
            // Full liked list for library completeness, in the background
            // (the preview above is already showing).
            scope.launch {
                val full = runCatching { api.likedVideos() }.getOrDefault(emptyList())
                if (full.size > _liked.value.size) {
                    _liked.value = full
                    updateLikedPlaylistEntry()
                }
            }
        }
    }

    /** Prepends the synthetic YTM-style "Liked songs" entry with a cover collage. */
    private fun updateLikedPlaylistEntry() {
        val likedNow = _liked.value
        if (likedNow.isNotEmpty()) {
            val collage = likedNow.take(4).mapNotNull { it.displayArtwork }
            _playlists.value = listOf(
                GDataApi.GPlaylist(
                    id = "__liked",
                    title = "Liked songs",
                    itemCount = likedNow.size,
                    art = collage.firstOrNull(),
                    arts = collage,
                ),
            ) + _playlists.value.filter { it.id != "__liked" }
        }
    }

    /** Resolves real artist credits for label-upload activity tracks via InnerTube enrichment. */
    fun enrichActivityArtists() {
        scope.launch {
            val current = _activity.value
            if (current.isEmpty()) return@launch
            try {
                val fixed = kotlinx.coroutines.coroutineScope {
                    current.map { t ->
                        async {
                            runCatching { tube.enrichTrack(t) }.getOrDefault(t)
                        }
                    }.map { it.await() }
                }
                // Only apply if the list hasn't changed underneath us.
                if (_activity.value.map { it.videoId } == current.map { it.videoId }) {
                    _activity.value = fixed
                    refreshRecentArtists()
                }
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Opens the library playlist with [id] and navigates to the Library screen.
     *
     * @param id playlist id to open.
     */
    fun openPlaylistById(id: String) {
        _playlists.value.firstOrNull { it.id == id }?.let {
            openPlaylist(it)
            go(Screen.Library)
        }
    }

    /**
     * Opens [pl], entering its screen immediately while tracks load in the background.
     *
     * Liked songs open from the local cache; other playlists fetch tracks then enrich sparse rows.
     *
     * @param pl playlist to open.
     */
    fun openPlaylist(pl: GDataApi.GPlaylist) {
        if (pl.id == "__liked") {
            val tracks = stampLikedIds(_liked.value)
            _openPlaylist.value = pl to tracks
            requestTrackRatings(tracks) { statuses ->
                val opened = _openPlaylist.value
                if (opened?.first?.id == pl.id) {
                    _openPlaylist.value = opened.first to opened.second.map { track ->
                        statuses[track.videoId]?.let { track.copy(rating = it) } ?: track
                    }
                }
            }
            return
        }
        val api = gdata ?: return
        val current = _playlists.value.firstOrNull { it.id == pl.id } ?: pl
        scope.launch {
            _libraryLoading.value = true
            // Enter the playlist screen immediately (header + centered
            // spinner in the list area) instead of sitting still while the
            // tracks fetch.
            _openPlaylist.value = current to emptyList()
            try {
                val tracks = stampLikedIds(api.playlistTracks(current.id))
                if (_openPlaylist.value?.first?.id != current.id) return@launch
                _openPlaylist.value = current to tracks
                // Sparse rows resolve metadata (plus like-state) via the
                // enrich pass, so the ratings pass skips them: one
                // watch-next call per track instead of two.
                val sparseIds = tracks.filter { track ->
                    track.artists.isEmpty() || track.thumbnails.isEmpty() || track.album == null
                }.distinctBy { it.videoId }.map { it.videoId }.toSet()
                requestTrackRatings(tracks.filter { it.videoId !in sparseIds }) { statuses ->
                    val opened = _openPlaylist.value
                    if (opened?.first?.id == current.id) {
                        _openPlaylist.value = opened.first to opened.second.map { track ->
                            statuses[track.videoId]?.let { track.copy(rating = it) } ?: track
                        }
                    }
                }
                val sparse = tracks.filter { it.videoId in sparseIds }.distinctBy { it.videoId }
                if (sparse.isNotEmpty()) {
                    val enriched = runCatching { tube.enrichTracks(sparse) }.getOrDefault(sparse)
                    val opened = _openPlaylist.value
                    if (opened != null && opened.first.id == current.id) {
                        val byId = enriched.associateBy { it.videoId }
                        synchronized(ratingCache) {
                            enriched.forEach { resolved ->
                                if (resolved.rating != RatingStatus.UNKNOWN &&
                                    ratingCache[resolved.videoId] == null
                                ) {
                                    ratingCache[resolved.videoId] = resolved.rating
                                }
                            }
                        }
                        _openPlaylist.value = opened.first to opened.second.map { track ->
                            val resolved = byId[track.videoId] ?: return@map track
                            track.copy(
                                artists = resolved.artists.ifEmpty { track.artists },
                                album = resolved.album ?: track.album,
                                thumbnails = if (track.thumbnails.isEmpty()) {
                                    resolved.thumbnails
                                } else {
                                    (track.thumbnails + resolved.thumbnails).distinctBy { it.url }
                                },
                                rating = if (track.rating == RatingStatus.UNKNOWN) {
                                    resolved.rating
                                } else {
                                    track.rating
                                },
                            )
                        }
                    }
                }
                if (current.art.isNullOrBlank() && _openPlaylist.value?.first?.id == current.id) {
                    val art = runCatching { tube.playlistArtwork(current.id) }
                        .getOrDefault(emptyList())
                        .maxByOrNull { it.width }?.url
                    if (!art.isNullOrBlank()) {
                        val enriched = current.copy(art = art)
                        _playlists.value = _playlists.value.map {
                            if (it.id == enriched.id) enriched else it
                        }
                        _openPlaylist.value = enriched to (_openPlaylist.value?.second ?: tracks)
                    }
                }
            } catch (_: Exception) {
                // Don't leave an empty spinner behind on failure.
                if (_openPlaylist.value?.first?.id == current.id) closePlaylist()
            }
            _libraryLoading.value = false
        }
    }

    /** Closes the open playlist, returning to the library root. */
    fun closePlaylist() {
        _openPlaylist.value = null
    }

    /** Applies [rating] for [videoId] to the detail and open-playlist views. */
    private fun applyRatingToViews(videoId: String, rating: RatingStatus) {
        fun updateTrack(track: Track): Track =
            if (track.videoId == videoId) track.copy(rating = rating) else track
        val detail = _detail.value
        _detail.value = when {
            detail.album != null ->
                detail.copy(album = detail.album.copy(tracks = detail.album.tracks.map(::updateTrack)))
            detail.playlist != null ->
                detail.copy(
                    playlist = detail.playlist.copy(tracks = detail.playlist.tracks.map(::updateTrack)),
                )
            else -> detail
        }
        val opened = _openPlaylist.value
        if (opened != null) {
            _openPlaylist.value = opened.first to opened.second.map(::updateTrack)
        }
    }

    /**
     * Rates the currently playing track.
     *
     * @param rating the new rating; [RatingStatus.UNKNOWN] is ignored.
     */
    fun rateCurrent(rating: RatingStatus) {
        val id = player.state.value.current?.videoId ?: return
        rateTrack(id, rating)
    }

    /**
     * Rates a track via InnerTube with a Data API fallback, updating player, views and liked songs.
     *
     * Dislikes only go through InnerTube since the Data API can only add/remove likes.
     *
     * @param videoId video id of the track to rate.
     * @param rating the new rating; [RatingStatus.UNKNOWN] is ignored.
     */
    fun rateTrack(videoId: String, rating: RatingStatus) {
        if (rating == RatingStatus.UNKNOWN) return
        val api = gdata
        scope.launch {
            val innerTubeOk = runCatching { tube.rate(videoId, rating) }.getOrDefault(false)
            val dataApiFallback = !innerTubeOk && rating != RatingStatus.DISLIKE && api != null &&
                runCatching { api.rate(videoId, rating == RatingStatus.LIKE) }.getOrDefault(false)
            if (!innerTubeOk && !dataApiFallback) return@launch

            player.updateTrackRating(videoId, rating)
            synchronized(ratingCache) {
                ratingCache[videoId] = rating
                ratingRequests.remove(videoId)
                ratingWaiters.remove(videoId)
            }
            applyRatingToViews(videoId, rating)
            val playerState = player.state.value
            val track = playerState.current?.takeIf { it.videoId == videoId }
                ?: playerState.queue.firstOrNull { it.videoId == videoId }
            if (rating == RatingStatus.LIKE) {
                if (track != null) {
                    _liked.value = (_liked.value + track).distinctBy { it.videoId }
                }
            } else {
                _liked.value = _liked.value.filterNot { it.videoId == videoId }
            }
        }
    }

    /** Signs out everywhere: clears auth, library, rating caches and the saved session file. */
    fun logout() {
        tube.auth = AuthSession.Anonymous
        tube.authProvider = null
        oauth?.logout()
        _account.value = null
        _accountAvatar.value = null
        _liked.value = emptyList()
        likedIds = emptySet()
        synchronized(ratingCache) {
            ratingCache.clear()
            ratingRequests.clear()
            ratingWaiters.clear()
        }
        lastRatingVideoId = null
        lastRatingQueueKey = null
        ownChannelId = null
        ownChannelIdLoaded = false
        player.state.value.current?.let { player.updateTrackRating(it.videoId, RatingStatus.UNKNOWN) }
        authFile().delete()
    }

    /**
     * Completes the Google device login, resolving the channel and loading the library on success.
     *
     * @param onUserCode invoked with the device code and verification URL to show the user.
     * @param onDone invoked with true on success, false otherwise.
     */
    fun googleLogin(
        onUserCode: (code: String, url: String) -> Unit,
        onDone: (Boolean) -> Unit,
    ) {
        val o = oauth ?: run { onDone(false); return }
        currentLoginJob?.cancel()
        currentLoginJob = scope.launch {
            val id = SysConfig.googleClientId
            val secret = SysConfig.googleClientSecret
            if (id.isBlank() || secret.isBlank()) {
                onDone(false)
                return@launch
            }
            val minted = try {
                o.loginDevice(id, secret, onUserCode) { !loginActive.get() }
            } catch (_: Exception) {
                false
            }
            if (!loginActive.get()) return@launch
            val name = if (minted) {
                try {
                    gdata?.channelName()
                } catch (_: Exception) {
                    null
                }
            } else {
                null
            }
            if (name != null) {
                _account.value = name
                refreshAccountAvatar()
                refreshCurrentRating()
                loadLibrary()
                refreshLikedIds()
                onDone(true)
            } else {
                onDone(false)
            }
        }
    }

    /** Cancels an in-flight Google device login. */
    fun cancelGoogleLogin() {
        loginActive.set(false)
        currentLoginJob?.cancel()
    }

    private var currentLoginJob: kotlinx.coroutines.Job? = null
    private val loginActive = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Arms the device-login flow so [googleLogin] accepts the minted session. */
    fun beginGoogleLogin() {
        loginActive.set(true)
    }

    private fun configDir(): File = File(System.getProperty("user.home"), ".config/nixietube").also { it.mkdirs() }

    private fun authFile(): File = File(configDir(), "auth.properties")

    /** Restores the saved cookie session, re-deriving a fresh auth timestamp on launch. */
    private fun loadAuth() {
        val f = authFile()
        if (!f.exists()) return
        try {
            val p = Properties().also { f.inputStream().use { s -> it.load(s) } }
            val cookie = p.getProperty("cookie").orEmpty()
            val hash = p.getProperty("sapisidHash").orEmpty()
            // Re-derive the SAPISIDHASH timestamp on every launch instead
            // of replaying the saved one: the saved hash works, but a fresh
            // timestamp removes stale-signature rejections as a failure
            // class entirely. Falls back to the saved pair verbatim.
            val session = if (cookie.isNotBlank()) {
                AuthSession.fromCookie(cookie) ?: AuthSession(cookie, hash.takeIf { it.isNotBlank() })
            } else {
                null
            }
            if (session != null) {
                // Reset login-validity cache so the next playthrough
                // re-verifies the freshly loaded cookie.
                loginCheckedAt = 0L
                loginValid = true
                // Restore the saved XSRF session token immediately so the
                // first playthrough already records history; it is
                // re-fetched below in case it rotated.
                val savedToken = p.getProperty("sessionToken").orEmpty().takeIf { it.isNotBlank() }
                tube.auth = if (savedToken != null) session.copy(sessionToken = savedToken) else session
                scope.launch {
                    _account.value = try {
                        tube.accountName()
                    } catch (_: Exception) {
                        null
                    }
                    // Fetch XSRF-TOKEN (session_token) from the page HTML so
                    // stats/* beacons record listening history. The token is
                    // session-specific; fetched once at login and re-fetched
                    // on next app launch.
                    try {
                        tube.fetchSessionToken()?.let {
                            tube.auth = tube.auth.copy(sessionToken = it)
                            saveAuth(tube.auth.cookie.orEmpty(), tube.auth.sapisidHash.orEmpty(), it)
                        }
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    /** Persists the cookie session to the auth properties file. */
    private fun saveAuth(cookie: String, hash: String, sessionToken: String? = null) {
        try {
            val p = Properties()
            p.setProperty("cookie", cookie)
            p.setProperty("sapisidHash", hash)
            if (!sessionToken.isNullOrBlank()) p.setProperty("sessionToken", sessionToken)
            authFile().outputStream().use { p.store(it, null) }
        } catch (_: Exception) {
        }
    }
}

/**
 * Home feed content with loading/error state.
 *
 * @property loading true while the shelves fetch is in flight.
 * @property shelves loaded home shelves.
 * @property error failure message, or null on success.
 */
data class HomeUiState(
    val loading: Boolean = true,
    val shelves: List<Shelf> = emptyList(),
    val error: String? = null,
)

/**
 * Search content for the last submitted query.
 *
 * @property query normalized submitted query.
 * @property loading true while the search fetch is in flight.
 * @property sections result sections keyed by section title.
 * @property error failure message, or null on success.
 */
data class SearchUiState(
    val query: String = "",
    val loading: Boolean = false,
    val sections: Map<String, List<ShelfItem>> = emptyMap(),
    val error: String? = null,
)
