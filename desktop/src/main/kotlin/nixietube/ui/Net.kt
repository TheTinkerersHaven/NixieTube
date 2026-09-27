package nixietube.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsBytes
import io.ktor.http.HttpHeaders
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import nixietube.art.ArtworkStore
import nixietube.innertube.LyricLine
import java.awt.image.BufferedImage
import java.net.URLEncoder
import java.util.Collections

/** Shared Ktor client for artwork, lyrics and other lightweight network fetches. */
val http = HttpClient(CIO) {
    install(HttpTimeout) {
        requestTimeoutMillis = 12_000
        connectTimeoutMillis = 4_000
        socketTimeoutMillis = 12_000
    }
}

// Fetches, decodes and caches artwork via the shared store; converts to a
// Compose bitmap at the boundary. No permanent nulls: failures retry.
/**
 * Remembers the cropped Compose bitmap for an artwork URL, loading it off the main thread.
 *
 * @param url artwork URL to load, or null to resolve to null.
 * @return the decoded image, or null while loading or on failure.
 */
@Composable
fun rememberArtwork(url: String?): ImageBitmap? {
    var bitmap by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(url) {
        if (url.isNullOrBlank()) return@LaunchedEffect
        bitmap = withContext(Dispatchers.IO) {
            try {
                ArtworkStore.image(url)?.toComposeImageBitmap()
            } catch (_: Exception) {
                null
            }
        }
    }
    return bitmap
}

// Cover palette for tinted backdrops: average colors of the top, middle
// and bottom horizontal bands. Decoded from the cached AWT image
// (reliable channel order), downscaled before sampling, and cached per
// URL. Empty until the artwork loads or when sampling fails.
/** Per-URL cache of sampled cover palettes backing [rememberCoverPalette]. */
private val coverPaletteCache: MutableMap<String, List<Color>> =
    Collections.synchronizedMap(mutableMapOf())

/**
 * Remembers the three-band cover palette for an artwork URL, sampling it off the main thread.
 *
 * @param url artwork URL to sample, or null to resolve to an empty palette.
 * @return top/middle/bottom average colors, or empty until the artwork loads.
 */
@Composable
fun rememberCoverPalette(url: String?): List<Color> {
    var palette by remember(url) { mutableStateOf(coverPaletteCache[url].orEmpty()) }
    LaunchedEffect(url) {
        if (url.isNullOrBlank()) return@LaunchedEffect
        coverPaletteCache[url]?.let {
            palette = it
            return@LaunchedEffect
        }
        palette = withContext(Dispatchers.IO) {
            try {
                coverBands(ArtworkStore.image(url))
            } catch (_: Exception) {
                emptyList()
            }
        }
        coverPaletteCache[url] = palette
    }
    return palette
}

/** Averages the top/middle/bottom horizontal bands of [img] into three colors. */
private fun coverBands(img: BufferedImage?): List<Color> {
    if (img == null || img.width <= 0 || img.height <= 0) return emptyList()
    val size = 48
    val thumb = BufferedImage(size, size, BufferedImage.TYPE_INT_RGB)
    val graphics = thumb.createGraphics()
    graphics.drawImage(img, 0, 0, size, size, null)
    graphics.dispose()
    val third = size / 3
    return (0 until 3).map { band ->
        var red = 0L
        var green = 0L
        var blue = 0L
        var n = 0L
        for (y in band * third until (band + 1) * third) {
            for (x in 0 until size) {
                val px = thumb.getRGB(x, y)
                red += (px shr 16) and 0xFF
                green += (px shr 8) and 0xFF
                blue += px and 0xFF
                n++
            }
        }
        Color((red / n).toInt() / 255f, (green / n).toInt() / 255f, (blue / n).toInt() / 255f)
    }
}

/**
 * Remembers the uncropped source bitmap for aspect-ratio-sensitive headers.
 *
 * @param url artwork URL to load, or null to resolve to null.
 * @return the decoded image, or null while loading or on failure.
 */
