package nixietube.innertube

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// Account-flavored features via the official YouTube Data API v3, which
// accepts standard OAuth tokens (unlike InnerTube from this environment).
// Playback of the resulting items still resolves through anonymous InnerTube.
class GDataApi(private val tokenProvider: suspend () -> String?) {
    private val json = Json { ignoreUnknownKeys = true }
    private val client = HttpClient(CIO)

    /**
     * A YouTube playlist from the signed-in account's library.
     *
     * @property id Playlist id.
     * @property title Playlist title.
     * @property itemCount Declared track count.
     * @property art Best playlist-cover URL, or null when none.
     * @property arts Additional cover URLs, if any.
     * @property owner Owning channel title.
     */
    data class GPlaylist(
        val id: String,
        val title: String,
        val itemCount: Int,
        val art: String?,
        val arts: List<String> = emptyList(),
        val owner: String = "",
        val ownerId: String = "",
    )

    // Playlist/video thumbnails come in varying sizes; take the best available.
    private fun thumbOf(parent: kotlinx.serialization.json.JsonObject?): String? {
        val thumbs = parent?.get("thumbnails")?.jsonObject ?: return null
        return listOf("high", "medium", "standard", "default", "maxres")
            .firstNotNullOfOrNull {
                thumbs[it]?.jsonObject?.get("url")?.jsonPrimitive?.contentOrNull
            }
    }

    private fun tagsOf(snippet: kotlinx.serialization.json.JsonObject): List<String> =
        snippet["tags"]?.jsonArray
            ?.mapNotNull { it.jsonPrimitive.contentOrNull }
            ?.filter { it.isNotBlank() }
            .orEmpty()

