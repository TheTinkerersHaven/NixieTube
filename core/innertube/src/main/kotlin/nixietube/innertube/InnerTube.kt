package nixietube.innertube

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap
import java.net.URLEncoder

/** InnerTube HTTP timeouts: hung sockets must never stall playback reporting. */
private const val HTTP_REQUEST_TIMEOUT_MS = 30_000L
private const val HTTP_CONNECT_TIMEOUT_MS = 10_000L
private const val HTTP_SOCKET_TIMEOUT_MS = 30_000L

/** Per-playback watchtime contexts kept (one entry per track playback). */
private const val WATCHTIME_CONTEXT_CACHE_SIZE = 16

/** First rtn counter per playback; rti chains the previous value. */
private const val WATCHTIME_INITIAL_RTN = 28

/** rtn increment between watchtime heartbeats of one playback. */
private const val WATCHTIME_RTN_STEP = 10

// Minimal YouTube Music InnerTube client over the public WEB_REMIX client.
// Anonymous by default; AuthSession headers (cookie + SAPISIDHASH) unlock
// library, likes and playlists.

/**
 * Minimal YouTube Music InnerTube client over the public WEB_REMIX client.
 *
 * Anonymous by default; [AuthSession] headers (cookie + SAPISIDHASH) unlock
 * library, likes and playlists.
 *
 * @param auth initial auth session, defaults to anonymous.
 */
class InnerTube(auth: AuthSession = AuthSession.Anonymous) {
    /** Current auth session used (with fallbacks) for InnerTube requests. */
    @Volatile
    var auth: AuthSession = auth

    // Optional hook (e.g. OAuth refresh) consulted before every request.
    var authProvider: (suspend () -> AuthSession?)? = null

    /** JSON codec with ignoreUnknownKeys and lenient parsing. */
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    // CIO speaks HTTP/1.1 by default, which is what YouTube's
    // frontends want with cookies (the old OkHttp setup pinned this
    // explicitly). Pure-Kotlin engine: no extra threads, no native deps.
    // Explicit timeouts: without them a hung socket hangs forever and a
    // single blip fails login/verify outright (see the retry in post).
    /** HTTP client with timeouts and JSON content negotiation. */
    private val client = HttpClient(CIO) {
        install(HttpTimeout) {
            requestTimeoutMillis = HTTP_REQUEST_TIMEOUT_MS
            connectTimeoutMillis = HTTP_CONNECT_TIMEOUT_MS
            socketTimeoutMillis = HTTP_SOCKET_TIMEOUT_MS
        }
        install(ContentNegotiation) { json(json) }
    }

    /** Memoizes album details fetched during track enrichment. */
    private val albumDetailsCache = ConcurrentHashMap<String, AlbumDetail>()

    // Remembers a Bearer token that WEB_REMIX rejected, so follow-up calls
    // skip straight to the working session instead of paying a doomed
    // request every time. Reset automatically when the token rotates.
    @Volatile
    private var bearerBrokenFor: String? = null

    /** Posts to an InnerTube endpoint with cookie/Bearer/anonymous auth fallback. */
    private suspend fun post(path: String, body: JsonElement): JsonElement {
        val session = try {
            authProvider?.invoke()
        } catch (_: Exception) {
            null
        } ?: auth

        // OAuth access tokens minted for the TV/device flow are valid for the
        // Data API, but WEB_REMIX rejects them with a 400 INVALID_ARGUMENT
        // response (verified: account_menu fails even with a fresh token,
        // while the cookie session succeeds). A valid Bearer session must
        // therefore never shadow a working cookie for endpoints that reject
        // Bearer auth (account_menu, library, like, search, next, browse).
        //
        // However, the feedback endpoint DOES accept Bearer tokens (200 OK),
        // and stats/* beacons do too. When the saved cookie is stale (LOGIN_INFO
        // expired), the cookie still returns 200/204 without an `error` field,
        // so post() returns it as a false success without ever trying Bearer.
        // For feedback specifically, prefer Bearer first so watchtime
        // reporting works when only the OAuth session is fresh.
        val saved = auth
        val token = session.accessToken
        val isFeedback = path == "feedback"
        val skipBearer = token != null && bearerBrokenFor == token && !isFeedback
        val sessions = buildList {
            if (isFeedback) {
                // feedback: Bearer first (valid), then cookie, then anonymous
                if (!skipBearer) add(session)
                if (!saved.cookie.isNullOrBlank() && saved != session) add(saved)
            } else {
                // all other paths: cookie first, then Bearer, then anonymous
                if (!saved.cookie.isNullOrBlank() && saved != session) add(saved)
                if (!skipBearer) add(session)
            }
            if (saved != session) add(saved)
            add(AuthSession.Anonymous)
        }.distinct()
        var last: JsonElement? = null
        var bearerFailed = false
        for (candidate in sessions) {
            // Transport blips (timeout, reset) throw; auth verdicts come
            // back as error bodies. Retry the transport once, then let it
            // propagate — callers distinguish errors from empty results.
            val response = try {
                request(path, body, candidate)
            } catch (_: Exception) {
                request(path, body, candidate)
            }
            if (!response.isErrorResponse()) {
                if (bearerFailed && token != null) bearerBrokenFor = token
                return response
            }
            if (candidate.accessToken != null && candidate.accessToken == token) {
                bearerFailed = true
            }
            last = response
            if (!canUseAnonymousFallback(path, body)) break
        }
        return last ?: JsonObject(emptyMap())
    }

    /** Returns true when an authed error response may be retried with other sessions. */
    private fun canUseAnonymousFallback(path: String, body: JsonElement): Boolean =
        when (path) {
            "search", "next" -> true
            // Public music browse is safe to retry, but a library browse must
            // remain an honest authentication check (verifyLogin relies on it).
            "browse" -> !body.toString().contains("FEmusic_library_landing")
            // feedback playerEvent: retry cookie → Bearer → anonymous so
            // watchtime fallback works for mixed auth sessions.
            "feedback" -> true
            else -> false
        }

    /** Executes a single authenticated InnerTube POST. */
    private suspend fun request(path: String, body: JsonElement, session: AuthSession): JsonElement =
        client.post("https://music.youtube.com/youtubei/v1/$path?alt=json") {
            // Shape mirrors ytmusicapi: no API key, alt=json, Firefox UA,
            // Origin always; X-Goog-Request-Time only for custom OAuth clients.
            contentType(ContentType.Application.Json)
            header(HttpHeaders.UserAgent, USER_AGENT)
            header(HttpHeaders.Origin, "https://music.youtube.com")
            if (session.accessToken != null) {
                header(HttpHeaders.Authorization, "Bearer ${session.accessToken}")
                header("X-Goog-Request-Time", (System.currentTimeMillis() / 1000).toString())
            } else {
                session.cookie?.let { header(HttpHeaders.Cookie, it) }
                session.sapisidHash?.let { header(HttpHeaders.Authorization, "SAPISIDHASH $it") }
            }
            setBody(body)
        }.body()

    /** Returns true when a response body is an InnerTube error envelope. */
    private fun JsonElement.isErrorResponse(): Boolean =
        this is JsonObject && this["error"] != null

    /** Builds the WEB_REMIX client context block for requests. */
    private fun contextBlock(): JsonElement = buildJsonObject {
        put("context", buildJsonObject {
            put("client", buildJsonObject {
                put("clientName", "WEB_REMIX")
                put("clientVersion", currentClientVersion())
                put("hl", "en")
            })
            put("user", buildJsonObject {})
        })
    }

    /** Returns today's WEB_REMIX client version string. */
    private fun currentClientVersion(): String {
        val today = java.time.LocalDate.now(java.time.ZoneOffset.UTC)
        return "1.%04d%02d%02d.01.00".format(today.year, today.monthValue, today.dayOfMonth)
    }

    /** Merges the client context with extra top-level body fields. */
    private fun bodyWith(extra: Map<String, String>): JsonElement = buildJsonObject {
        put("context", contextBlock().jsonObject.getValue("context"))
        extra.forEach { (k, v) -> put(k, v) }
    }

    // ---------- Home ----------

    /**
     * Loads the home feed shelves.
     *
     * @return home shelves, or empty when the response has no tabs.
     */
    suspend fun home(): List<Shelf> {
        val res = post("browse", bodyWith(mapOf("browseId" to "FEmusic_home")))
        val tabs = res.nav("contents", "singleColumnBrowseResultsRenderer", "tabs") as? JsonArray
            ?: return emptyList()
        val content = tabs.firstOrNull()
            ?.nav("tabRenderer", "content", "sectionListRenderer", "contents") as? JsonArray
            ?: return emptyList()
        return content.mapNotNull { parseShelf(it) }
    }

    /** Parses a home-feed element into a shelf, or null when unsupported/empty. */
    private fun parseShelf(el: JsonElement): Shelf? {
        (el as? JsonObject)?.get("musicCarouselShelfRenderer")?.let { shelf ->
            val title = shelf.nav("header", "musicCarouselShelfBasicHeaderRenderer", "title", "runs")
                .runsText().ifBlank { return@let null }
            val items = (shelf.nav("contents") as? JsonArray)
                ?.mapNotNull { parseShelfItem(it) }.orEmpty()
            if (items.isEmpty()) return@let null
            return Shelf(title, items)
        }
        (el as? JsonObject)?.get("musicShelfRenderer")?.let { shelf ->
            val title = shelf.nav("title", "runs").runsText()
            val items = (shelf.nav("contents") as? JsonArray)
                ?.mapNotNull {
                    it.nav("musicResponsiveListItemRenderer")
                        ?.let { li -> parseListItem(li)?.let { t -> ShelfItem.Song(t) } }
                }.orEmpty()
            if (items.isEmpty()) return@let null
            return Shelf(title.ifBlank { "Songs" }, items)
        }
        return null
    }

    /** Parses a shelf content element into a song or browse item. */
    private fun parseShelfItem(el: JsonElement): ShelfItem? {
        (el as? JsonObject)?.get("musicTwoRowItemRenderer")?.let { item ->
            val title = item.nav("title", "runs").runsText()
            val subtitle = item.nav("subtitle", "runs").runsText()
            val thumbs = item.parseThumbnails()
            item.nav("navigationEndpoint", "watchEndpoint", "videoId")?.str()?.let { videoId ->
                val playlistId = item.nav("navigationEndpoint", "watchEndpoint", "playlistId")?.str()
                return ShelfItem.Song(
                    Track(
                        videoId = videoId,
                        title = title.ifBlank { subtitle },
                        artists = listOfNotNull(subtitle.takeIf { it.isNotBlank() }?.let { ArtistRef(it) }),
                        thumbnails = thumbs,
                        playlistId = playlistId,
                        radioPlaylistId = "RDAMVM$videoId",
                    ),
                )
            }
            val endpoint = item.nav("navigationEndpoint", "browseEndpoint")
            endpoint?.nav("browseId")?.str()?.let { browseId ->
                return ShelfItem.Browse(
                    title = title,
                    subtitle = subtitle,
                    browseId = browseId,
                    thumbnails = thumbs,
                    kind = detectReleaseKind(subtitle),
                    browseParams = endpoint.nav("params")?.str(),
                )
            }
            return null
        }
        (el as? JsonObject)?.get("musicResponsiveListItemRenderer")?.let { li ->
            return parseListItem(li)?.let { ShelfItem.Song(it) }
        }
        return null
    }