@Composable
fun rememberSourceArtwork(url: String?): ImageBitmap? {
    var bitmap by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(url) {
        if (url.isNullOrBlank()) return@LaunchedEffect
        bitmap = withContext(Dispatchers.IO) {
            try {
                ArtworkStore.source(url)?.toComposeImageBitmap()
            } catch (_: Exception) {
                null
            }
        }
    }
    return bitmap
}

private val lenientJson = Json { ignoreUnknownKeys = true }

// Timed lyrics from the public LRCLIB API (no key required), plus the
// provider's album name (used only as a fallback; YouTube metadata is
// preferred for release kind and canonical album IDs).
/**
 * Fetches lyrics from LRCLIB, preferring a direct match and falling back to the best search hit.
 *
 * @param artist artist name to query.
 * @param title track title to query.
 * @param album album name hint, blank when unknown.
 * @param durationSec expected duration used to rank candidates, 0 when unknown.
 * @return the lyric lines with the provider's album name, or empty lines when nothing matches.
 */
suspend fun fetchLyricsAndAlbum(
    artist: String,
    title: String,
    album: String,
    durationSec: Int,
): Pair<List<LyricLine>, String?> =
    withContext(Dispatchers.IO) {
        try {
            val albumParam = if (album.isNotBlank()) "&album_name=${enc(album)}" else ""
            val dur = if (durationSec > 0) "&duration=$durationSec" else ""
            val q = "artist_name=${enc(artist)}&track_name=${enc(title)}$albumParam$dur"
            val direct = tryGet("https://lrclib.net/api/get?$q")
            val directAlbum = direct?.takeIf { it.matches(title, artist) }?.album
            if (direct != null && direct.matches(title, artist) && direct.lines.isNotEmpty()) {
                return@withContext direct.lines to direct.album
            }

            val sq = "track_name=${enc(title)}&artist_name=${enc(artist)}"
            val res = http.get("https://lrclib.net/api/search?$sq") {
                header(HttpHeaders.UserAgent, "NixieTube/1.0")
            }.bodyAsBytes()
            val arr = lenientJson.parseToJsonElement(String(res)) as? kotlinx.serialization.json.JsonArray
                ?: return@withContext emptyList<LyricLine>() to directAlbum

            val candidates = arr.mapNotNull { candidateFrom(it) }
                .filter { it.matches(title, artist) }
            val best = candidates.maxWithOrNull(
                compareBy<Candidate> {
                    if (it.lines.any { line -> line.timeMs >= 0 }) 1 else 0
                }.thenBy {
                    if (durationSec > 0 && it.durationSec > 0) {
                        100 - kotlin.math.abs(it.durationSec - durationSec).coerceAtMost(100)
                    } else {
                        0
                    }
                }.thenBy { if (it.album.isNullOrBlank()) 0 else 1 },
            )
            best?.let { return@withContext it.lines to (it.album ?: directAlbum) }
            emptyList<LyricLine>() to directAlbum
        } catch (_: Exception) {
            emptyList<LyricLine>() to null
        }
    }

/**
 * Fetches lyric lines from LRCLIB for the given track metadata.
 *
 * @param artist artist name to query.
 * @param title track title to query.
 * @param album album name hint, blank when unknown.
 * @param durationSec expected duration used to rank candidates, 0 when unknown.
 * @return the lyric lines, or empty when nothing matches.
 */
suspend fun fetchLyrics(artist: String, title: String, album: String, durationSec: Int): List<LyricLine> =
    fetchLyricsAndAlbum(artist, title, album, durationSec).first

/** Fetches and parses a single LRCLIB response, or null on failure. */
private suspend fun tryGet(url: String): Candidate? {
    return try {
        val bytes = http.get(url) {
            header(HttpHeaders.UserAgent, "NixieTube/1.0")
        }.bodyAsBytes()
        candidateFrom(lenientJson.parseToJsonElement(String(bytes)))
    } catch (_: Exception) {
        null
    }
}

