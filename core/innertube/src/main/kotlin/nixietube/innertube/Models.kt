package nixietube.innertube

import kotlinx.serialization.Serializable

// Pure-Kotlin domain models. No UI imports here on purpose:
// these modules must stay reusable if the UI layer is ever swapped (e.g. Qt).

/** Image thumbnail with its dimensions; zero width/height means unknown. */
@Serializable
data class Thumbnail(val url: String, val width: Int = 0, val height: Int = 0)

/** Like state of a track as reported by YouTube. */
@Serializable
enum class RatingStatus {
    /** User liked the track. */
    LIKE,
    /** User disliked the track. */
    DISLIKE,
    /** Explicitly neutral / like removed. */
    INDIFFERENT,
    /** No rating information available. */
    UNKNOWN,
    ;

    companion object {
        /**
         * Maps a raw InnerTube/Data API status string to a [RatingStatus].
         *
         * @param value raw status such as "LIKE", "DISLIKE", "NONE" or "REMOVED".
         * @return the matching status, or [UNKNOWN] when null or unrecognized.
         */
        fun fromValue(value: String?): RatingStatus = when (value?.trim()?.uppercase()) {
            "LIKE" -> LIKE
            "DISLIKE" -> DISLIKE
            "INDIFFERENT", "NONE", "REMOVED" -> INDIFFERENT
            else -> UNKNOWN
        }
    }
}

/** Kind of music release used to classify browse results and album headers. */
@Serializable
enum class ReleaseKind(val label: String) {
    ALBUM("Album"),
    EP("EP"),
    SINGLE("Single"),
    COMPILATION("Compilation"),
    MIXED("Mixed"),
}

/**
 * A playable music track from YouTube Music.
 *
 * @property videoId YouTube video id backing playback and stream resolution.
 * @property title Track title.
 * @property artists Credited artists, possibly empty when unknown.
 * @property album Linked album reference, or null when unknown.
 * @property durationSec Duration in seconds, or 0 when unknown.
 * @property thumbnails Artwork candidates in various sizes.
 * @property playlistId Playlist context the track was found in, if any.
 * @property radioPlaylistId Radio/mix playlist seed for this track, if known.
 * @property artistId Browse id of the primary artist channel, if known.
 * @property views Raw view-count label as shown by YouTube, or empty.
 * @property rating Known like state, or [RatingStatus.UNKNOWN].
 * @property likeCount Public like count, or -1 when unknown.
 * @property dislikeCount Public dislike count, or -1 when unknown.
 */
@Serializable
data class Track(
    val videoId: String,
    val title: String,
    val artists: List<ArtistRef> = emptyList(),
    val album: AlbumRef? = null,
    val durationSec: Int = 0,
    val thumbnails: List<Thumbnail> = emptyList(),
    val playlistId: String? = null,
    val radioPlaylistId: String? = null,
    val artistId: String? = null,
    val views: String = "",
    val rating: RatingStatus = RatingStatus.UNKNOWN,
    // Public counters (-1 = unknown). Dislikes are no longer published
    // by YouTube, so dislikeCount is unknown for virtually everything.
    val likeCount: Long = -1L,
    val dislikeCount: Long = -1L,
) {
    val artistNames: String get() = artists.joinToString(", ") { it.name }
    val bestArtwork: String? get() = thumbnails.maxByOrNull { it.width }?.url
    // Song display art: prefer a true 1:1 cover (e.g. the Topic thumbnail)
    // over a larger 16:9 video frame. Falls back to the largest available.
    val displayArtwork: String?
        get() = thumbnails.filter { it.isSquare() }.maxByOrNull { it.width }?.url ?: bestArtwork
}

private val SQUARE_SIZE_RE = Regex("""=w(\d+)-h(\d+)(?:\D|$)""")

/**
 * Returns true when the thumbnail is square, using explicit dimensions
 * or the Google `=w{W}-h{H}` URL sizing suffix as fallback.
 *
 * @return true when width equals height, false otherwise.
 */
fun Thumbnail.isSquare(): Boolean {
    if (width > 0 && height > 0) return width == height
    val match = SQUARE_SIZE_RE.find(url) ?: return false
    val w = match.groupValues[1].toIntOrNull()
    val h = match.groupValues[2].toIntOrNull()
    return w != null && w > 0 && w == h
}

private val GOOGLE_WH_SIZE_RE = Regex("""=w(\d+)-h(\d+)""")

// Requests a larger rendition from Google image servers (yt3/lh3 honor
// =w sizing). Never downscales and never distorts: known dimensions are
// scaled proportionally, unknown ones keep width-only sizing.
/**
 * Returns a copy requesting a larger rendition from Google image servers.
 *
 * @param targetWidth desired width in pixels; never downscales or distorts.
 * @return the upscaled thumbnail, or this instance when already large enough.
 */