    // ---------- Search ----------

    /**
     * Searches YouTube Music and normalizes results into stable categories.
     *
     * @param query search text.
     * @return map of "Songs", "Albums/EP/Singles" and "Artists" to items.
     */
    suspend fun search(query: String): Map<String, List<ShelfItem>> {
        val res = post("search", bodyWith(mapOf("query" to query)))
        val tabs = res.nav("contents", "tabbedSearchResultsRenderer", "tabs") as? JsonArray
            ?: return emptyMap()
        val sections = tabs.firstOrNull()
            ?.nav("tabRenderer", "content", "sectionListRenderer", "contents") as? JsonArray
            ?: return emptyMap()
        val raw = linkedMapOf<String, MutableList<ShelfItem>>()
        val directSongs = mutableListOf<ShelfItem.Song>()
        for (section in sections) {
            val obj = section as? JsonObject ?: continue
            // Shelves may sit at top level or inside itemSectionRenderer.
            val candidates = mutableListOf(obj)
            (obj.get("itemSectionRenderer")?.nav("contents") as? JsonArray)
                ?.mapNotNull { it as? JsonObject }
                ?.let { candidates.addAll(it) }
            for (c in candidates) {
                if (c.get("musicShelfRenderer") != null || c.get("musicCardShelfRenderer") != null) {
                    parseSearchShelf(c, raw)
                    continue
                }
                c.get("musicResponsiveListItemRenderer")?.let { li ->
                    parseListItem(li)?.let { directSongs += ShelfItem.Song(it) }
                        ?: parseBrowseItem(li)?.let { raw.getOrPut("Browse") { mutableListOf() } += it }
                }
            }
        }
        if (directSongs.isNotEmpty()) raw.getOrPut("Songs") { mutableListOf() }.addAll(directSongs)

        // YouTube returns several locale/shelf-specific sections. Normalize
        // them into the three stable categories exposed by the UI.
        val songs = linkedMapOf<String, ShelfItem.Song>()
        val releases = linkedMapOf<String, ShelfItem.Browse>()
        val artists = linkedMapOf<String, ShelfItem.Browse>()
        raw.values.forEach { items ->
            items.forEach { item ->
                when (item) {
                    is ShelfItem.Song -> songs.putIfAbsent(item.track.videoId, item)
                    is ShelfItem.Browse -> when {
                        item.browseId.startsWith("MPRE") -> releases.putIfAbsent(item.browseId, item)
                        item.browseId.startsWith("UC") -> artists.putIfAbsent(item.browseId, item)
                    }
                }
            }
        }
        // A single/EP sometimes arrives with no dedicated song row — only
        // the release entity — even when unrelated same-titled songs are
        // present. When the query names such a release exactly, surface its
        // title track(s) first so the exact match is playable. Bounded to
        // singles/EPs (at most two fetches); albums are left alone.
        val queryCanon = canonicalMetadata(query)
        // The query's dominant artist(s): exact title matches credited to
        // them outrank same-titled covers (e.g. Mahmood's "TUTA GOLD"
        // above its 147K-view covers).
        val dominantIds = artists.values.map { it.browseId }.toSet()
        val dominantNames = artists.values.map { canonicalMetadata(it.title) }
            .filter { it.isNotBlank() }.toSet()
        fun ShelfItem.Song.isDominantMatch(): Boolean =
            track.artists.any { artist ->
                (!artist.browseId.isNullOrBlank() && artist.browseId in dominantIds) ||
                    canonicalMetadata(artist.name).takeIf { it.isNotBlank() } in dominantNames
            }
        fun ShelfItem.Browse.isDominantRelease(): Boolean {
            if (dominantNames.isEmpty()) return false
            val subtitle = " ${canonicalMetadata(this.subtitle)} "
            return dominantNames.any { name -> subtitle.contains(" $name ") }
        }
        if (queryCanon.isNotBlank()) {
            val added = releases.values
                .filter {
                    (it.kind == ReleaseKind.SINGLE || it.kind == ReleaseKind.EP) &&
                        canonicalMetadata(it.title) == queryCanon
                }
                // Prefer the dominant artist's release: without this the
                // first two same-titled covers win and get prepended below.
                .sortedByDescending { it.isDominantRelease() }
                .take(2)
                .flatMap { release ->
                    runCatching { album(release.browseId)?.tracks }.getOrNull().orEmpty()
                }
                .filter { canonicalMetadata(it.title) == queryCanon && !songs.containsKey(it.videoId) }
                .distinctBy { it.videoId }
            if (added.isNotEmpty()) {
                val ordered = linkedMapOf<String, ShelfItem.Song>()
                added.forEach { ordered[it.videoId] = ShelfItem.Song(it) }
                songs.forEach { (id, item) -> ordered.putIfAbsent(id, item) }
                songs.clear()
                songs.putAll(ordered)
            }
            // Exact title matches first — the dominant artist's recording
            // above same-titled covers — then everything else in YouTube's
            // order. No-op for artist-name queries (no title matches).
            val (exact, rest) = songs.values.partition { canonicalMetadata(it.track.title) == queryCanon }
            val (mine, others) = exact.partition { it.isDominantMatch() }
            val rankedSongs = mine + others + rest
            songs.clear()
            rankedSongs.forEach { songs[it.track.videoId] = it }
            // Same preference inside releases: the artist's own single/EP
            // above same-titled ones.
            if (dominantNames.isNotEmpty()) {
                val (ownReleases, otherReleases) = releases.values.partition { it.isDominantRelease() }
                val rankedReleases = ownReleases + otherReleases
                releases.clear()
                rankedReleases.forEach { releases[it.browseId] = it }
            }
        }
        return buildMap {
            if (songs.isNotEmpty()) put("Songs", songs.values.toList())
            if (releases.isNotEmpty()) put("Albums/EP/Singles", releases.values.toList())
            if (artists.isNotEmpty()) put("Artists", artists.values.toList())
        }
    }

    /** Merges one search-result shelf into the categorized output map. */
    private fun parseSearchShelf(obj: JsonObject, out: MutableMap<String, MutableList<ShelfItem>>) {
        obj.get("musicShelfRenderer")?.let { shelf ->
            val titleRuns = shelf.nav("title", "runs")
            val title = titleRuns.runsText().ifBlank { "Results" }
            addArtistSearchResult(out, shelf, title, titleRuns)
            val items = (shelf.nav("contents") as? JsonArray)?.mapNotNull {
                it.nav("musicResponsiveListItemRenderer")?.let { li ->
                    parseListItem(li)?.let { t -> ShelfItem.Song(t) }
                        ?: parseBrowseItem(li)
                }
            }.orEmpty()
            if (items.isNotEmpty()) {
                out.getOrPut(title) { mutableListOf() }.addAll(items)
            }
        }
        obj.get("musicCardShelfRenderer")?.let { shelf ->
            val titleRuns = shelf.nav("title", "runs")
            val rawItems = (shelf.nav("contents") as? JsonArray)?.mapNotNull {
                it.nav("musicResponsiveListItemRenderer")?.let { li ->
                    parseListItem(li)?.let { t -> ShelfItem.Song(t) }
                        ?: parseBrowseItem(li)
                }
            }.orEmpty()
            val title = titleRuns.runsText().ifBlank { "Top result" }
            addArtistSearchResult(out, shelf, title, titleRuns)
            // Top-result cards often omit the artist on every row (the card
            // itself *is* the artist). Backfill from the card title, except
            // for generic headers.
            val generic = title.equals("Top result", ignoreCase = true) ||
                title.equals("Results", ignoreCase = true)
            val items = if (!generic) {
                rawItems.map { item ->
                    if (item is ShelfItem.Song && item.track.artists.isEmpty()) {
                        ShelfItem.Song(
                            item.track.copy(artists = listOf(ArtistRef(title))),
                        )
                    } else {
                        item
                    }
                }
            } else {
                rawItems
            }
            if (items.isNotEmpty()) {
                out.getOrPut(title) { mutableListOf() }.addAll(items)
            }
            // Exact-match cards sometimes carry no rows at all — just the
            // entity header (thumbnail/title/onTap). The artist case is
            // covered above; surface a linked album the same way so exact
            // album searches never come back empty.
            if (!generic) {
                addAlbumSearchResult(out, shelf, title, titleRuns)
            }
        }
    }

    /**
     * Adds an artist entry from a shelf title run when it links to a channel.
     *
     * @param out categorized output map to append to.
     * @param shelf shelf JSON used for artwork fallback.
     * @param title shelf title text.
     * @param titleRuns title runs holding the browse endpoint.
     */
    private fun addArtistSearchResult(
        out: MutableMap<String, MutableList<ShelfItem>>,
        shelf: JsonElement,
        title: String,
        titleRuns: JsonElement?,
    ) {
        val genericTitle = title.isBlank() || title.equals("Top result", ignoreCase = true) ||
            title.equals("Results", ignoreCase = true) || title.equals("Artist", ignoreCase = true)
        if (genericTitle) return
        val browseId = titleRuns.artistBrowseId() ?: return
        if (!browseId.startsWith("UC")) return
        val artists = out.getOrPut("Artists") { mutableListOf() }
        if (artists.none { it is ShelfItem.Browse && it.browseId == browseId }) {
            artists += ShelfItem.Browse(
                title = title,
                subtitle = "Artist",
                browseId = browseId,
                thumbnails = shelf.nav("thumbnail")?.parseThumbnails().orEmpty(),
                browseParams = titleRuns.browseParamsFromRuns(),
            )
        }
    }

    /** Returns the first browse endpoint found in title runs, or null. */
    private fun JsonElement?.browseEndpointFromRuns(): JsonElement? {
        val runs = this as? JsonArray ?: return null
        return runs.asSequence()
            .mapNotNull { it.nav("navigationEndpoint", "browseEndpoint") }
            .firstOrNull()
    }