/** One LRCLIB lyric candidate with the metadata used to rank it against the request. */
private data class Candidate(
    val lines: List<LyricLine>,
    val album: String?,
    val title: String,
    val artist: String,
    val durationSec: Int,
) {
    /** Returns true when this candidate's title/artist match the requested track. */
    fun matches(requestedTitle: String, requestedArtist: String): Boolean {
        if (normalizeLrc(title) != normalizeLrc(requestedTitle)) return false
        val requested = normalizeLrc(requestedArtist)
        val actual = normalizeLrc(artist)
        if (requested.isBlank() || actual.isBlank()) return requested.isBlank()
        if (requested == actual) return true
        val requestedTokens = requested.split(' ').filter { it.isNotBlank() }.toSet()
        val actualTokens = actual.split(' ').filter { it.isNotBlank() }.toSet()
        return requestedTokens.isNotEmpty() && actualTokens.containsAll(requestedTokens)
    }
}

/** Builds a [Candidate] from one LRCLIB JSON object, or null when title/artist are missing. */
private fun candidateFrom(el: kotlinx.serialization.json.JsonElement): Candidate? {
    val obj = el as? kotlinx.serialization.json.JsonObject ?: return null
    val title = obj["trackName"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
    val artist = obj["artistName"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
    if (title.isBlank() || artist.isBlank()) return null
    val album = obj["albumName"]?.jsonPrimitive?.contentOrNull?.trim()?.takeIf { it.isNotBlank() }
    val duration = obj["duration"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()?.toInt() ?: 0
    return Candidate(lyricsFrom(el), album, title, artist, duration)
}

/** Normalizes a title/artist for fuzzy matching by stripping features, editions and punctuation. */
private fun normalizeLrc(value: String): String {
    var n = value.lowercase()
    n = n.replace(Regex("""\s*[\(\[]?(feat\.?|ft\.?|with|con)\b[^)\]]*[\)\]]?"""), "")
    n = n.replace(
        Regex("""\s*[-–—]\s*(remaster|remix|edit|live|acoustic|sped up|slowed|mix|version|single|ep)\b.*$"""),
        "",
    )
    return n.replace(Regex("[^a-z0-9 ]"), "")
        .replace(Regex("\\s+"), " ")
        .trim()
}

/** Extracts lyric lines from one LRCLIB JSON object, preferring synced over plain lyrics. */
private fun lyricsFrom(el: kotlinx.serialization.json.JsonElement): List<LyricLine> {
    val obj = el as? kotlinx.serialization.json.JsonObject ?: return emptyList()
    val synced = obj["syncedLyrics"]?.jsonPrimitive?.contentOrNull
    if (!synced.isNullOrBlank()) {
        val parsed = parseLrc(synced)
        if (parsed.isNotEmpty()) return parsed
    }
    val plain = obj["plainLyrics"]?.jsonPrimitive?.contentOrNull
    if (!plain.isNullOrBlank()) {
        return plain.lines().filter { it.isNotBlank() }.map { LyricLine(-1, it) }
    }
    return emptyList()
}

/** URL-encodes [s] as UTF-8 for LRCLIB query parameters. */
private fun enc(s: String) = URLEncoder.encode(s, Charsets.UTF_8)

private val LRC_RE = Regex("""\[(\d+):(\d+)(?:[.:](\d+))?](.*)""")

/**
 * Parses synced `[mm:ss.xx] text` lyric lines, skipping blank or malformed rows.
 *
 * @param lrc raw LRC text.
 * @return timed lyric lines in file order.
 */
fun parseLrc(lrc: String): List<LyricLine> = lrc.lines().mapNotNull { line ->
    val m = LRC_RE.find(line.trim()) ?: return@mapNotNull null
    val min = m.groupValues[1].toLongOrNull() ?: return@mapNotNull null
    val sec = m.groupValues[2].toLongOrNull() ?: return@mapNotNull null
    val frac = m.groupValues[3].padEnd(3, '0').take(3).toLongOrNull() ?: 0L
    val text = m.groupValues[4].trim()
    if (text.isBlank()) return@mapNotNull null
    LyricLine(min * 60_000 + sec * 1000 + frac, text)
}
