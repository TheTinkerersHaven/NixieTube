package nixietube.innertube

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.localization.Localization
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

// Resolves a playable audio-stream URL for a videoId.
// NewPipeExtractor handles YouTube's throttling-parameter deciphering,
// which raw InnerTube player responses leave to the client.
object StreamResolver {
    /** One-time NewPipe setup guard. */
    private val initialized = AtomicBoolean(false)

    /** Initializes NewPipe exactly once with a URL-connection downloader. */
    private fun ensureInit() {
        if (initialized.compareAndSet(false, true)) {
            NewPipe.init(UrlConnectionDownloader(), Localization.DEFAULT)
        }
    }

    /**
     * Highest-bitrate audio stream found for a video, with public counters.
     *
     * @property url Direct stream URL.
     * @property bitrate Average bitrate in bits per second.
     * @property codec Stream codec label, or null when unknown.
     * @property likes Like count, or -1 when unknown.
     * @property dislikes Dislike count, or -1 when unknown.
     */
    data class ResolvedStream(
        val url: String,
        val bitrate: Int,
        val codec: String?,
        val likes: Long = -1L,
        val dislikes: Long = -1L,
    )

    /**
     * Fetches the page for [videoId] and picks the highest-bitrate audio stream.
     *
     * @param videoId YouTube video id to resolve.
     * @return the resolved stream, or null when extraction fails.
     */
    suspend fun resolve(videoId: String): ResolvedStream? = withContext(Dispatchers.IO) {
        try {
            ensureInit()
            val service = NewPipe.getService(0)
            val extractor = service.getStreamExtractor("https://music.youtube.com/watch?v=$videoId")
            extractor.fetchPage()
            extractor.audioStreams
                .filter { it.content.isNotBlank() }
                .maxByOrNull { it.averageBitrate }
                ?.let { stream ->
                    val likes = runCatching { extractor.likeCount }.getOrDefault(-1L)
                    val dislikes = runCatching { extractor.dislikeCount }.getOrDefault(-1L)
                    ResolvedStream(stream.content, stream.averageBitrate, stream.codec, likes, dislikes)
                }
        } catch (_: Exception) {
            null
        }
    }

    /** NewPipe HTTP downloader backed by [HttpURLConnection]. */
    private class UrlConnectionDownloader : Downloader() {
        /**
         * Executes a NewPipe [request] and returns the raw HTTP [Response].
         *
         * @param request the NewPipe download request.
         * @return the HTTP response with status code, headers, and body.
         */
        override fun execute(request: Request): Response {
            val conn = URL(request.url()).openConnection() as HttpURLConnection
            conn.requestMethod = request.httpMethod()
            conn.connectTimeout = 15_000
            conn.readTimeout = 15_000
            conn.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            )
            request.headers()?.forEach { (name, values) ->
                values.forEach { conn.addRequestProperty(name, it) }
            }
            request.dataToSend()?.let { body ->
                conn.doOutput = true
                conn.outputStream.use { it.write(body) }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            val headers = conn.headerFields
                .filterKeys { it != null }
                .mapKeys { it.key!! }
            return Response(code, conn.responseMessage, headers, text, conn.url.toString())
        }
    }
}