    /** Returns the first album browse endpoint in title runs, or null. */
    private fun JsonElement?.albumEndpointFromRuns(): JsonElement? {
        val runs = this as? JsonArray ?: return null
        return runs.asSequence()
            .mapNotNull { it.nav("navigationEndpoint", "browseEndpoint") }
            .firstOrNull { it.nav("browseId")?.str()?.startsWith("MPRE") == true }
    }

    /**
     * Adds an album entry from a card header when it links to a release.
     *
     * Top-result cards for exact album matches often carry no rows — the
     * header (title runs or onTap) is the only link to the release.
     *
     * @param out categorized output map to append to.
     * @param shelf shelf JSON holding the header, artwork and onTap endpoint.
     * @param title card title text (the entity name).
     * @param titleRuns title runs holding the browse endpoint.
     */
    private fun addAlbumSearchResult(
        out: MutableMap<String, MutableList<ShelfItem>>,
        shelf: JsonElement,
        title: String,
        titleRuns: JsonElement?,
    ) {
        if (title.isBlank()) return
        val endpoint = titleRuns.albumEndpointFromRuns()
            ?: shelf.nav("onTap", "browseEndpoint")?.takeIf {
                it.nav("browseId")?.str()?.startsWith("MPRE") == true
            } ?: return
        val browseId = endpoint.nav("browseId")?.str() ?: return
        val subtitle = shelf.nav("subtitle", "runs").runsText()
        val releases = out.getOrPut("Albums") { mutableListOf() }
        if (releases.none { it is ShelfItem.Browse && it.browseId == browseId }) {
            releases += ShelfItem.Browse(
                title = title,
                subtitle = subtitle,
                browseId = browseId,
                thumbnails = shelf.nav("thumbnail")?.parseThumbnails().orEmpty(),
                kind = detectReleaseKind(subtitle),
                browseParams = endpoint.nav("params")?.str(),
            )
        }
    }

    /** Returns the first browse id found in title runs, or null. */
    private fun JsonElement?.browseIdFromRuns(): String? =
        browseEndpointFromRuns()?.nav("browseId")?.str()

    /** Returns the first browse params found in title runs, or null. */
    private fun JsonElement?.browseParamsFromRuns(): String? =
        browseEndpointFromRuns()?.nav("params")?.str()

    /** Returns the artist channel id from title runs, or null when absent. */
    private fun JsonElement?.artistBrowseId(): String? =
        browseIdFromRuns()?.takeIf { it.startsWith("UC") }

    /** Parses a list row into a browse entry, or null when it has no browse id. */
    private fun parseBrowseItem(li: JsonElement): ShelfItem.Browse? {
        val flex = li.nav("flexColumns") as? JsonArray ?: return null
        val cols = flex.mapNotNull {
            it.nav("musicResponsiveListItemFlexColumnRenderer", "text", "runs") as? JsonArray
        }
        if (cols.isEmpty()) return null
        val title = cols[0].runsText()
        // Prefer the item-level endpoint: rows embed related entities'
        // ids in their runs (e.g. album rows carry the artist's UC id).
        val itemEndpoint = li.nav("navigationEndpoint", "browseEndpoint")
        var browseId = itemEndpoint?.nav("browseId")?.str()
        var browseParams = itemEndpoint?.nav("params")?.str()
        if (browseId == null) {
            outer@ for (col in cols) {
                for (run in col) {
                    val endpoint = run.nav("navigationEndpoint", "browseEndpoint")
                    browseId = endpoint?.nav("browseId")?.str()
                    browseParams = endpoint?.nav("params")?.str()
                    if (browseId != null) break@outer
                }
            }
        }
        browseId ?: return null
        val subtitle = cols.drop(1).joinToString(" ") { it.runsText() }
        return ShelfItem.Browse(
            title = title,
            subtitle = subtitle,
            browseId = browseId,
            thumbnails = li.parseThumbnails(),
            kind = detectReleaseKind(subtitle),
            browseParams = browseParams,
        )
    }

    // ---------- Detail pages ----------

    /**
     * Opens an album/release page and backfills track artists/artwork from the header.
     *
     * @param browseId release browse id (MPRE…).
     * @return album detail, or null when the header or shelf is missing.
     */
    suspend fun album(browseId: String): AlbumDetail? {
        val res = post("browse", bodyWith(mapOf("browseId" to browseId)))
        val header = (res.findFirst("musicDetailHeaderRenderer")
            ?: res.findFirst("musicResponsiveHeaderRenderer")) as? JsonObject ?: return null
        val shelf = res.findFirst("musicShelfRenderer") as? JsonObject
        val albumTitle = header.nav("title", "runs").runsText()
        val subtitle = header.nav("subtitle", "runs").runsText()
        val description = header.nav("description", "runs").runsText()
            .ifBlank { subtitle }
            .let { if (it == subtitle) "" else it }
        val headerThumbs = header.parseThumbnails()
        // Album track rows usually carry no thumbnail and no artist runs;
        // the header art and header artist apply to the whole release.
        // Unlinked headers (e.g. Various Artists compilations, credited in
        // the strapline) fall back to the plain-text credit so the author
        // row still shows.
        val headerArtist = channelRefFromRuns(
            header.nav("subtitle", "runs"),
            header.nav("straplineTextOne", "runs"),
            header.nav("straplineTextTwo", "runs"),
            header.nav("secondSubtitle", "runs"),
        ) ?: plainRefFromRuns(
            header.nav("subtitle", "runs"),
            header.nav("straplineTextOne", "runs"),
            header.nav("straplineTextTwo", "runs"),
            header.nav("secondSubtitle", "runs"),
        )
        val kind = detectReleaseKind(subtitle) ?: detectReleaseKind(description)
        val tracks = (shelf?.nav("contents") as? JsonArray)?.mapNotNull {
            it.nav("musicResponsiveListItemRenderer")?.let { li -> parseListItem(li) }
        }.orEmpty().map { track ->
            var fixed = track
            if (fixed.thumbnails.isEmpty() && headerThumbs.isNotEmpty()) {
                fixed = fixed.copy(thumbnails = headerThumbs)
            }
            // Only linked header artists backfill track rows: stamping an
            // unlinked credit (e.g. Various Artists) would poison
            // artist-based matching downstream (lyrics lookup treats a
            // blank artist as match-all). The header row itself still uses
            // headerArtist via AlbumDetail.artist.
            if (fixed.artists.isEmpty() && headerArtist?.browseId != null) {
                fixed = fixed.copy(artists = listOf(headerArtist), artistId = headerArtist.browseId)
            }
            if (fixed.album == null && albumTitle.isNotBlank()) {
                fixed = fixed.copy(album = AlbumRef(albumTitle, browseId, kind))
            }
            fixed
        }
        return AlbumDetail(
            title = albumTitle,
            subtitle = subtitle,
            description = description,
            thumbnails = headerThumbs,
            tracks = tracks,
            kind = kind,
            artist = headerArtist,
        )
    }

    /**
     * Opens an artist page with top songs and categorized carousels.
     *
     * @param browseId artist channel browse id (UC…).
     * @return artist detail, or null when the header is missing.
     */
    suspend fun artist(browseId: String): ArtistDetail? {
        val res = post("browse", bodyWith(mapOf("browseId" to browseId)))
        val header = (res.findFirst("musicImmersiveHeaderRenderer")
            ?: res.findFirst("musicVisualHeaderRenderer")) as? JsonObject ?: return null
        val subscribers = res.findFirst("subscriptionButtonRenderer")
            ?.nav("text", "runs").runsText()
            .ifBlank {
                res.findFirst("subscriptionButtonRenderer")
                    ?.nav("longBylineText", "runs").runsText()
            }.orEmpty()
        val topShelf = res.findAll("musicShelfRenderer")
            .mapNotNull { it as? JsonObject }
            .firstOrNull { it.nav("title", "runs").runsText().equals("Top songs", ignoreCase = true) }
            ?: res.findFirst("musicShelfRenderer") as? JsonObject
        val topSongs = (topShelf?.nav("contents") as? JsonArray)?.mapNotNull {
            it.nav("musicResponsiveListItemRenderer")?.let { li -> parseListItem(li) }
        }.orEmpty()
        val songsEndpoint = topShelf?.nav("bottomEndpoint", "browseEndpoint")
        val titleEndpoint = topShelf?.nav("title", "runs")
        val songsPlaylistId = songsEndpoint?.nav("browseId")?.str()
            ?: titleEndpoint?.browseIdFromRuns()
        val songsPlaylistParams = songsEndpoint?.nav("params")?.str()
            ?: titleEndpoint?.browseParamsFromRuns()

        val albums = mutableListOf<ShelfItem.Browse>()
        val singlesAndEps = mutableListOf<ShelfItem.Browse>()
        val relatedPlaylists = mutableListOf<ShelfItem.Browse>()
        val similarArtists = mutableListOf<ShelfItem.Browse>()

        fun carouselItems(shelf: JsonElement): List<ShelfItem.Browse> =
            (shelf.nav("contents") as? JsonArray)?.mapNotNull { element ->
                val item = element.nav("musicTwoRowItemRenderer") ?: return@mapNotNull null
                val endpoint = item.nav("navigationEndpoint", "browseEndpoint")
                val id = endpoint?.nav("browseId")?.str() ?: return@mapNotNull null
                val subtitle = item.nav("subtitle", "runs").runsText()
                ShelfItem.Browse(
                    title = item.nav("title", "runs").runsText(),
                    subtitle = subtitle,
                    browseId = id,
                    thumbnails = item.parseThumbnails(),
                    kind = detectReleaseKind(subtitle),
                    browseParams = endpoint.nav("params")?.str(),
                )
            }.orEmpty()

        for (shelf in res.findAll("musicCarouselShelfRenderer")) {
            val title = shelf.nav("header", "musicCarouselShelfBasicHeaderRenderer", "title", "runs")
                .runsText()
            val items = carouselItems(shelf)
            if (items.isEmpty()) continue
            val tokens = canonicalMetadata(title).split(' ').filter { it.isNotBlank() }.toSet()
            val destination = when {
                "album" in tokens || "albums" in tokens -> albums
                "single" in tokens || "singles" in tokens || "ep" in tokens || "eps" in tokens -> singlesAndEps
                "playlist" in tokens || "playlists" in tokens || "featured" in tokens -> relatedPlaylists
                "fan" in tokens || "fans" in tokens || "similar" in tokens -> similarArtists
                items.any { it.browseId.startsWith("UC") } -> similarArtists
                items.any { it.browseId.startsWith("VL") } -> relatedPlaylists
                else -> albums
            }
            destination.addAll(items)
        }

        return ArtistDetail(
            name = header.nav("title", "runs").runsText(),
            description = header.nav("description", "runs").runsText(),
            thumbnails = header.parseThumbnails(),
            topSongs = topSongs,
            albums = albums.distinctBy { it.browseId },
            singlesAndEps = singlesAndEps.distinctBy { it.browseId },
            relatedPlaylists = relatedPlaylists.distinctBy { it.browseId },
            similarArtists = similarArtists.distinctBy { it.browseId },
            songsPlaylistId = songsPlaylistId,
            songsPlaylistParams = songsPlaylistParams,
            subscribers = subscribers,
        )
    }