    private fun canonical(value: String): String =
        value.lowercase()
            .replace(Regex("[^a-z0-9]+"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()

    private fun isReleaseNoise(value: String): Boolean {
        val v = canonical(value)
        return v in setOf(
            "release", "single", "ep", "album", "compilation", "music", "song",
            "video", "official", "audio", "lyrics", "lyric video",
        ) || v.matches(Regex("(19|20)\\d{2}"))
    }

    private fun isGenericReleaseOwner(owner: String): Boolean =
        owner.trim().equals("Release", ignoreCase = true) ||
            owner.trim().equals("Release - Topic", ignoreCase = true)

    private fun isReleaseTypeTag(value: String): Boolean =
        canonical(value) in setOf("album", "single", "compilation", "mixtape", "ep")

    private fun hasReleaseType(value: String): Boolean {
        val compact = value.lowercase().replace(Regex("[^a-z]"), "")
        val tokens = canonical(value).split(' ').filter { it.isNotBlank() }
        return isReleaseTypeTag(value) || tokens.any { it in setOf("album", "single", "compilation", "mixtape") } ||
            value.contains("e.p.", ignoreCase = true) ||
            compact == "ep" || compact.contains("eptrack")
    }

    // YouTube's Data API exposes distributor channels as "Release - Topic"
    // for some auto-generated Topic uploads. The real artist/album are in the
    // video tags, while channelTitle is not useful. Prefer those tags only for
    // that known-bad owner; normal artist channels remain authoritative.
    private fun artistFromTags(title: String, tags: List<String>): String? {
        val titleKey = canonical(title)
        return tags.firstOrNull { tag ->
            val key = canonical(tag)
            key.isNotBlank() && key != titleKey && !isReleaseNoise(key)
        }?.trim()
    }

    internal fun albumFromTags(
        title: String,
        artist: String,
        rawOwner: String,
        tags: List<String>,
    ): String? {
        // For ordinary artist channels, arbitrary SEO/genre tags are common
        // and guessing an album from them creates worse metadata. A
        // distributor channel is the one case where the tag order is known to
        // contain the canonical artist/release; normal Topic channels are
        // enriched from InnerTube instead.
        if (!isGenericReleaseOwner(rawOwner) || tags.isEmpty()) return null
        val titleKey = canonical(title)
        val artistKey = canonical(artist)
        val meaningful = tags.filter { tag ->
            val key = canonical(tag)
            key.isNotBlank() && key != titleKey && !isReleaseNoise(key)
        }
        val meaningfulKeys = meaningful.map(::canonical).toSet()
        val titleIndex = tags.indexOfFirst { canonical(it) == titleKey }
        if (titleIndex > 0) {
            val beforeTitle = tags.take(titleIndex).filter { tag ->
                canonical(tag) in meaningfulKeys
            }
            // Topic tags normally use [primary, featured, album, title] for
            // collaborations. The tag immediately before the title is the
            // release name; choosing the first non-title tag would put the
            // featured artist in Album instead.
            val separateTypeIndex = tags.indexOfFirst { isReleaseTypeTag(it) }
            if (separateTypeIndex in 0 until titleIndex) {
                val beforeType = tags.take(separateTypeIndex).filter { tag ->
                    canonical(tag) in meaningfulKeys
                }
                if (beforeType.size == 1 && canonical(beforeType.first()) == artistKey) {
                    return title.trim().takeIf { it.isNotBlank() }
                }
                // There is no reliable way to distinguish a second artist
                // from an album when a standalone type tag is also present.
                return null
            }
            val explicitType = beforeTitle.any(::hasReleaseType)
            if (explicitType && beforeTitle.isNotEmpty()) return beforeTitle.last().trim()
            // [artist, title] is the common single-release shape. Other
            // untyped multi-tag rows are intentionally left unresolved: a
            // secondary artist or genre is more likely than an album, and
            // InnerTube enrichment will confirm the release when playback
            // starts.
            if (beforeTitle.size == 1 && canonical(beforeTitle.first()) == artistKey) {
                return title.trim().takeIf { it.isNotBlank() }
            }
        }
        if (tags.any { canonical(it) == titleKey } && meaningful.size <= 1 &&
            meaningful.firstOrNull()?.let { canonical(it) == artistKey } == true
        ) {
            return title.trim().takeIf { it.isNotBlank() }
        }
        return null
    }

    internal fun albumKindFromTags(
        title: String,
        album: String?,
        rawOwner: String,
        tags: List<String> = emptyList(),
    ): ReleaseKind? {
        if (album == null || !isGenericReleaseOwner(rawOwner)) return null
        if (canonical(album) == canonical(title)) return ReleaseKind.SINGLE
        val text = (listOf(album) + tags).joinToString(" ")
        val tokens = canonical(text).split(' ').filter { it.isNotBlank() }.toSet()
        return when {
            "ep" in tokens || text.contains("e.p.", ignoreCase = true) -> ReleaseKind.EP
            "single" in tokens -> ReleaseKind.SINGLE
            "compilation" in tokens -> ReleaseKind.COMPILATION
            "album" in tokens -> ReleaseKind.ALBUM
            else -> null
        }
    }

    /**
     * A liked video with the metadata needed to display it as a track.
     *
     * @property videoId YouTube video id.
     * @property title Video title.
     * @property channel Owning channel title.
     * @property art Best thumbnail URL, or null when none.
     */
    data class GLiked(val videoId: String, val title: String, val channel: String, val art: String?)

    /** Returns the current OAuth token or throws when signed out. */
    private suspend fun token(): String = tokenProvider() ?: throw IllegalStateException("not signed in")

    private suspend fun get(path: String, params: Map<String, String>): String {
        val body: String = client.get("https://www.googleapis.com/youtube/v3/$path") {
            header(HttpHeaders.Authorization, "Bearer ${token()}")
            params.forEach { (k, v) -> parameter(k, v) }
        }.body()
        return body
    }

    // Signed-in channel avatar for the home greeting. Prefers the medium
    // thumbnail over the 800px original.
    /**
     * Returns the signed-in channel's avatar URL, preferring the medium thumbnail.
     *
     * @return avatar URL, or null on failure.
     */
    suspend fun channelAvatar(): String? {
        return try {
            val el = json.parseToJsonElement(get("channels", mapOf("part" to "snippet", "mine" to "true")))
            val sn = el.jsonObject["items"]?.jsonArray?.firstOrNull()
                ?.jsonObject?.get("snippet")?.jsonObject ?: return null
            val thumbs = sn["thumbnails"]?.jsonObject
            thumbs?.get("medium")?.jsonObject?.get("url")?.jsonPrimitive?.contentOrNull
                ?: thumbs?.get("default")?.jsonObject?.get("url")?.jsonPrimitive?.contentOrNull
                ?: thumbOf(sn)
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Returns the signed-in channel's display name.
     *
     * @return channel title, or null on failure.
     */
    suspend fun channelName(): String? {
        return try {
            val el = json.parseToJsonElement(get("channels", mapOf("part" to "snippet", "mine" to "true")))
            el.jsonObject["items"]?.jsonArray?.firstOrNull()
                ?.jsonObject?.get("snippet")?.jsonObject
                ?.get("title")?.jsonPrimitive?.contentOrNull
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Returns the signed-in channel's id, used to never link to yourself.
     *
     * @return channel id, or null on failure.
     */
    suspend fun ownChannelId(): String? {
        return try {
            val el = json.parseToJsonElement(get("channels", mapOf("part" to "id", "mine" to "true")))
            el.jsonObject["items"]?.jsonArray?.firstOrNull()
                ?.jsonObject?.get("id")?.jsonPrimitive?.contentOrNull
                ?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Lists the account's music playlists, excluding likes and non-music lists.
     *
     * @return music playlists in account order.
     */
    suspend fun playlists(): List<GPlaylist> {
        val out = mutableListOf<GPlaylist>()
        var pageToken: String? = null
        try {
            do {
                val params = mutableMapOf("part" to "snippet,contentDetails", "mine" to "true", "maxResults" to "50")
                pageToken?.let { params["pageToken"] = it }
                val el = json.parseToJsonElement(get("playlists", params))
                val obj = el.jsonObject
                obj["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val sn = o["snippet"]?.jsonObject
                    val cd = o["contentDetails"]?.jsonObject
                    out.add(
                        GPlaylist(
                            id = o["id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                            title = sn?.get("title")?.jsonPrimitive?.contentOrNull.orEmpty(),
                            itemCount = cd?.get("itemCount")?.jsonPrimitive?.intOrNull ?: 0,
                            art = thumbOf(sn),
                            owner = sn?.get("channelTitle")?.jsonPrimitive?.contentOrNull.orEmpty(),
                            ownerId = sn?.get("channelId")?.jsonPrimitive?.contentOrNull.orEmpty(),
                        ),
                    )
                }
                pageToken = obj["nextPageToken"]?.jsonPrimitive?.contentOrNull
            } while (pageToken != null)
        } catch (_: Exception) {
        }
        return keepMusicPlaylists(out.filter { !it.id.startsWith("LL") })
    }

    /** First classifiable video id in [pl], or null for empty/unreadable playlists. */
    private suspend fun firstPlaylistVideo(pl: GPlaylist): String? {
        if (pl.itemCount == 0) return null
        val el = json.parseToJsonElement(
            get(
                "playlistItems",
                mapOf(
                    "part" to "snippet,contentDetails",
                    "playlistId" to pl.id,
                    "maxResults" to "3",
                ),
            ),
        )
        return el.jsonObject["items"]?.jsonArray
            ?.mapNotNull {
                it.jsonObject["contentDetails"]?.jsonObject?.get("videoId")?.jsonPrimitive?.contentOrNull
            }
            ?.firstOrNull { it != "UCBR8-60-B28hp2BmDPdntcQ" }
    }

    // Drops non-music playlists (plain YouTube video collections). Probe
    // only enough items to classify the playlist; a video thumbnail is not a
    // playlist cover and must never be used as one.
    /** Filters out non-music playlists via topic probing of their first items. */
    private suspend fun keepMusicPlaylists(all: List<GPlaylist>): List<GPlaylist> {
        if (all.isEmpty()) return all
        val firstIds = mutableMapOf<String, String>() // playlistId -> videoId
        try {
            for (pl in all) {
                firstPlaylistVideo(pl)?.let { firstIds[pl.id] = it }
            }
            if (firstIds.isEmpty()) return all
            val musical = mutableSetOf<String>()
            firstIds.values.chunked(50).forEach { chunk ->
                val el = json.parseToJsonElement(
                    get("videos", mapOf("part" to "topicDetails", "id" to chunk.joinToString(","))),
                )
                el.jsonObject["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val id = o["id"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                    if (hasMusicTopics(o)) musical.add(id)
                }
            }
            val musicalPlaylists = firstIds.filter { (_, vid) -> vid in musical }.keys
            // Playlists we couldn't classify (empty/private) stay visible.
            val unknown = all.filter { it.id !in firstIds }.map { it.id }.toSet()
            return all.filter { it.id in musicalPlaylists || it.id in unknown }
        } catch (_: Exception) {
            return all
        }
    }

    /**
     * Lists tracks of a playlist with fixed-up artist/title metadata.
     *
     * @param playlistId Data API playlist id.
     * @param max maximum tracks to return.
     * @return playlist tracks in order.
     */
    suspend fun playlistTracks(playlistId: String, max: Int = 5000): List<Track> {
        val out = mutableListOf<Track>()
        var pageToken: String? = null
        try {
            while (out.size < max) {
                val params = mutableMapOf(
                    "part" to "snippet,contentDetails",
                    "playlistId" to playlistId,
                    "maxResults" to "50",
                )
                pageToken?.let { params["pageToken"] = it }
                val el = json.parseToJsonElement(get("playlistItems", params))
                val obj = el.jsonObject
                obj["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val sn = o["snippet"]?.jsonObject ?: return@forEach
                    val videoId = sn["resourceId"]?.jsonObject?.get("videoId")?.jsonPrimitive?.contentOrNull
                        ?: return@forEach
                    if (videoId == "UCBR8-60-B28hp2BmDPdntcQ") return@forEach // deleted/private stub
                    val rawTitle = sn["title"]?.jsonPrimitive?.contentOrNull ?: "Unknown"
                    val rawOwner = sn["videoOwnerChannelTitle"]?.jsonPrimitive?.contentOrNull.orEmpty()
                    val tags = tagsOf(sn)
                    val (artist, songTitle) = fixup(rawTitle, rawOwner, tags)
                    val album = albumFromTags(rawTitle, artist, rawOwner, tags)
                    out.add(
                        Track(
                            videoId = videoId,
                            title = songTitle,
                            artists = listOfNotNull(
                                artist.takeIf { it.isNotBlank() }?.let { ArtistRef(it) },
                            ),
                            album = album?.let {
                                AlbumRef(it, kind = albumKindFromTags(rawTitle, it, rawOwner, tags))
                            },
                            thumbnails = listOfNotNull(
                                thumbOf(sn)?.let { Thumbnail(it) },
                            ),
                        ),
                    )
                }
                pageToken = obj["nextPageToken"]?.jsonPrimitive?.contentOrNull ?: break
            }
        } catch (_: Exception) {
        }
        return out.take(max)
    }

    // Recently liked/uploaded/favorited videos, the closest thing the
    // Data API offers to a personalized home feed. NB: snippet.channelTitle
    // here is the ACTOR (you), so artists are backfilled via videos.list.
    private data class Pending(val videoId: String, val title: String, val art: String?)

    private data class VideoMeta(
        val owner: String,
        val channelId: String,
        val duration: Int,
        val tags: List<String>,
    )

    /**
     * Returns recent liked/uploaded/favorited videos as tracks with real owners backfilled.
     *
     * @param max maximum tracks to return.
     * @return recent activity tracks, or empty on failure.
     */
    suspend fun recentActivity(max: Int = 30): List<Track> {
        val ids = mutableListOf<Pending>()
        try {
            val el = json.parseToJsonElement(
                get(
                    "activities",
                    mapOf("part" to "snippet,contentDetails", "mine" to "true", "maxResults" to "50"),
                ),
            )
            el.jsonObject["items"]?.jsonArray?.forEach { item ->
                val o = item.jsonObject
                val sn = o["snippet"]?.jsonObject ?: return@forEach
                if (sn["type"]?.jsonPrimitive?.contentOrNull == "subscription") return@forEach
                val cd = o["contentDetails"]?.jsonObject ?: return@forEach
                val detail = cd["like"]?.jsonObject
                    ?: cd["favorite"]?.jsonObject
                    ?: cd["upload"]?.jsonObject
                    ?: cd["playlistItem"]?.jsonObject
                    ?: cd["recommendation"]?.jsonObject
                    ?: return@forEach
                val videoId = detail["resourceId"]?.jsonObject?.get("videoId")?.jsonPrimitive?.contentOrNull
                    ?: return@forEach
                val title = sn["title"]?.jsonPrimitive?.contentOrNull ?: "Unknown"
                val art = thumbOf(sn)
                ids.add(Pending(videoId, title, art))
                if (ids.size >= max) return@forEach
            }
        } catch (_: Exception) {
            return emptyList()
        }
        if (ids.isEmpty()) return emptyList()
        // Batch-resolve real owners (channelTitle + channelId) and durations.
        val owners = mutableMapOf<String, VideoMeta>()
        try {
            var idx = 0
            while (idx < ids.size) {
                val chunk = ids.subList(idx, minOf(idx + 50, ids.size)).map { it.videoId }
                val el = json.parseToJsonElement(
                    get("videos", mapOf("part" to "snippet,contentDetails", "id" to chunk.joinToString(","))),
                )
                el.jsonObject["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val id = o["id"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                    val sn2 = o["snippet"]?.jsonObject ?: return@forEach
                    val owner = sn2["channelTitle"]?.jsonPrimitive?.contentOrNull
                    val channelId = sn2["channelId"]?.jsonPrimitive?.contentOrNull
                    val dur = isoDuration(
                        o["contentDetails"]?.jsonObject?.get("duration")?.jsonPrimitive?.contentOrNull,
                    )
                    if (!owner.isNullOrBlank()) {
                        owners[id] = VideoMeta(
                            owner = owner,
                            channelId = channelId.orEmpty(),
                            duration = dur,
                            tags = tagsOf(sn2),
                        )
                    }
                }
                idx += 50
            }
        } catch (_: Exception) {
        }
        return ids.map { (videoId, title, art) ->
            val meta = owners[videoId] ?: VideoMeta("", "", 0, emptyList())
            val (artist, songTitle) = fixup(title, meta.owner, meta.tags)
            val album = albumFromTags(title, artist, meta.owner, meta.tags)
            Track(
                videoId = videoId,
                title = songTitle,
                artists = listOfNotNull(
                    artist.takeIf { it.isNotBlank() }?.let { ArtistRef(it) },
                ),
                album = album?.let {
                    AlbumRef(it, kind = albumKindFromTags(title, it, meta.owner, meta.tags))
                },
                thumbnails = listOfNotNull(art?.let { Thumbnail(it) }),
                artistId = meta.channelId.takeIf {
                    it.isNotBlank() && !isGenericReleaseOwner(meta.owner)
                },
                durationSec = meta.duration,
            )
        }
    }

    // ISO8601 durations from the Data API ("PT4M13S") -> seconds.
    /**
     * Parses an ISO-8601 Data API duration (e.g. "PT4M13S") to seconds.
     *
     * @param raw raw duration string, or null.
     * @return duration in seconds, or 0 when blank/unparseable.
     */
    fun isoDuration(raw: String?): Int {
        if (raw.isNullOrBlank()) return 0
        val m = Regex("""PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?""").find(raw) ?: return 0
        val h = m.groupValues[1].toIntOrNull() ?: 0
        val min = m.groupValues[2].toIntOrNull() ?: 0
        val s = m.groupValues[3].toIntOrNull() ?: 0
        return h * 3600 + min * 60 + s
    }

    // "Daft Punk - Topic" -> "Daft Punk", "AdeleVEVO" -> "Adele".
    /**
     * Strips channel suffixes (" - Topic", "VEVO") to get the artist name.
     *
     * @param name raw channel/owner name.
     * @return normalized artist name.
     */
    fun normalizeArtist(name: String): String {
        var n = name.trim()
        if (n.endsWith(" - Topic", ignoreCase = true)) n = n.dropLast(8).trim()
        if (n.endsWith("VEVO", ignoreCase = true) && n.length > 4) n = n.dropLast(4).trim()
        return n.ifBlank { name }
    }

    private val versionWords = setOf(
        "live", "remaster", "remastered", "remix", "edit", "mix", "acoustic",
        "unplugged", "demo", "extended", "vip", "bootleg", "cover",
        "instrumental", "karaoke", "sped up", "slowed", "nightcore",
    )

    // Reconcile a Data API title/owner pair. Topic channels already carry
    // the real artist; distributor "Release - Topic" channels do not, so
    // use the video tags for those. Label uploads titled "Artist - Track"
    // carry the uploader as owner, so split those, unless the suffix is a
    // version word ("Song - Live"), which stays put.
    /**
     * Reconciles a Data API title/owner pair into an artist/title pair.
     *
     * @param title raw video title.
     * @param rawOwner raw owner channel title.
     * @param tags video tags used for distributor-owned uploads.
     * @return artist name to song title pair.
     */
    fun fixup(
        title: String,
        rawOwner: String,
        tags: List<String> = emptyList(),
    ): Pair<String, String> {
        val cleanTitle = title.trim()
        val ownerArtist = normalizeArtist(rawOwner)
        if (isGenericReleaseOwner(rawOwner)) {
            val taggedArtist = artistFromTags(cleanTitle, tags)
            return (taggedArtist ?: ownerArtist) to cleanTitle
        }
        if (rawOwner.endsWith(" - Topic", ignoreCase = true)) {
            return ownerArtist to cleanTitle
        }
        val artist = ownerArtist
        val dash = cleanTitle.indexOf(" - ")
        if (dash <= 0) return artist to cleanTitle
        val candidate = cleanTitle.substring(0, dash).trim()
        val suffix = cleanTitle.substring(dash + 3).trim()
        if (candidate.isBlank() || candidate.length > 60 || suffix.isBlank()) {
            return artist to cleanTitle
        }
        val suffixHead = suffix.split(Regex("[\\s(\\[]"))[0].lowercase()
        if (suffixHead in versionWords) return artist to cleanTitle
        return candidate to suffix
    }

    // Channels you're subscribed to -> artist pages (browseId = channel UC id).
    /**
     * Lists subscribed channels as music artist entries.
     *
     * @param max maximum entries to return.
     * @return artist browse entries.
     */
    suspend fun subscriptions(max: Int = 50): List<ShelfItem.Browse> {
        val out = mutableListOf<ShelfItem.Browse>()
        var pageToken: String? = null
        try {
            while (out.size < max) {
                val params = mutableMapOf(
                    "part" to "snippet",
                    "mine" to "true",
                    "maxResults" to "50",
                    "order" to "alphabetical",
                )
                pageToken?.let { params["pageToken"] = it }
                val el = json.parseToJsonElement(get("subscriptions", params))
                val obj = el.jsonObject
                obj["items"]?.jsonArray?.forEach { item ->
                    val sn = item.jsonObject["snippet"]?.jsonObject ?: return@forEach
                    val channelId = sn["resourceId"]?.jsonObject?.get("channelId")
                        ?.jsonPrimitive?.contentOrNull ?: return@forEach
                    out.add(
                        ShelfItem.Browse(
                            title = sn["title"]?.jsonPrimitive?.contentOrNull ?: "Unknown",
                            subtitle = "Artist",
                            browseId = channelId,
                            thumbnails = listOfNotNull(
                                thumbOf(sn)?.let { Thumbnail(it) },
                            ),
                        ),
                    )
                }
                pageToken = obj["nextPageToken"]?.jsonPrimitive?.contentOrNull ?: break
            }
        } catch (_: Exception) {
        }
        return keepMusicChannels(out.take(max))
    }

    // Drops non-music channels (vloggers, gamers…) via one batched
    // channels.list topicDetails lookup. Unclassifiable stay visible.
    /** Filters out non-music channels via a batched topicDetails lookup. */
    private suspend fun keepMusicChannels(all: List<ShelfItem.Browse>): List<ShelfItem.Browse> {
        if (all.isEmpty()) return all
        return try {
            val musical = mutableSetOf<String>()
            val unknown = mutableSetOf<String>()
            all.map { it.browseId }.chunked(50).forEach { chunk ->
                val el = json.parseToJsonElement(
                    get("channels", mapOf("part" to "topicDetails", "id" to chunk.joinToString(","))),
                )
                val seen = mutableSetOf<String>()
                el.jsonObject["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val id = o["id"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                    seen.add(id)
                    if (hasMusicTopics(o)) musical.add(id)
                }
                chunk.filter { it !in seen }.forEach { unknown.add(it) }
            }
            all.filter { it.browseId in musical || it.browseId in unknown }
        } catch (_: Exception) {
            all
        }
    }
    /**
     * Lists liked videos classified as music with region filtering applied.
     *
     * @param max maximum tracks to return.
     * @return liked music tracks.
     */
    suspend fun likedVideos(max: Int = 2000): List<Track> {
        val out = mutableListOf<Track>()
        var pageToken: String? = null
        try {
            while (out.size < max) {
                val params = mutableMapOf(
                    "part" to "snippet,contentDetails,topicDetails",
                    "myRating" to "like",
                    "maxResults" to "50",
                )
                pageToken?.let { params["pageToken"] = it }
                val el = json.parseToJsonElement(get("videos", params))
                val obj = el.jsonObject
                val region = region()
                obj["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val sn = o["snippet"]?.jsonObject ?: return@forEach
                    val videoId = o["id"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                    if (!keepTrack(o, region)) return@forEach
                    val rawTitle = sn["title"]?.jsonPrimitive?.contentOrNull ?: "Unknown"
                    val rawOwner = sn["channelTitle"]?.jsonPrimitive?.contentOrNull.orEmpty()
                    val tags = tagsOf(sn)
                    val (artist, songTitle) = fixup(rawTitle, rawOwner, tags)
                    val album = albumFromTags(rawTitle, artist, rawOwner, tags)
                    out.add(
                        Track(
                            videoId = videoId,
                            title = songTitle,
                            artists = listOfNotNull(
                                artist.takeIf { it.isNotBlank() }?.let { ArtistRef(it) },
                            ),
                            album = album?.let {
                                AlbumRef(it, kind = albumKindFromTags(rawTitle, it, rawOwner, tags))
                            },
                            thumbnails = listOfNotNull(
                                thumbOf(sn)?.let { Thumbnail(it) },
                            ),
                            durationSec = isoDuration(
                                o["contentDetails"]?.jsonObject?.get("duration")?.jsonPrimitive?.contentOrNull,
                            ),
                            rating = RatingStatus.LIKE,
                        ),
                    )
                }
                pageToken = obj["nextPageToken"]?.jsonPrimitive?.contentOrNull ?: break
            }
        } catch (_: Exception) {
        }
        return out.take(max)
    }

    // Every video ID the account rated LIKE. Minimal parts and no region
    // filtering (unlike likedVideos): used to mark like-state on surfaces
    // that never run the ratings flow, and to prime its cache, in
    // sessions where InnerTube personalization is unavailable.
    /**
     * Returns every video id the account rated LIKE, without region filtering.
     *
     * @param max maximum ids to return.
     * @return liked video ids in account order.
     */
    suspend fun likedVideoIds(max: Int = 2000): Set<String> {
        val out = linkedSetOf<String>()
        var pageToken: String? = null
        try {
            while (out.size < max) {
                val params = mutableMapOf(
                    "part" to "id",
                    "myRating" to "like",
                    "maxResults" to "50",
                )
                pageToken?.let { params["pageToken"] = it }
                val el = json.parseToJsonElement(get("videos", params))
                el.jsonObject["items"]?.jsonArray?.forEach { item ->
                    item.jsonObject["id"]?.jsonPrimitive?.contentOrNull
                        ?.takeIf { it.isNotBlank() }?.let { out += it }
                }
                pageToken = el.jsonObject["nextPageToken"]?.jsonPrimitive?.contentOrNull ?: break
            }
        } catch (_: Exception) {
        }
        return out
    }

    // Channel avatars, one batched call per 50 ids. Used for artist icons
    // where InnerTube only exposes the wide header banner.
    /**
     * Batch-resolves channel avatars for artist icons.
     *
     * @param ids channel ids to look up.
     * @return channel id to avatar URL map.
     */
    suspend fun channelAvatars(ids: List<String>): Map<String, String> {
        val out = linkedMapOf<String, String>()
        try {
            ids.distinct().filter { it.isNotBlank() }.chunked(50).forEach { chunk ->
                val el = json.parseToJsonElement(
                    get("channels", mapOf("part" to "snippet", "id" to chunk.joinToString(","))),
                )
                el.jsonObject["items"]?.jsonArray?.forEach { item ->
                    val o = item.jsonObject
                    val id = o["id"]?.jsonPrimitive?.contentOrNull ?: return@forEach
                    val art = thumbOf(o["snippet"]?.jsonObject)
                    if (!art.isNullOrBlank()) out[id] = art
                }
            }
        } catch (_: Exception) {
        }
        return out
    }

    private fun region(): String =
        java.util.Locale.getDefault().country.ifBlank { "US" }

    private fun hasMusicTopics(video: kotlinx.serialization.json.JsonObject): Boolean {
        val details = video["topicDetails"]?.jsonObject ?: return false
        val ids = details["relevantTopicIds"]?.jsonArray
            ?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
        if (ids.any { it == "/m/04rlf" }) return true
        val cats = details["topicCategories"]?.jsonArray
            ?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
        return cats.any { it.contains("music", ignoreCase = true) }
    }

    // Keep iff YouTube classifies it as music (category 10 or music
    // topics) and it is playable in the user's region.
    private fun keepTrack(
        video: kotlinx.serialization.json.JsonObject,
        region: String,
    ): Boolean {
        val snippet = video["snippet"]?.jsonObject
        if ((snippet?.get("categoryId")?.jsonPrimitive?.contentOrNull) == "10") return true
        val details = video["topicDetails"]?.jsonObject ?: return false
        val ids = details["relevantTopicIds"]?.jsonArray
            ?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
        if (ids.any { it == "/m/04rlf" }) return !isRegionBlocked(video, region)
        val cats = details["topicCategories"]?.jsonArray
            ?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
        if (cats.isEmpty()) return false
        if (!cats.any { it.contains("music", ignoreCase = true) }) return false
        return !isRegionBlocked(video, region)
    }

    private fun isRegionBlocked(video: kotlinx.serialization.json.JsonObject, region: String): Boolean {
        if (region.isBlank()) return false
        val rr = video["contentDetails"]?.jsonObject?.get("regionRestriction")?.jsonObject ?: return false
        if (rr["blocked"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty().contains(region)) {
            return true
        }
        val allowed = rr["allowed"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }
        return allowed != null && !allowed.contains(region)
    }

    /**
     * Rates a video liked or neutral via the Data API.
     *
     * @param videoId YouTube video id to rate.
     * @param like true to like, false to remove the rating.
     * @return true when the request succeeds.
     */
    suspend fun rate(videoId: String, like: Boolean): Boolean {        return try {
            val token = token()
            client.post("https://www.googleapis.com/youtube/v3/videos/rate") {
                header(HttpHeaders.Authorization, "Bearer $token")
                parameter("id", videoId)
                parameter("rating", if (like) "like" else "none")
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Appends a video to a playlist.
     *
     * @param playlistId Data API playlist id.
     * @param videoId YouTube video id to add.
     * @return true when the insert succeeds.
     */
    suspend fun addToPlaylist(playlistId: String, videoId: String): Boolean {
        return try {
            client.post("https://www.googleapis.com/youtube/v3/playlistItems") {
                header(HttpHeaders.Authorization, "Bearer ${token()}")
                parameter("part", "snippet")
                contentType(io.ktor.http.ContentType.Application.Json)
                setBody(
                    """{"snippet":{"playlistId":"$playlistId","resourceId":{"kind":"youtube#video","videoId":"$videoId"}}}""",
                )
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Finds the playlist-item id backing a video inside a playlist.
     *
     * Removal needs the item id, not the video id, so this pages the
     * playlist until the video is found.
     *
     * @param playlistId Data API playlist id.
     * @param videoId YouTube video id to look for.
     * @return playlist-item id, or null when absent or on failure.
     */
    suspend fun playlistItemId(playlistId: String, videoId: String): String? {
        var pageToken: String? = null
        return try {
            var found: String? = null
            while (found == null) {
                val params = mutableMapOf(
                    "part" to "snippet",
                    "playlistId" to playlistId,
                    "maxResults" to "50",
                )
                pageToken?.let { params["pageToken"] = it }
                val el = json.parseToJsonElement(get("playlistItems", params))
                val obj = el.jsonObject
                found = obj["items"]?.jsonArray?.firstNotNullOfOrNull { item ->
                    val o = item.jsonObject
                    val vid = o["snippet"]?.jsonObject
                        ?.get("resourceId")?.jsonObject
                        ?.get("videoId")?.jsonPrimitive?.contentOrNull
                    if (vid == videoId) o["id"]?.jsonPrimitive?.contentOrNull else null
                }
                if (found == null) {
                    pageToken = obj["nextPageToken"]?.jsonPrimitive?.contentOrNull ?: break
                }
            }
            found
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Removes one entry from a playlist by playlist-item id.
     *
     * @param itemId playlist-item id from [playlistItemId].
     * @return true when the delete succeeds.
     */
    suspend fun removePlaylistItem(itemId: String): Boolean {
        return try {
            client.delete("https://www.googleapis.com/youtube/v3/playlistItems") {
                header(HttpHeaders.Authorization, "Bearer ${token()}")
                parameter("id", itemId)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Returns the subscription id for a channel, or null when not subscribed.
     *
     * @param channelId channel id to check.
     * @return subscription id, or null on failure.
     */
    suspend fun subscriptionId(channelId: String): String? {
        return try {
            val el = json.parseToJsonElement(
                get(
                    "subscriptions",
                    mapOf("part" to "id", "mine" to "true", "forChannelId" to channelId),
                ),
            )
            el.jsonObject["items"]?.jsonArray?.firstOrNull()
                ?.jsonObject?.get("id")?.jsonPrimitive?.contentOrNull
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Subscribes to a channel.
     *
     * @param channelId channel id to subscribe to.
     * @return true when the request succeeds.
     */
    suspend fun subscribe(channelId: String): Boolean {
        return try {
            val token = token()
            client.post("https://www.googleapis.com/youtube/v3/subscriptions?part=snippet") {
                header(HttpHeaders.Authorization, "Bearer $token")
                contentType(io.ktor.http.ContentType.Application.Json)
                setBody(
                    """{"snippet":{"resourceId":{"kind":"youtube#channel","channelId":"$channelId"}}}""",
                )
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Removes a subscription.
     *
     * @param subscriptionId subscription id from [subscriptionId].
     * @return true when the request succeeds.
     */
    suspend fun unsubscribe(subscriptionId: String): Boolean {
        return try {
            val token = token()
            client.delete("https://www.googleapis.com/youtube/v3/subscriptions") {
                header(HttpHeaders.Authorization, "Bearer $token")
                parameter("id", subscriptionId)
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}
