package nixietube.art

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsBytes
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import javax.imageio.ImageIO
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

// Pure-JVM artwork pipeline (no UI imports — reusable under any frontend).
// Memory LRU + raw disk cache, integrity-checked downloads, border stripping,
// and center-square crops for cover art. The uncropped source path is reserved
// for aspect-ratio-sensitive banners; the cropped file is exposed as a stable
// file:// URI for MPRIS.
/**
 * Pure-JVM artwork pipeline: memory LRU plus integrity-checked disk cache.
 *
 * Downloads thumbnails, strips baked-in borders, center-crops square covers,
 * and exposes stable cropped files for MPRIS.
 */
object ArtworkStore {
    private val http = HttpClient(CIO) {
        install(HttpTimeout) {
            requestTimeoutMillis = 15_000
            connectTimeoutMillis = 5_000
            socketTimeoutMillis = 15_000
        }
    }

    // Byte-bounded LRU bitmap caches. Entries vary wildly in size
    // (540px covers vs 1920px banners), so a count cap alone cannot
    // bound RSS: eviction is driven by decoded bytes instead.
    private const val COVER_CACHE_BYTES = 64L * 1024 * 1024
    private const val BANNER_CACHE_BYTES = 64L * 1024 * 1024
    private const val MAX_FAILURE_KEYS = 2000

    private val memCache: MutableMap<String, BufferedImage> =
        Collections.synchronizedMap(LinkedHashMap(160, 0.75f, true))

    // Artist headers must retain the server image's aspect ratio. Keep a
    // separate cache so a previously requested square cover cannot crop the
    // banner before it is displayed.
    private val sourceMemCache: MutableMap<String, BufferedImage> =
        Collections.synchronizedMap(LinkedHashMap(80, 0.75f, true))

    private val failures = Collections.synchronizedMap(mutableMapOf<String, Int>())
    private val sourceFailures = Collections.synchronizedMap(mutableMapOf<String, Int>())

    /** Decoded byte size of an image, assuming 4 bytes per pixel. */
    private fun BufferedImage.bytes(): Long = width.toLong() * height * 4

    /** Inserts into a byte-bounded LRU cache, evicting oldest entries over budget. */
    private fun cachePut(
        cache: MutableMap<String, BufferedImage>,
        url: String,
        img: BufferedImage,
        budgetBytes: Long,
    ) {
        synchronized(cache) {
            cache[url] = img
            var total = cache.values.sumOf { it.bytes() }
            if (total <= budgetBytes) return
            val it = cache.entries.iterator()
            while (total > budgetBytes && it.hasNext()) {
                val e = it.next()
                if (e.key == url) continue
                total -= e.value.bytes()
                it.remove()
            }
        }
    }

    /** Records a download failure for [url], evicting oldest keys past the cap. */
    private fun noteFailure(map: MutableMap<String, Int>, url: String) {
        synchronized(map) {
            map[url] = (map[url] ?: 0) + 1
            if (map.size > MAX_FAILURE_KEYS) {
                val keys = map.keys.iterator()
                repeat(map.size - MAX_FAILURE_KEYS) {
                    if (keys.hasNext()) {
                        keys.next()
                        keys.remove()
                    }
                }
            }
        }
    }

    // A player tick can ask for the same URL hundreds of times while a slow
    // thumbnail request is in flight.  Per-key mutexes prevent a request storm
    // without serializing unrelated artwork.
    private val keyLocks = ConcurrentHashMap<String, Mutex>()

    private fun cacheDir(): File =
        File(System.getProperty("user.home"), ".cache/nixietube/art2").also { it.mkdirs() }