    /**
     * Opens a playlist page.
     *
     * @param browseId playlist browse id (PL…/VL…/RD…).
     * @param params optional browse params for continuation pages.
     * @return playlist detail, or null when the track shelf is missing.
     */
    suspend fun playlist(browseId: String, params: String? = null): PlaylistDetail? {
        fun bodyFor(id: String) = bodyWith(buildMap {
            put("browseId", id)
            params?.takeIf { it.isNotBlank() }?.let { put("params", it) }
        })
        // Raw PL ids answer HTTP 400 / an error envelope (not a playlist),
        // while the canonical VL form succeeds — try both, keeping the
        // first non-error response.
        val ids = if (browseId.startsWith("PL")) listOf(browseId, "VL$browseId") else listOf(browseId)
        val res = ids.firstNotNullOfOrNull { id ->
            runCatching { post("browse", bodyFor(id)) }.getOrNull()
                ?.takeIf { attempt -> attempt !is JsonObject || attempt["error"] == null }
        } ?: return null
        val header = (res.findFirst("musicDetailHeaderRenderer")
            ?: res.findFirst("musicEditablePlaylistDetailHeaderRenderer")
            ?: res.findFirst("musicHeaderRenderer")) as? JsonObject
        val shelf = (res.findFirst("musicPlaylistShelfRenderer")
            ?: res.findFirst("musicShelfRenderer")) as? JsonObject ?: return null
        val tracks = (shelf.nav("contents") as? JsonArray)?.mapNotNull {
            (it.nav("musicResponsiveListItemRenderer"))?.let { li -> parseListItem(li) }
        }.orEmpty()
        val micro = res.nav("microformat", "microformatDataRenderer")
        val title = header?.let {
            (it.nav("title", "runs") ?: it.nav("header", "musicDetailHeaderTitleRenderer", "title", "runs"))
                .runsText()
        }.orEmpty().ifBlank {
            micro?.nav("title")?.str().orEmpty()
        }
        val subtitle = header?.nav("subtitle", "runs")?.runsText().orEmpty().ifBlank {
            micro?.nav("description")?.str().orEmpty()
        }
        val thumbnails = header?.parseThumbnails().orEmpty().ifEmpty {
            res.nav("background", "musicThumbnailRenderer")?.parseThumbnails().orEmpty()
        }.ifEmpty {
            micro?.nav("thumbnail")?.parseThumbnails().orEmpty()
        }
        // Playlist headers link the owner channel the same way album
        // headers link the artist; surface it for the author row.
        val author = header?.let {
            channelRefFromRuns(
                it.nav("subtitle", "runs"),
                it.nav("straplineTextOne", "runs"),
                it.nav("straplineTextTwo", "runs"),
                it.nav("secondSubtitle", "runs"),
            )
        }
        return PlaylistDetail(
            title = title,
            subtitle = subtitle,
            thumbnails = thumbnails,
            tracks = tracks,
            author = author,
        )
    }

    /**
     * Resolves just the artwork of a playlist, trying the PL/VL id variants.
     *
     * @param browseId playlist browse id.
     * @param params optional browse params.
     * @return thumbnails, or empty when none resolve.
     */
    suspend fun playlistArtwork(browseId: String, params: String? = null): List<Thumbnail> {
        if (browseId.isBlank()) return emptyList()
        val ids = if (browseId.startsWith("PL")) listOf(browseId, "VL$browseId") else listOf(browseId)
        for (id in ids) {
            val browse = buildMap {
                put("browseId", id)
                params?.takeIf { it.isNotBlank() }?.let { put("params", it) }
            }
            val res = runCatching { post("browse", bodyWith(browse)) }.getOrNull() ?: continue
            val header = (res.findFirst("musicDetailHeaderRenderer")
                ?: res.findFirst("musicEditablePlaylistDetailHeaderRenderer")
                ?: res.findFirst("musicHeaderRenderer")) as? JsonObject
            val micro = res.nav("microformat", "microformatDataRenderer")
            val thumbnails = header?.parseThumbnails().orEmpty().ifEmpty {
                res.nav("background", "musicThumbnailRenderer")?.parseThumbnails().orEmpty()
            }.ifEmpty {
                micro?.nav("thumbnail")?.parseThumbnails().orEmpty()
            }
            if (thumbnails.isNotEmpty()) return thumbnails
        }
        return emptyList()
    }

    // Resolve the release metadata that the Data API omits. The watch-next
    // panel carries the canonical artist/album pair, and the album page adds
    // the release kind (Album/EP/Single/Compilation).
    suspend fun enrichTrack(track: Track): Track {
        var result = track
        // One watch-next call carries the canonical artists/album/artwork
        // AND the like state (player overlay preferred, panel fallback),
        // so a single request fully resolves a track without playing it.
        val res = runCatching { nextResponse(track.videoId) }.getOrNull()
        if (res != null && result.rating == RatingStatus.UNKNOWN) {
            val overlay = res.nav(
                "playerOverlays", "playerOverlayRenderer", "actions", 0,
                "likeButtonRenderer", "likeStatus",
            )?.str()?.let(RatingStatus::fromValue) ?: RatingStatus.UNKNOWN
            val panelRating = panelsOf(res).firstOrNull { it.videoId == track.videoId }?.rating
                ?: RatingStatus.UNKNOWN
            val fetched = if (overlay != RatingStatus.UNKNOWN) overlay else panelRating
            if (fetched != RatingStatus.UNKNOWN) result = result.copy(rating = fetched)
        }
        val panel = res?.let(::panelsOf)?.firstOrNull { it.videoId == track.videoId }
        if (panel != null) {
            val replaceGenericArtist = result.artists.isEmpty() ||
                result.artistNames.trim().equals("Release", ignoreCase = true)
            val existingArtistKeys = result.artists.map { canonicalMetadata(it.name) }.toSet()
            val panelAddsArtist = panel.artists.any {
                canonicalMetadata(it.name) !in existingArtistKeys
            }
            val panelAddsIdentity = panel.artists.any { incoming ->
                val key = canonicalMetadata(incoming.name)
                result.artists.any { existing ->
                    canonicalMetadata(existing.name) == key &&
                        existing.browseId.isNullOrBlank() && !incoming.browseId.isNullOrBlank()
                }
            }
            val panelHasMoreArtists = panel.artists.size > result.artists.size
            val currentAlbum = result.album
            val panelAlbum = panel.album
            val knownArtists = result.artists + panel.artists
            val currentAlbumIsUnlinkedArtist = currentAlbum != null &&
                currentAlbum.browseId.isNullOrBlank() && currentAlbum.kind == null &&
                knownArtists.any {
                    canonicalMetadata(it.name) == canonicalMetadata(currentAlbum.name)
                }
            val preferredAlbum = when {
                currentAlbumIsUnlinkedArtist && panelAlbum == null -> null
                panelAlbum == null -> currentAlbum
                currentAlbum == null -> panelAlbum
                currentAlbum.name.trim().equals("Release", ignoreCase = true) -> panelAlbum
                currentAlbumIsUnlinkedArtist -> panelAlbum
                currentAlbum.browseId == null && panelAlbum.browseId != null -> panelAlbum
                currentAlbum.kind == null && panelAlbum.kind != null -> panelAlbum
                else -> currentAlbum
            }
            val panelAddsValue = replaceGenericArtist || panelHasMoreArtists ||
                panelAddsArtist || panelAddsIdentity
            result = result.copy(
                title = preferredTrackTitle(result.title, panel.title),
                artists = if (panel.artists.isNotEmpty() && panelAddsValue) panel.artists else result.artists,
                album = preferredAlbum,
                thumbnails = (result.thumbnails + panel.thumbnails).distinctBy { it.url },
            )
        }

        val ref = result.album
        val browseId = ref?.browseId
        if (ref != null && browseId != null && ref.kind == null) {
            val detail = albumDetailsCache[browseId] ?: runCatching { album(browseId) }.getOrNull()
            if (detail != null) {
                albumDetailsCache[browseId] = detail
                result = result.copy(
                    album = ref.copy(
                        name = detail.title.ifBlank { ref.name },
                        kind = detail.kind ?: ref.kind,
                    ),
                )
            }
        }
        return result
    }

    // ---------- Up-next / radio continuation ----------

    private suspend fun nextResponse(videoId: String, playlistId: String? = null): JsonElement {
        val extra = mutableMapOf("videoId" to videoId, "queueContext" to "")
        playlistId?.let { extra["playlistId"] = it }
        return post("next", bodyWith(extra))
    }

    private fun panelsOf(res: JsonElement): List<Track> {
        val tabs = res.nav(
            "contents", "singleColumnMusicWatchNextResultsRenderer",
            "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs",
        ) as? JsonArray ?: return emptyList()
        val panels = tabs.firstOrNull()
            ?.nav(
                "tabRenderer", "content", "musicQueueRenderer",
                "content", "playlistPanelRenderer", "contents",
            ) as? JsonArray
            ?: return emptyList()
        return panels.mapNotNull { it.nav("playlistPanelVideoRenderer")?.parsePanelVideo() }
    }

    /**
     * Returns the up-next queue for a video, optionally within a playlist.
     *
     * @param videoId current video id.
     * @param playlistId playlist context, if any.
     * @return up-next tracks.
     */
    suspend fun upNext(videoId: String, playlistId: String? = null): List<Track> =
        panelsOf(nextResponse(videoId, playlistId))

    // Resolves full metadata (artists/album/artwork/like-state) for many
    // tracks concurrently, so lists can display correct data without
    // playing anything first. Order is preserved; failures keep input.
    /**
     * Enriches many tracks concurrently while preserving order.
     *
     * @param tracks tracks to enrich.
     * @param concurrency max parallel watch-next fetches.
     * @return enriched tracks in input order; failures keep the input.
     */
    suspend fun enrichTracks(tracks: List<Track>, concurrency: Int = 8): List<Track> {
        if (tracks.isEmpty()) return tracks
        val enriched = coroutineScope {
            tracks.chunked(concurrency.coerceAtLeast(1)).flatMap { chunk ->
                chunk.map { async { it.videoId to runCatching { enrichTrack(it) }.getOrDefault(it) } }
                    .awaitAll()
            }
        }.toMap()
        return tracks.map { enriched[it.videoId] ?: it }
    }