fun Thumbnail.upscaledTo(targetWidth: Int): Thumbnail {
    if (targetWidth <= 0 || (width > 0 && width >= targetWidth)) return this
    val sized = if (width > 0 && height > 0 && GOOGLE_WH_SIZE_RE.containsMatchIn(url)) {
        val newH = (targetWidth.toLong() * height / width).toInt().coerceAtLeast(1)
        GOOGLE_WH_SIZE_RE.replace(url, "=w$targetWidth-h$newH")
    } else if (!GOOGLE_WH_SIZE_RE.containsMatchIn(url)) {
        "$url=w$targetWidth"
    } else {
        return this
    }
    return copy(url = sized)
}

/** Reference to an artist channel.
 *
 * @property name Display name of the artist.
 * @property browseId Channel browse id (UC…), or null when unlinked.
 */
@Serializable
data class ArtistRef(val name: String, val browseId: String? = null)

/** Reference to an album/release page.
 *
 * @property name Release title.
 * @property browseId Release browse id (MPRE…), or null when unlinked.
 * @property kind Release kind, or null when undetected.
 * @property year Release year label, or empty when unknown.
 */
@Serializable
data class AlbumRef(
    val name: String,
    val browseId: String? = null,
    val kind: ReleaseKind? = null,
    val year: String = "",
)

/** A home-screen shelf (carousel or list) with its items.
 *
 * @property title Shelf header title.
 * @property items Shelf entries in display order.
 */
data class Shelf(
    val title: String,
    val items: List<ShelfItem>,
)

sealed interface ShelfItem {
    /** A directly playable song entry.
     *
     * @property track The song track.
     */
    data class Song(val track: Track) : ShelfItem
    /** A browsable entry (album, artist, or playlist).
     *
     * @property title Entry title.
     * @property subtitle Entry subtitle/byline.
     * @property browseId Browse id used to open the detail page.
     * @property thumbnails Entry artwork.
     * @property kind Release kind for album-like entries, or null.
     * @property browseParams Optional browse params required to open the page.
     */
    data class Browse(
        val title: String,
        val subtitle: String,
        val browseId: String,
        val thumbnails: List<Thumbnail>,
        val kind: ReleaseKind? = null,
        val browseParams: String? = null,
    ) : ShelfItem
}

/** Full album/release page.
 *
 * @property title Release title.
 * @property subtitle Header subtitle/byline.
 * @property description Release description, or empty.
 * @property thumbnails Release artwork.
 * @property tracks Release track list in order.
 * @property kind Release kind, or null when undetected.
 * @property year Release year label, or empty.
 */
data class AlbumDetail(
    val title: String,
    val subtitle: String,
    val description: String,
    val thumbnails: List<Thumbnail>,
    val tracks: List<Track>,
    val kind: ReleaseKind? = null,
    val year: String = "",
)

/** Full artist page.
 *
 * @property name Artist display name.
 * @property description Artist description/bio, or empty.
 * @property thumbnails Artist imagery.
 * @property topSongs Top tracks.
 * @property albums Album entries.
 * @property singlesAndEps Singles and EPs.
 * @property relatedPlaylists Playlists featuring the artist.
 * @property similarArtists Similar artist entries.
 * @property songsPlaylistId Browse id opening the full songs list, if any.
 * @property songsPlaylistParams Params for the full songs list, if any.
 * @property subscribers Subscriber-count label, or empty.
 */
data class ArtistDetail(
    val name: String,
    val description: String,
    val thumbnails: List<Thumbnail>,
    val topSongs: List<Track>,
    val albums: List<ShelfItem.Browse>,
    val singlesAndEps: List<ShelfItem.Browse> = emptyList(),
    val relatedPlaylists: List<ShelfItem.Browse> = emptyList(),
    val similarArtists: List<ShelfItem.Browse> = emptyList(),
    val songsPlaylistId: String? = null,
    val songsPlaylistParams: String? = null,
    val subscribers: String = "",
)

/** Full playlist page.
 *
 * @property title Playlist title.
 * @property subtitle Playlist subtitle/byline.
 * @property thumbnails Playlist artwork.
 * @property tracks Playlist tracks in order.
 */
data class PlaylistDetail(
    val title: String,
    val subtitle: String,
    val thumbnails: List<Thumbnail>,
    val tracks: List<Track>,
)

/** One synced lyric line.
 *
 * @property timeMs Start time in milliseconds.
 * @property text Lyric text.
 */
data class LyricLine(val timeMs: Long, val text: String)

/** Search-result category filter labels exposed by the UI. */
enum class SearchFilter(val label: String) {
    SONGS("Songs"),
    RELEASES("Albums/EP/Singles"),
    ARTISTS("Artists"),
}