    /** SHA-1 hex digest of a URL, used for disk cache file names. */
    private fun digest(url: String): String =
        MessageDigest.getInstance("SHA-1")
            .digest(url.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun rawFile(url: String): File = File(cacheDir(), "${digest(url)}.img")

    // Generation suffix: bump whenever the source pipeline changes what a
    // URL resolves to, so stale renders from older builds are never reused.
    private fun sourceFile(url: String): File = File(cacheDir(), "${digest(url)}.source3.img")

    private fun croppedFile(url: String): File = File(cacheDir(), "${digest(url)}.crop.png")

    /** Runs [block] under a per-URL mutex so concurrent requests for one URL coalesce. */
    private suspend fun <T> keyed(url: String, block: suspend () -> T): T {
        val lock = keyLocks.getOrPut(url) { Mutex() }
        try {
            return lock.withLock { block() }
        } finally {
            // Mutexes guard in-flight requests, not URLs: drop them so
            // the map can't grow with every distinct URL ever seen.
            keyLocks.remove(url, lock)
        }
    }

    /** Writes [bytes] to [target] via temp file plus atomic rename. */
    private fun writeAtomically(target: File, bytes: ByteArray) {
        val dir = target.parentFile ?: return
        dir.mkdirs()
        val temp = File.createTempFile(".art-", ".tmp", dir)
        try {
            temp.writeBytes(bytes)
            try {
                Files.move(
                    temp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: Exception) {
                Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    // Decoded square image, downloading when needed. Null after repeated
    // failures; callers may retry later without caching a permanent null.
    /**
     * Returns the decoded square cover for [url], downloading and caching on miss.
     *
     * @param url Image URL, or null.
     * @return Decoded square image, or null when blank or repeatedly failing.
     */
    suspend fun image(url: String?): BufferedImage? {
        if (url.isNullOrBlank()) return null
        memCache[url]?.let { return it }
        if ((failures[url] ?: 0) >= 3) return null
        return keyed(url) {
            memCache[url]?.let { return@keyed it }
            withContext(Dispatchers.IO) {
                val cached = readCachedBytes(url)
                val bytes = cached ?: run {
                    val downloaded = download(url)
                    if (downloaded != null) {
                        runCatching { writeAtomically(rawFile(url), downloaded) }
                    } else {
                        noteFailure(failures, url)
                    }
                    downloaded
                }
                bytes?.let { decode(it) }?.also { cachePut(memCache, url, it, COVER_CACHE_BYTES) }
            }
        }
    }

    /**
     * Loads the original, uncropped image for a banner. Unlike [image], this
     * prefers the URL without YouTube's square size transform and does not
     * center-crop the decoded bitmap.
     *
     * @param url Image URL, or null.
     * @return Decoded banner image at served aspect ratio, or null on failure.
     */
    suspend fun source(url: String?): BufferedImage? {
        if (url.isNullOrBlank()) return null
        sourceMemCache[url]?.let { return it }
        if ((sourceFailures[url] ?: 0) >= 3) return null
        return keyed(url) {
            sourceMemCache[url]?.let { return@keyed it }
            withContext(Dispatchers.IO) {
                val cached = readCachedBytes(sourceFile(url))
                val bytes = cached ?: run {
                    // Banners: the stripped "original" URL often serves a
                    // small default rendition, so ask for a large one first
                    // and only fall back down from there.
                    val candidates = linkedSetOf(
                        upscaleArtworkUrl(url, 1920),
                        url,
                        originalArt(url),
                    )
                    var downloaded: ByteArray? = null
                    for (candidate in candidates) {
                        downloaded = tryDownload(candidate)
                        if (downloaded != null) break
                    }
                    if (downloaded != null) {
                        runCatching { writeAtomically(sourceFile(url), downloaded) }
                    } else {
                        noteFailure(sourceFailures, url)
                    }
                    downloaded
                }
                // Banners render as-served: border stripping is for
                // letterboxed video frames and eats dark banner edges.
                bytes?.let { decode(it, cropSquare = false, stripBorders = false) }
                    ?.also { cachePut(sourceMemCache, url, it, BANNER_CACHE_BYTES) }
            }
        }
    }

    // Rewrites Google image size params upward (proportionally when the
    // current size is known) or appends a width-only request. Never
    // downscales; unknown shapes pass through for the caller to handle.
    /** Rewrites Google image size params up to [targetWidth]; never downscales. */
    private fun upscaleArtworkUrl(url: String, targetWidth: Int): String {
        val match = Regex("""=w(\d+)(?:-h(\d+))?""").find(url)
            ?: return "$url=w$targetWidth"
        val w = match.groupValues[1].toIntOrNull() ?: 0
        if (w >= targetWidth) return url
        val h = match.groupValues[2].toIntOrNull() ?: 0
        val replacement = if (w > 0 && h > 0) {
            "=w$targetWidth-h${(targetWidth.toLong() * h / w).toInt().coerceAtLeast(1)}"
        } else {
            "=w$targetWidth"
        }
        return url.replaceRange(match.range, replacement)
    }

    // Ensures a cropped, stable file exists for MPRIS. The returned file is
    // always square; the original download remains in the raw cache for the
    // normal image path.
    /**
     * Returns the stable cropped PNG file for [url], rendering it on first use.
     *
     * @param url Image URL, or null.
     * @return Square PNG file for MPRIS, or null on failure.
     */
    suspend fun file(url: String?): File? {
        if (url.isNullOrBlank()) return null
        return keyed(url) {
            withContext(Dispatchers.IO) {
                val target = croppedFile(url)
                if (target.isFile && target.length() > 0L) return@withContext target

                val cached = readCachedBytes(url)
                val bytes = cached ?: run {
                    val downloaded = download(url)
                    if (downloaded != null) {
                        runCatching { writeAtomically(rawFile(url), downloaded) }
                    } else {
                        noteFailure(failures, url)
                    }
                    downloaded
                } ?: return@withContext null

                val image = decode(bytes) ?: run {
                    noteFailure(failures, url)
                    return@withContext null
                }
                val out = ByteArrayOutputStream()
                if (!ImageIO.write(image, "png", out)) {
                    noteFailure(failures, url)
                    return@withContext null
                }
                runCatching { writeAtomically(target, out.toByteArray()) }
                    .onFailure { return@withContext null }
                cachePut(memCache, url, image, COVER_CACHE_BYTES)
                target
            }
        }
    }

    // Disk file only if already present — safe to call on D-Bus/IPC threads.
    /**
     * Returns the cropped file for [url] only if already rendered on disk.
     *
     * @param url Image URL, or null.
     * @return Existing cropped PNG file, or null when absent.
     */
    fun cachedFile(url: String?): File? {
        if (url.isNullOrBlank()) return null
        return croppedFile(url).takeIf { it.isFile && it.length() > 0L }
    }

    private fun readCachedBytes(url: String): ByteArray? =
        readCachedBytes(rawFile(url))

    private fun readCachedBytes(disk: File): ByteArray? {
        if (!disk.isFile) return null
        return try {
            val raw = disk.readBytes()
            if (!looksComplete(raw)) {
                disk.delete()
                null
            } else {
                raw
            }
        } catch (_: Exception) {
            runCatching { disk.delete() }
            null
        }
    }

    /** Decodes [bytes], optionally stripping borders and center-cropping to square. */
    private fun decode(
        bytes: ByteArray,
        cropSquare: Boolean = true,
        stripBorders: Boolean = true,
    ): BufferedImage? {
        return try {
            ByteArrayInputStream(bytes).use { ImageIO.read(it) }
                ?.let { if (stripBorders) stripBorders(it, cropSquare) else it }
        } catch (_: Exception) {
            null
        }
    }

    /** Downloads [url], first trying the upscaled variant when it differs. */
    private suspend fun download(url: String): ByteArray? {
        val upgraded = upgradeArt(url)
        if (upgraded != url) {
            tryDownload(upgraded)?.let { return it }
        }
        return tryDownload(url)
    }

    /** GETs [url], rejecting tiny or truncated payloads. */
    private suspend fun tryDownload(url: String): ByteArray? {
        return try {
            http.get(url).bodyAsBytes()
                .takeIf { it.size > 100 }
                ?.takeIf { looksComplete(it) }
        } catch (_: Exception) {
            null
        }
    }

    // Truncated downloads decode into partial (gray-banded) images and would
    // poison the disk cache — reject them up front. JPEG must end with EOI;
    // anything else goes through the decoder's verdict.
    /** Checks payload completeness (JPEG must end with EOI) to keep partial downloads out of cache. */
    private fun looksComplete(bytes: ByteArray): Boolean {
        if (bytes.size < 4) return false
        val isJpeg = bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()
        if (!isJpeg) return true
        val n = bytes.size
        return bytes[n - 2] == 0xFF.toByte() && bytes[n - 1] == 0xD9.toByte()
    }

    // Detects the uniform border color from the corners and crops to the
    // content box (baked-in letterbox/pillarbox bars). Cover art uses the
    // historical center-square result; banners keep the content aspect ratio.
    /** Crops uniform letterbox/pillarbox borders, then optionally center-squares the content. */
    private fun stripBorders(img: BufferedImage, cropSquare: Boolean): BufferedImage {
        return try {
            val w = img.width
            val h = img.height
            if (w < 8 || h < 8) return if (cropSquare) centerSquare(img) else img
            val edge = img.getRGB(0, 0)
            fun similar(rgb: Int): Boolean {
                val dr = ((rgb shr 16) and 0xFF) - ((edge shr 16) and 0xFF)
                val dg = ((rgb shr 8) and 0xFF) - ((edge shr 8) and 0xFF)
                val db = (rgb and 0xFF) - (edge and 0xFF)
                return dr * dr + dg * dg + db * db < 14 * 14 * 3
            }
            fun rowIsBorder(y: Int): Boolean {
                var diff = 0
                var total = 0
                var x = 0
                while (x < w) {
                    total++
                    if (!similar(img.getRGB(x, y))) diff++
                    x += 4
                }
                return diff * 20 < total
            }
            fun colIsBorder(x: Int): Boolean {
                var diff = 0
                var total = 0
                var y = 0
                while (y < h) {
                    total++
                    if (!similar(img.getRGB(x, y))) diff++
                    y += 4
                }
                return diff * 20 < total
            }
            var top = 0
            while (top < h / 2 && rowIsBorder(top)) top++
            var bottom = h - 1
            while (bottom > top && rowIsBorder(bottom)) bottom--
            var left = 0
            while (left < w / 2 && colIsBorder(left)) left++
            var right = w - 1
            while (right > left && colIsBorder(right)) right--
            val cw = right - left + 1
            val ch = bottom - top + 1
            if (cw < w / 2 || ch < h / 2) {
                return if (cropSquare) centerSquare(img) else img
            }
            val content = img.getSubimage(left, top, cw, ch)
            if (cropSquare) centerSquare(content) else content
        } catch (_: Exception) {
            if (cropSquare) centerSquare(img) else img
        }
    }

    /** Crops [img] to its centered square. */
    private fun centerSquare(img: BufferedImage): BufferedImage {
        val side = minOf(img.width, img.height)
        if (side <= 0) return img
        if (side == img.width && side == img.height) return img
        val x = (img.width - side) / 2
        val y = (img.height - side) / 2
        return img.getSubimage(x, y, side, side)
    }

    // Ask for a bigger thumbnail than the default w60/w120 stubs. Only
    // rewrites lh3-style size params; anything else passes through.
    private val sizeParamRe = Regex("""=w\d+-h\d+[^?]*$""")
    private val sourceSizeParamRe = Regex("""=w\d+-h\d+[^?]*""")

    private fun originalArt(url: String): String = sourceSizeParamRe.replace(url, "")

    /**
     * Rewrites a thumbnail URL to request a 540px cover; other URLs pass through.
     *
     * @param url Original artwork URL.
     * @return Upgraded URL, or [url] unchanged when no size param is present.
     */
    fun upgradeArt(url: String): String {
        if (!sizeParamRe.containsMatchIn(url)) return url
        return sizeParamRe.replace(url, "=w540-h540-l90-rj")
    }
}