    /**
     * Reads the like state of a video from the player overlay or queue panel.
     *
     * @param videoId video id to check.
     * @return rating, or [RatingStatus.UNKNOWN] on failure.
     */
    suspend fun rating(videoId: String): RatingStatus {
        if (videoId.isBlank()) return RatingStatus.UNKNOWN
        return try {
            val res = post("next", bodyWith(mapOf("videoId" to videoId, "queueContext" to "")))
            val overlayStatus = res.nav(
                "playerOverlays", "playerOverlayRenderer", "actions", 0,
                "likeButtonRenderer", "likeStatus",
            )?.str()
            if (!overlayStatus.isNullOrBlank()) return RatingStatus.fromValue(overlayStatus)
            res.findAll("playlistPanelVideoRenderer")
                .asSequence()
                .mapNotNull { it.parsePanelVideo() }
                .firstOrNull { it.videoId == videoId }
                ?.rating
                ?: RatingStatus.UNKNOWN
        } catch (_: Exception) {
            RatingStatus.UNKNOWN
        }
    }

    /**
     * Reads like states for many videos concurrently, skipping unknown ones.
     *
     * @param videoIds video ids to check.
     * @param concurrency max parallel fetches.
     * @return video id to known rating map.
     */
    suspend fun ratings(videoIds: List<String>, concurrency: Int = 8): Map<String, RatingStatus> {
        val ids = videoIds.asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .toList()
        if (ids.isEmpty()) return emptyMap()
        val out = linkedMapOf<String, RatingStatus>()
        ids.chunked(concurrency.coerceAtLeast(1)).forEach { chunk ->
            val values = coroutineScope {
                chunk.map { id -> async { id to rating(id) } }.awaitAll()
            }
            values.forEach { (id, status) ->
                if (status != RatingStatus.UNKNOWN) out[id] = status
            }
        }
        return out
    }

    /**
     * Sets the like state of a video.
     *
     * @param videoId video id to rate.
     * @param rating target rating; [RatingStatus.UNKNOWN] is rejected.
     * @return true when the endpoint accepts the change.
     */
    suspend fun rate(videoId: String, rating: RatingStatus): Boolean {
        if (videoId.isBlank() || rating == RatingStatus.UNKNOWN) return false
        val endpoint = when (rating) {
            RatingStatus.LIKE -> "like/like"
            RatingStatus.DISLIKE -> "like/dislike"
            RatingStatus.INDIFFERENT -> "like/removelike"
            RatingStatus.UNKNOWN -> return false
        }
        return try {
            val body = buildJsonObject {
                put("context", contextBlock().jsonObject.getValue("context"))
                put("target", buildJsonObject { put("videoId", videoId) })
            }
            val response = post(endpoint, body)
            (response as? JsonObject)?.get("error") == null
        } catch (_: Exception) {
            false
        }
    }

    // Report playback events to YouTube's feedback pipeline so that
    // listening history feeds into the user's recaps (Year in Review,
    // Most Listened To, etc.). Uses the same authenticated session as
    // the rate endpoint. Events are acknowledged with HTTP 200 on success.
    suspend fun feedback(videoId: String, type: String, currentTimeMs: Long, cpn: String = ""): Boolean {
        if (videoId.isBlank()) return false
        val body = buildJsonObject {
            put("context", contextBlock().jsonObject.getValue("context"))
            put("actions", buildJsonArray {
                add(buildJsonObject {
                    put("action", "playerEvent")
                    put("playerEvent", buildJsonObject {
                        put("videoId", videoId)
                        put("currentTime", currentTimeMs)
                        put("type", type)
                        if (cpn.isNotBlank()) put("cpn", cpn)
                    })
                })
            })
        }
        return try {
            val response = post("feedback", body)
            (response as? JsonObject)?.get("error") == null
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Per-playback watchtime session tokens from the InnerTube player response.
     *
     * `ei`/`plid`/`of`/`vm` are minted fresh for EVERY player call, so they
     * must be fetched once per track playback (keyed by cpn) and reused for
     * that track's heartbeats — never shared across plays. Verified against
     * the real YTM web client: beacons built from these tokens land in
     * `FEmusic_history`; hand-built URLs without them 204 but never record.
     *
     * @property ei session event id from the playbackTracking base URL.
     * @property plid session playlist id from the playbackTracking base URL.
     * @property of opaque session token from the playbackTracking base URL.
     * @property vm opaque session token from the playbackTracking base URL.
     * @property lenSec track length in seconds from videoDetails.
     * @property ptrackingUrl ptracking base URL, fired once per playback.
     */
    data class WatchtimeContext(
        val ei: String,
        val plid: String,
        val of: String,
        val vm: String,
        val lenSec: Double,
        val ptrackingUrl: String?,
    )

    /** Per-cpn watchtime contexts (one entry per track playback, bounded). */
    private val watchtimeContexts = ConcurrentHashMap<String, WatchtimeContext>()

    /** Wall-clock start per cpn, for the `lact` beacon param. */
    private val watchtimeStartMs = ConcurrentHashMap<String, Long>()

    /** Last `rtn` counter per cpn (`rti` chains the previous value). */
    private val watchtimeLastRtn = ConcurrentHashMap<String, Int>()

    /**
     * Fetches fresh watchtime session tokens for [videoId] via the player endpoint.
     *
     * Needs `racyCheckOk`/`contentCheckOk` or the endpoint answers 400.
     *
     * @param videoId video id to open the player for.
     * @return session tokens, or null when the player call fails.
     */
    suspend fun watchtimeContext(videoId: String): WatchtimeContext? {
        if (videoId.isBlank()) return null
        return try {
            val body = buildJsonObject {
                put("context", contextBlock().jsonObject.getValue("context"))
                put("videoId", videoId)
                put("playbackContext", buildJsonObject {
                    put("contentPlaybackContext", buildJsonObject {
                        put("html5Preference", "HTML5_PREF_WANTS")
                    })
                })
                put("racyCheckOk", true)
                put("contentCheckOk", true)
            }
            val res = post("player", body)
            if (res is JsonObject && res["error"] != null) return null
            val base = res.nav("playbackTracking", "videostatsWatchtimeUrl", "baseUrl")
                ?.str().orEmpty()
            val query = base.substringAfter("?", "").split("&").mapNotNull { part ->
                val i = part.indexOf("=")
                if (i < 0) null else part.substring(0, i) to part.substring(i + 1)
            }.toMap()
            val ei = query["ei"].orEmpty()
            val plid = query["plid"].orEmpty()
            if (ei.isBlank() || plid.isBlank()) return null
            val len = res.nav("videoDetails", "lengthSeconds")?.str()?.toDoubleOrNull()
                ?: query["len"]?.toDoubleOrNull() ?: 0.0
            WatchtimeContext(
                ei = ei,
                plid = plid,
                of = query["of"].orEmpty(),
                vm = query["vm"].orEmpty(),
                lenSec = len,
                ptrackingUrl = res.nav("playbackTracking", "ptrackingUrl", "baseUrl")?.str(),
            )
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Reports playback to YouTube's watchtime endpoints so history/recaps record the listen.
     *
     * Mirrors the real YTM web client (captured 2026-09-27): for new tracks
     * (`startSec == 0.0`) fires the `ptracking` pixel, then a `stats/playback`
     * POST to create the watch record, then `stats/watchtime` POST heartbeats;
     * every stats POST carries `{"session_token": <XSRF_TOKEN>}` as a JSON
     * body plus the player-minted `ei`/`plid`/`of`/`vm` session params. A
     * `feedback` POST with a playerEvent is also sent — it returns structured
     * JSON, giving a real success/failure signal, since the beacons answer
     * HTTP 204 (blind ack) for all well-formed requests.
     *
     * End-to-end verified: this sequence lands in `FEmusic_history` within
     * ~2 minutes; the previous hand-built URLs (form-encoded token, no
     * session params) never did.
     *
     * @param videoId played video id.
     * @param cpn client playback nonce, stable for one track playback.
     * @param startSec watched segment start in seconds.
     * @param currentSec watched segment end in seconds.
     * @param state player state label.
     * @param durationSec track duration in seconds (for the `len` param).
     * @param playlistId playlist context the track plays from, if any.
     * @return true when either the beacon or the feedback POST succeeds.
     */
    suspend fun reportWatchtime(
        videoId: String,
        cpn: String,
        startSec: Double,
        currentSec: Double,
        state: String,
        durationSec: Double = 0.0,
        playlistId: String? = null,
    ): Boolean {
        if (videoId.isBlank() || cpn.isBlank()) return false
        // The XSRF token is the auth that makes beacons record history.
        // Refresh it lazily on first use after launch/login.
        var token = auth.sessionToken
        if (token.isNullOrBlank()) {
            token = runCatching { fetchSessionToken() }.getOrNull()
            if (!token.isNullOrBlank()) auth = auth.copy(sessionToken = token)
        }
        val referer = "https://music.youtube.com/watch?v=$videoId"
        // Per-playback session tokens: fetched once per cpn, reused for the
        // track's heartbeats. A later heartbeat retries the fetch when the
        // first attempt failed transiently.
        val ctx = watchtimeContexts[cpn]
            ?: runCatching { watchtimeContext(videoId) }.getOrNull()?.also { fresh ->
                if (watchtimeContexts.size > WATCHTIME_CONTEXT_CACHE_SIZE) {
                    watchtimeContexts.keys.firstOrNull()?.let { old ->
                        watchtimeContexts.remove(old)
                        watchtimeStartMs.remove(old)
                        watchtimeLastRtn.remove(old)
                    }
                }
                watchtimeContexts[cpn] = fresh
            }
        val nowMs = System.currentTimeMillis()
        val startMs = watchtimeStartMs.getOrPut(cpn) { nowMs }
        val lactMs = (nowMs - startMs).coerceAtLeast(0L)
        val rtn = (watchtimeLastRtn[cpn] ?: WATCHTIME_INITIAL_RTN) + WATCHTIME_RTN_STEP
        val rti = rtn - 10
        watchtimeLastRtn[cpn] = rtn
        // stats/playback creates the watch record that stats/watchtime
        // then updates. Fires only for new tracks (startSec == 0.0) so we
        // don't spam playback-record creation on every heartbeat.
        if (state == "playing" && startSec == 0.0 && ctx != null) {
            ctx.ptrackingUrl?.takeIf { it.isNotBlank() }?.let { ptracking ->
                runCatching { getBeacon(ptracking, referer) }
            }
            runCatching {
                postBeacon(playbackUrl(ctx, videoId, cpn, currentSec, durationSec, playlistId, lactMs), referer, token)
            }
        }
        val beaconOk = if (ctx != null) {
            val url = watchtimeUrl(
                ctx, videoId, cpn, startSec, currentSec, state,
                durationSec, playlistId, lactMs, rtn, rti,
                final = state == "paused",
            )
            runCatching { postBeacon(url, referer, token) }.getOrDefault(-1) in 200..299
        } else {
            false
        }
        // The stats/watchtime beacon returns 204 (blind ack) for all
        // well-formed requests, so always also fire a feedback playerEvent
        // — the InnerTube POST returns a structured response, giving us a
        // real success/failure signal.
        val eventType = when {
            state == "playing" && startSec == 0.0 -> "playerPlay"
            state == "paused" -> "playerPause"
            else -> "progressHeartbeat"
        }
        val fb = feedback(videoId, eventType, (currentSec * 1000).toLong(), cpn)
        return beaconOk || fb
    }

    /** Formats seconds for beacon params, clamping negatives to zero. */
    private fun fmtSec(v: Double): String = "%.3f".format(java.util.Locale.US, v.coerceAtLeast(0.0))

    /** Builds a `stats/playback` URL in the real web client's shape. */
    private fun playbackUrl(
        ctx: WatchtimeContext,
        videoId: String,
        cpn: String,
        currentSec: Double,
        durationSec: Double,
        playlistId: String?,
        lactMs: Long,
    ): String {
        val len = if (durationSec > 0.0) durationSec else ctx.lenSec
        return buildString {
            append("https://music.youtube.com/api/stats/playback")
            append("?ns=yt&el=detailpage&cpn=").append(cpn)
            append("&ver=2&cmt=").append(fmtSec(currentSec))
            append("&fmt=0&fs=0&rt=").append(fmtSec(currentSec + RT_OFFSET_SEC))
            append("&euri&lact=").append(lactMs)
            append("&cl=").append(CL)
            append("&mos=0&volume=100")
            append("&cbr=Chrome&cbrver=").append(BEACON_CBRVER)
            append("&c=WEB_REMIX&cver=").append(currentClientVersion())
            append("&cplayer=UNIPLAYER&cos=X11&cplatform=DESKTOP")
            append("&hl=en_US&cr=US&uga=m18")
            append("&len=").append(fmtSec(len))
            appendBeaconTail(this, ctx, videoId, playlistId)
        }
    }

    /** Builds a `stats/watchtime` URL in the real web client's shape. */
    private fun watchtimeUrl(
        ctx: WatchtimeContext,
        videoId: String,
        cpn: String,
        startSec: Double,
        currentSec: Double,
        state: String,
        durationSec: Double,
        playlistId: String?,
        lactMs: Long,
        rtn: Int,
        rti: Int,
        final: Boolean,
    ): String {
        val len = if (durationSec > 0.0) durationSec else ctx.lenSec
        return buildString {
            append("https://music.youtube.com/api/stats/watchtime")
            append("?ns=yt&el=detailpage&cpn=").append(cpn)
            append("&ver=2&cmt=").append(fmtSec(currentSec))
            append("&fmt=0&fs=0&rt=").append(fmtSec(currentSec + RT_OFFSET_SEC))
            append("&euri&lact=").append(lactMs)
            append("&cl=").append(CL)
            append("&state=").append(state)
            append("&volume=100")
            append("&cbr=Chrome&cbrver=").append(BEACON_CBRVER)
            append("&c=WEB_REMIX&cver=").append(currentClientVersion())
            append("&cplayer=UNIPLAYER&cos=X11&cplatform=DESKTOP")
            append("&hl=en_US&cr=US&uga=m18")
            append("&len=").append(fmtSec(len))
            append("&rtn=").append(rtn).append("&afmt=251&idpj=-8&ldpj=-16&rti=").append(rti)
            append("&st=").append(fmtSec(startSec)).append("&et=").append(fmtSec(currentSec))
            append("&muted=0&vis=10")
            appendBeaconTail(this, ctx, videoId, playlistId)
            // final=1 on pause signals end-of-session so YT finalises the watch record.
            if (final) append("&final=1")
        }
    }

    /** Appends the identity/session tail (`docid`, `ei`, `plid`, `referrer`, `of`, `vm`). */
    private fun appendBeaconTail(
        out: StringBuilder,
        ctx: WatchtimeContext,
        videoId: String,
        playlistId: String?,
    ) {
        out.append("&docid=").append(videoId)
        out.append("&ei=").append(ctx.ei)
        out.append("&plid=").append(ctx.plid)
        if (!playlistId.isNullOrBlank()) {
            out.append("&referrer=")
                .append(URLEncoder.encode("https://music.youtube.com/playlist?list=$playlistId", "UTF-8"))
            out.append("&list=").append(playlistId)
        } else {
            out.append("&referrer=")
                .append(URLEncoder.encode("https://music.youtube.com/watch?v=$videoId", "UTF-8"))
        }
        out.append("&of=").append(ctx.of)
        out.append("&vm=").append(ctx.vm)
    }

    /**
     * Fetches the XSRF-TOKEN from the music.youtube.com page HTML and returns
     * it. The YTM web client extracts this token from `yt.config_.XSRF_TOKEN`
     * during page load and sends it as JSON `{"session_token": <value>}` in
     * the body of every stats/ endpoint POST beacon. Without it the beacons
     * 204 (blind ack) but plays are never recorded in listening history — the
     * SAPISIDHASH Authorization header alone does NOT cause plays to appear.
     */
    suspend fun fetchSessionToken(): String? {
        val cookie = auth.cookie ?: return null
        return try {
            val html = client.get("https://music.youtube.com") {
                header(HttpHeaders.UserAgent, USER_AGENT)
                header(HttpHeaders.Cookie, cookie)
                header("Accept-Language", "en-US,en;q=0.5")
            }.bodyAsText()
            // The token appears as "XSRF_TOKEN":"<value>" in a <script> tag.
            Regex("""["']XSRF_TOKEN["'\s]*:\s*["']([^"']+)["']""").find(html)
                ?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }

    // Authenticated beacons for stats/* endpoints. The YTM web client sends
    // stats/playback and stats/watchtime as POST with JSON
    // `{"session_token": <XSRF_TOKEN>}` in the body — that, together with
    // the player-minted ei/plid/of/vm session params, is what causes plays
    // to be recorded in listening history. A form-encoded body or missing
    // session params 204 (blind ack) but silently record nothing.
    //
    // When sessionToken is present (cookie session), postBeacon() sends POST
    // with the token as JSON. When it is absent (Bearer-only/OAuth
    // sessions, or token extraction failed), postBeacon() falls back to GET
    // with the SAPISIDHASH/Bearer header — 204s but may not record history.
    //
    // Key insight: stats/* beacons return 204 as a *blind ack* for ALL
    // well-formed requests — even anonymous ones. The server does not tell
    // us whether the watch record was actually created. We MUST try every
    // available auth candidate, not short-circuit on the first 204.
    //
    // Candidate order (best → fallback):
    // 1. Cookie + SAPISIDHASH  (standard web-client auth; records history
    //    when LOGIN_INFO is valid and session_token is sent)
    // 2. Cookie + Bearer       (combined — server picks whichever auth it
    //    accepts; covers the case where SAPISIDHASH is rejected but the
    //    cookie's LOGIN_INFO is still valid)
    // 3. Bearer only           (TV-device OAuth; 204 but may not record)
    private suspend fun postBeacon(url: String, referer: String, sessionToken: String?): Int {
        val session = try {
            authProvider?.invoke()
        } catch (_: Exception) {
            null
        } ?: auth

        val cookieAuth = auth
        val bearerAuth = session

        val candidates = mutableListOf<AuthSession>()

        // 1. Cookie + SAPISIDHASH (primary: web-client auth pattern)
        if (!cookieAuth.cookie.isNullOrBlank()) {
            candidates += cookieAuth
        }
        // 2. Combined: Cookie + Bearer (no SAPISIDHASH — let server choose)
        if (cookieAuth !== bearerAuth &&
            !cookieAuth.cookie.isNullOrBlank() && !bearerAuth.accessToken.isNullOrBlank()
        ) {
            candidates += AuthSession(cookie = cookieAuth.cookie, accessToken = bearerAuth.accessToken)
        }
        // 3. Bearer only (fallback — e.g. OAuth-only users)
        if (cookieAuth !== bearerAuth &&
            bearerAuth.cookie.isNullOrBlank() && !bearerAuth.accessToken.isNullOrBlank()
        ) {
            candidates += bearerAuth
        }

        var lastStatus = -1
        for (candidate in candidates) {
            try {
                val status = if (!sessionToken.isNullOrBlank()) {
                    // YTM web client: POST to stats/* with the session
                    // token as a JSON body.
                    val safeToken = sessionToken
                        .replace("\\", "\\\\")
                        .replace("\"", "\\\"")
                    client.post(url) {
                        header(HttpHeaders.UserAgent, BEACON_UA)
                        header(HttpHeaders.Origin, "https://music.youtube.com")
                        header("Referer", referer)
                        contentType(ContentType.Application.Json)
                        candidate.cookie?.let { header(HttpHeaders.Cookie, it) }
                        candidate.sapisidHash?.let {
                            header(HttpHeaders.Authorization, "SAPISIDHASH $it")
                        } ?: candidate.accessToken?.let {
                            header(HttpHeaders.Authorization, "Bearer $it")
                        }
                        setBody("{\"session_token\":\"$safeToken\"}")
                    }.status.value
                } else {
                    // Fallback: GET with SAPISIDHASH/Bearer header (204s but
                    // may not record history without session_token).
                    client.get(url) {
                        header(HttpHeaders.UserAgent, BEACON_UA)
                        header(HttpHeaders.Origin, "https://music.youtube.com")
                        header("Referer", referer)
                        candidate.cookie?.let { header(HttpHeaders.Cookie, it) }
                        candidate.sapisidHash?.let {
                            header(HttpHeaders.Authorization, "SAPISIDHASH $it")
                        } ?: candidate.accessToken?.let {
                            header(HttpHeaders.Authorization, "Bearer $it")
                        }
                    }.status.value
                }
                if (status in 200..299) lastStatus = status
                // DO NOT return on first 204 — it's a blind ack.
                // Try ALL candidates so that a valid cookie session is
                // always exercised even when Bearer succeeds first.
            } catch (_: Exception) {
            }
        }
        return lastStatus
    }

    // Authenticated GET pixel (ptracking). Best-effort: ignores status.
    private suspend fun getBeacon(url: String, referer: String) {
        val session = try {
            authProvider?.invoke()
        } catch (_: Exception) {
            null
        } ?: auth
        val candidates = listOf(auth, session).distinct()
            .filter { !it.cookie.isNullOrBlank() || !it.accessToken.isNullOrBlank() }
        for (candidate in candidates) {
            try {
                client.get(url) {
                    header(HttpHeaders.UserAgent, BEACON_UA)
                    header(HttpHeaders.Origin, "https://music.youtube.com")
                    header("Referer", referer)
                    candidate.cookie?.let { header(HttpHeaders.Cookie, it) }
                    candidate.sapisidHash?.let {
                        header(HttpHeaders.Authorization, "SAPISIDHASH $it")
                    } ?: candidate.accessToken?.let {
                        header(HttpHeaders.Authorization, "Bearer $it")
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun JsonElement.parsePanelVideo(): Track? {
        val title = nav("title", "runs").runsText()
        val videoId = nav("navigationEndpoint", "watchEndpoint", "videoId")?.str() ?: return null
        val byline = (nav("longBylineText", "runs") as? JsonArray)
            ?: (nav("shortBylineText", "runs") as? JsonArray)
            ?: JsonArray(emptyList())
        val artists = mutableListOf<ArtistRef>()
        var album: AlbumRef? = null
        for (run in byline) {
            val text = run.nav("text")?.str()?.trim().orEmpty()
            if (text.isBlank() || text == "•") continue
            val id = run.nav("navigationEndpoint", "browseEndpoint", "browseId")?.str()
            when {
                id?.startsWith("UC") == true -> artists += ArtistRef(text, id)
                id?.startsWith("MPRE") == true ->
                    album = AlbumRef(text, id, detectReleaseKind(text))
            }
        }

        val bylinePieces = byline.joinToString(" ") { it.nav("text")?.str().orEmpty() }
            .split(Regex("\\s*[•·]\\s*"))
            .map { it.trim() }
            .filter { it.isNotBlank() }
        if (artists.isEmpty()) {
            // Without artist endpoints, the first meaningful byline part is
            // the artist. Only then can a following part safely be treated as
            // an album; once endpoint-backed artists exist, a plain part is
            // much more likely to be a secondary artist.
            val plain = bylinePieces.filter { !isBylineNoise(it) }
            plain.firstOrNull()?.let { artists += ArtistRef(it) }
            if (album == null) {
                plain.asSequence()
                    .drop(1)
                    .firstOrNull { canonicalMetadata(it) != canonicalMetadata(title) }
                    ?.let { album = AlbumRef(it, null, detectReleaseKind(it)) }
            }
        }

        val duration = nav("lengthText", "runs").runsText().toDurationSec()
            .takeIf { it > 0 } ?: nav("lengthText", "simpleText")?.str()?.toDurationSec() ?: 0
        val rating = parseLikeRating(this)
        return Track(
            videoId = videoId,
            title = title,
            artists = artists.distinctBy { it.name },
            album = album,
            durationSec = duration,
            thumbnails = parseThumbnails(),
            radioPlaylistId = "RDAMVM$videoId",
            artistId = artists.firstOrNull { it.browseId?.startsWith("UC") == true }?.browseId,
            rating = rating,
        )
    }

    // ---------- Auth check ----------

    // True when the current session can actually read the library
    // (stronger than account_menu, which is finicky about auth shape).
    suspend fun verifyLogin(debug: AuthDebug = AuthDebug()): Boolean {
        return try {
            val res = post("browse", bodyWith(mapOf("browseId" to "FEmusic_library_landing")))
            if ((res as? JsonObject)?.containsKey("error") == true) {
                debug.log("library: top-level error: ${res.toString().take(200)}")
                return false
            }
            val blocks = res.findAll("musicShelfRenderer").size +
                res.findAll("musicCarouselShelfRenderer").size +
                res.findAll("gridRenderer").size
            debug.log("library: content blocks=$blocks")
            blocks > 0
        } catch (e: Exception) {
            debug.log("library: exception ${e.message?.take(200)}")
            false
        }
    }

    /** File-backed debug log sink for auth verification diagnostics. */
    class AuthDebug {
        /** Backing log file for auth diagnostics. */
        private val file = java.io.File("/tmp/nixietube-auth-debug.log")
    /**
     * Appends a timestamped line to the auth debug log.
     *
     * @param line message to log.
     */
    fun log(line: String) {
            try {
                file.appendText(java.time.Instant.now().toString() + " " + line + "\n")
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Returns the signed-in account name, or null when anonymous or failing.
     *
     * @return account name, or null.
     */
    suspend fun accountName(): String? {
        if (auth == AuthSession.Anonymous) return null
        return try {
            val res = post("account/account_menu", contextBlock())
            res.findAll("accountName")
                .mapNotNull { it.nav("runs").runsText().takeIf { t -> t.isNotBlank() } }
                .firstOrNull()
                ?: res.findAll("accountName").mapNotNull { it.nav("simpleText")?.str() }.firstOrNull()
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        /** API key bundled with the WEB_REMIX client shape. */
        const val API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        /** Client ID the real YTM web client uses in stats beacon URLs. */
        const val CL = "985604239"
        const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"
        /** Browser UA for stats beacons, matching the captured web client. */
        const val BEACON_UA =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
        /** Browser version label for the cbrver beacon param. */
        const val BEACON_CBRVER = "153.0.0.0"
        /** Fixed plausible offset between cmt and the rt beacon param. */
        const val RT_OFFSET_SEC = 25.529
    }
}

/**
 * Auth credentials for InnerTube requests.
 *
 * @property cookie Cookie header value for cookie sessions.
 * @property sapisidHash SAPISIDHASH Authorization value derived from the cookie.
 * @property accessToken OAuth bearer token, if any.
 * @property sessionToken XSRF-TOKEN extracted from the music.youtube.com page
 *   HTML, sent as `session_token=<value>` in the body of stats/ POST beacons.
 *   This is the auth token the real YTM web client uses to record listening
 *   history; the SAPISIDHASH Authorization header alone does NOT cause plays to
 *   appear in YouTube Music's history.
 */
data class AuthSession(
    val cookie: String? = null,
    val sapisidHash: String? = null,
    val accessToken: String? = null,
    val sessionToken: String? = null,
) {
    companion object {
        val Anonymous = AuthSession()

        // Derive the SAPISIDHASH Authorization value from a pasted Cookie
        // header, so users only copy ONE field from DevTools:
        // "<timestamp>_<sha1(timestamp + ' ' + SAPISID + ' ' + origin)>".
        // Prefers __Secure-3PAPISID (what YouTube checks over HTTPS),
        // falls back to plain SAPISID.
        /**
         * Derives a cookie session (with SAPISIDHASH) from a pasted Cookie header.
         *
         * @param rawCookie raw Cookie header value from DevTools.
         * @param origin origin used in the SAPISIDHASH digest.
         * @return session, or null when no SAPISID value is present.
         */
        fun fromCookie(rawCookie: String, origin: String = "https://music.youtube.com"): AuthSession? {
            // DevTools "pretty" headers view wraps/truncates long values —
            // normalize whitespace (a Cookie header never contains any).
            val cookie = rawCookie.replace(Regex("\\s+"), "")
            val sapisid = Regex("""__Secure-3PAPISID=([^;]+)""").find(cookie)?.groupValues?.get(1)
                ?: Regex("""(?:^|;)SAPISID=([^;]+)""").find(cookie)?.groupValues?.get(1)
                ?: return null
            val clean = sapisid.trim().trim('"')
            if (clean.isEmpty()) return null
            val timestamp = System.currentTimeMillis() / 1000
            val digest = java.security.MessageDigest.getInstance("SHA-1")
            // NB: mask bytes — "%02x".format(byte) sign-extends negatives.
            val hash = digest.digest("$timestamp $clean $origin".toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
            return AuthSession(cookie.trim(), "${timestamp}_${hash}")
        }
    }
}

// ---------- JSON navigation helpers ----------

internal fun JsonElement.nav(vararg keys: Any): JsonElement? {
    var cur: JsonElement? = this
    for (key in keys) {
        cur = when (key) {
            is String -> (cur as? JsonObject)?.get(key)
            is Int -> (cur as? JsonArray)?.getOrNull(key)
            else -> null
        }
        if (cur == null) return null
    }
    return cur
}

internal fun JsonElement?.str(): String? =
    (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

internal fun JsonElement?.runsText(): String {
    val runs = (this as? JsonArray) ?: return ""
    return runs.joinToString("") { (it as? JsonObject)?.get("text")?.str().orEmpty() }
}

internal fun JsonElement.findAll(key: String): List<JsonElement> {
    val out = mutableListOf<JsonElement>()
    fun visit(el: JsonElement) {
        when (el) {
            is JsonObject -> el.entries.forEach { (k, v) ->
                if (k == key) out.add(v)
                visit(v)
            }
            is JsonArray -> el.forEach { visit(it) }
            else -> Unit
        }
    }
    visit(this)
    return out
}

internal fun JsonElement.findFirst(key: String): JsonElement? = findAll(key).firstOrNull()

internal fun JsonArray.parseThumbnailList(): List<Thumbnail> = mapNotNull {
    val url = it.nav("url")?.str() ?: return@mapNotNull null
    Thumbnail(url, it.nav("width")?.intOrNull() ?: 0, it.nav("height")?.intOrNull() ?: 0)
}

internal fun JsonElement.parseThumbnails(): List<Thumbnail> {
    val arr = (findFirst("thumbnails") as? JsonArray) ?: return emptyList()
    return arr.parseThumbnailList()
}

internal fun JsonElement?.intOrNull(): Int? =
    (this as? JsonPrimitive)?.intOrNull

internal fun String.toDurationSec(): Int {
    val parts = split(":").mapNotNull { it.toIntOrNull() }
    if (parts.isEmpty()) return 0
    return parts.fold(0) { acc, p -> acc * 60 + p }
}

private fun parseLikeRating(item: JsonElement): RatingStatus {
    item.nav("menu", "menuRenderer", "topLevelButtons", 0, "likeButtonRenderer", "likeStatus")
        ?.str()
        ?.let { return RatingStatus.fromValue(it) }
    val menuItems = item.nav("menu", "menuRenderer", "items") as? JsonArray ?: return RatingStatus.UNKNOWN
    for (entry in menuItems) {
        val toggle = entry.nav("toggleMenuServiceItemRenderer")
        val service = toggle?.nav("defaultServiceEndpoint")
            ?: entry.nav("menuServiceItemRenderer", "serviceEndpoint")
        val status = service?.nav("likeEndpoint", "status")?.str()
        if (!status.isNullOrBlank()) return RatingStatus.fromValue(status)
    }
    return RatingStatus.UNKNOWN
}

internal fun parseListItem(li: JsonElement): Track? {
    val flex = li.nav("flexColumns") as? JsonArray ?: return null
    val cols = flex.mapNotNull {
        it.nav("musicResponsiveListItemFlexColumnRenderer", "text", "runs") as? JsonArray
    }
    if (cols.isEmpty()) return null
    val titleRuns = cols[0]
    val title = titleRuns.runsText()
    var videoId = titleRuns.firstVideoId()
    var playlistId: String? = null
    var radioId: String? = null
    if (videoId == null) {
        val watch = li.nav("navigationEndpoint", "watchEndpoint")
        videoId = watch?.nav("videoId")?.str()
        playlistId = watch?.nav("playlistId")?.str()
    }
    if (videoId == null) return null
    radioId = "RDAMVM$videoId"
    val artists = mutableListOf<ArtistRef>()
    val plainGroups = mutableListOf<String>()
    var plainGroup = StringBuilder()
    var album: AlbumRef? = null
    var duration = 0
    var views = ""

    fun flushPlainGroup() {
        val value = plainGroup.toString().trim()
        if (value.isNotBlank()) plainGroups += value
        plainGroup = StringBuilder()
    }

    // Pre-scan: which bullet-separated segments carry artist/album
    // endpoints? A plain run sitting in a segment with a channel endpoint
    // (e.g. "Camo & Krooked" between two linked artists) is an unlinked
    // artist credit, not release text. A plain run next to a release
    // endpoint (or with none around) keeps the old treatment.
    val segmentHasArtist = mutableListOf(false)
    val segmentHasRelease = mutableListOf(false)
    for (col in cols.drop(1)) {
        for (run in col) {
            val text = run.nav("text")?.str()?.trim().orEmpty()
            if (text == "•" || text == "·") {
                segmentHasArtist.add(false)
                segmentHasRelease.add(false)
                continue
            }
            val bid = run.nav("navigationEndpoint", "browseEndpoint", "browseId")?.str()
            if (bid?.startsWith("UC") == true) segmentHasArtist[segmentHasArtist.lastIndex] = true
            if (bid?.startsWith("MPRE") == true) segmentHasRelease[segmentHasRelease.lastIndex] = true
        }
    }
    var segmentIdx = 0

    for (col in cols.drop(1)) {
        for (run in col) {
            val text = run.nav("text")?.str()?.trim().orEmpty()
            if (text.isBlank()) continue
            if (text == "•" || text == "·") {
                flushPlainGroup()
                segmentIdx++
                continue
            }
            if (views.isEmpty() && VIEWS_RE.containsMatchIn(text)) {
                views = text
                continue
            }
            if (text.matches(DURATION_RE)) {
                duration = text.toDurationSec()
                continue
            }
            val browseId = run.nav("navigationEndpoint", "browseEndpoint", "browseId")?.str()
            when {
                browseId?.startsWith("UC") == true -> {
                    flushPlainGroup()
                    artists.add(ArtistRef(text, browseId))
                }
                browseId?.startsWith("MPRE") == true -> {
                    flushPlainGroup()
                    album = AlbumRef(text, browseId, detectReleaseKind(text))
                }
                browseId == null && !isBylineNoise(text) && !SKIP_WORDS_RE.containsMatchIn(text) -> {
                    val inArtistZone = segmentIdx < segmentHasArtist.size &&
                        segmentHasArtist[segmentIdx] &&
                        !(segmentIdx < segmentHasRelease.size && segmentHasRelease[segmentIdx])
                    val credit = text
                        .replace(Regex("""(?i)^(feat\.?|ft\.?|featuring)\s+"""), "")
                        .trim().trimEnd(',', ';', ':')
                    val isArtistCredit = inArtistZone && credit.isNotBlank() && !isBylineNoise(credit) &&
                        !isCreditConjunction(credit)
                    if (isArtistCredit) {
                        artists.add(ArtistRef(credit))
                    } else {
                        // Runs before the first bullet form one artist credit;
                        // runs after a bullet are a separate release field. This
                        // prevents "A & B • Album" from turning B into Album.
                        if (plainGroup.isNotEmpty()) plainGroup.append(' ')
                        plainGroup.append(text)
                    }
                }
            }
        }
    }
    flushPlainGroup()
    if (artists.isEmpty()) {
        // Only infer a plain-text album when the row has no endpoint-backed
        // artist at all. If one artist has a browse endpoint, an unlinked
        // part is commonly a second/featured artist, not the release title.
        plainGroups.firstOrNull()?.let { artists.add(ArtistRef(it)) }
        if (album == null) {
            plainGroups.asSequence()
                .drop(1)
                .firstOrNull { canonicalMetadata(it) != canonicalMetadata(title) }
                ?.let { album = AlbumRef(it, null, detectReleaseKind(it)) }
        }
    }
    val rating = parseLikeRating(li)
    return Track(
        videoId = videoId,
        title = title,
        artists = artists.distinctBy { it.name },
        album = album,
        durationSec = duration,
        thumbnails = li.parseThumbnails(),
        playlistId = playlistId,
        radioPlaylistId = radioId,
        artistId = artists.firstOrNull { it.browseId?.startsWith("UC") == true }?.browseId,
        views = views,
        rating = rating,
    )
}

private fun canonicalMetadata(value: String): String =
    value.lowercase()
        .replace(Regex("[^a-z0-9]+"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

private val FEATURE_CREDIT_RE =
    Regex("""(?i)(?:\(|\[|\b)(?:feat\.?|ft\.?|featuring|w/)\s+[^)\]]+(?:\)|\])?""")

private val FEATURE_SEGMENT_RE =
    Regex("""(?i)\s*[\(\[]?(?:feat\.?|ft\.?|featuring|w/)\s+[^)\]]+[\)\]]?""")

private fun hasFeaturedCredit(value: String): Boolean =
    FEATURE_CREDIT_RE.containsMatchIn(value)

private fun preferredTrackTitle(current: String, candidate: String): String {
    val oldTitle = current.trim()
    val newTitle = candidate.trim()
    if (newTitle.isBlank()) return oldTitle
    if (oldTitle.isBlank()) return newTitle
    val oldHasFeature = hasFeaturedCredit(oldTitle)
    val newHasFeature = hasFeaturedCredit(newTitle)
    if (newHasFeature && !oldHasFeature) return newTitle
    if (newHasFeature && oldHasFeature &&
        canonicalMetadata(oldTitle.replace(FEATURE_SEGMENT_RE, "")) ==
        canonicalMetadata(newTitle.replace(FEATURE_SEGMENT_RE, ""))
    ) {
        return newTitle
    }
    return oldTitle
}

private fun isBylineNoise(value: String): Boolean {
    val v = canonicalMetadata(value)
    return v in setOf(
        "", "and", "feat", "ft", "with", "music", "audio", "official", "lyrics", "lyric video",
    ) || TYPE_LABELS.any { canonicalMetadata(it) == v } ||
        v.matches(Regex("(19|20)\\d{2}")) || v.matches(Regex("\\d{1,3}:\\d{2}(:\\d{2})?")) ||
        Regex("(?i)\\b(views|plays|likes|subscribers|followers|listeners|streams)\\b").containsMatchIn(value)
}

// Single-token joiners between linked artists ("A x B", "A e B"): never an
// artist credit on their own. Multi-word credits ("Camo & Krooked") pass
// through untouched.
private fun isCreditConjunction(value: String): Boolean =
    !value.any { it.isWhitespace() } && canonicalMetadata(value) in setOf(
        "x", "e", "y", "et", "vs", "versus", "meets", "pres", "presents",
    )

// First linked channel (artist/owner) across header run lists, used for
// album artists and playlist authors alike.
/**
 * Returns the first channel reference in [runs], or null when none is linked.
 *
 * @param runs header run lists (subtitle, second subtitle) to scan.
 * @return artist/owner ref with a UC browse id, or null.
 */
private fun channelRefFromRuns(vararg runs: JsonElement?): ArtistRef? =
    runs.asSequence()
        .filterIsInstance<JsonArray>()
        .flatMap { it.asSequence() }
        .mapNotNull { run ->
            val id = run.nav("navigationEndpoint", "browseEndpoint", "browseId")?.str()
            if (id?.startsWith("UC") == true) {
                ArtistRef(run.nav("text")?.str().orEmpty().trim(), id)
            } else {
                null
            }
        }
        .firstOrNull { it.name.isNotBlank() }

// Plain-text fallback for headers with no linked channel (e.g. Various
// Artists compilations, credited in the strapline). Composite runs carrying
// bullets are skipped so a packed "Album • 2023" line never becomes an
// author name, as are digit-leading runs (counts, years and durations like
// "23 songs" or "1 hour, 36 minutes" live in these lists; a genuinely
// unlinked digit-leading artist is vanishingly rare and stays hidden).
/**
 * Returns the first meaningful plain-text run in [runs] as an unlinked ref.
 *
 * @param runs header run lists (subtitle, strapline, second subtitle) to scan.
 * @return artist ref without a browse id, or null.
 */
private fun plainRefFromRuns(vararg runs: JsonElement?): ArtistRef? =
    runs.asSequence()
        .filterIsInstance<JsonArray>()
        .flatMap { it.asSequence() }
        .mapNotNull { run -> run.nav("text")?.str()?.trim()?.takeIf { it.isNotBlank() } }
        .filter { !it.contains('•') && !it.contains('·') && !it.first().isDigit() && !isBylineNoise(it) }
        .map { ArtistRef(it) }
        .firstOrNull()

private fun detectReleaseKind(text: String): ReleaseKind? {
    val tokens = text.lowercase()
        .replace(Regex("[^a-z0-9]+"), " ")
        .split(" ")
        .filter { it.isNotBlank() }
        .toSet()
    return when {
        "ep" in tokens -> ReleaseKind.EP
        "single" in tokens -> ReleaseKind.SINGLE
        "compilation" in tokens -> ReleaseKind.COMPILATION
        "mixed" in tokens -> ReleaseKind.MIXED
        "album" in tokens -> ReleaseKind.ALBUM
        else -> null
    }
}

private val DURATION_RE = Regex("""\d{1,3}:\d{2}(:\d{2})?""")

private val VIEWS_RE = Regex(
    """(?i)\d[\d.,\s]*(mila|mln|k|m|b)?\s*(views|views|riproduzioni|""" +
        """visualizzazioni|vues|vistas|aufrufe|weergaven|reproducciones|visualiza|""" +
        """visualizações|streams?|plays|再生|조회수|просмотров)""",
)

private val TYPE_LABELS = setOf(
    "Song", "Video", "Album", "Single", "EP", "Release", "Artist", "Playlist",
    "Podcast", "Episode", "Profile", "Channel",
)

private val SKIP_WORDS_RE = Regex("""(?i)\b(views|plays|subscribers|followers|listeners)\b""")

private fun JsonArray.firstVideoId(): String? {
    for (run in this) {
        val id = run.nav("navigationEndpoint", "watchEndpoint", "videoId")?.str()
        if (id != null) return id
    }
    return null
}
