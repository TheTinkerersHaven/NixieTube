package nixietube.sys

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.forms.submitForm
import io.ktor.client.statement.bodyAsText
import io.ktor.http.parameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import nixietube.innertube.AuthSession
import nixietube.innertube.InnerTube
import java.io.File
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Properties


/** Clock skew tolerated when judging an OAuth token as still valid. */
private const val TOKEN_EXPIRY_SKEW_SEC = 120L

/** Upper bound on waiting for the browser-login callback. */
private const val MAX_POLL_DURATION_MS = 600_000L


/**
 * Google OAuth via the standard browser flow (Desktop-type clients, loopback redirect).
 *
 * Account data goes through the YouTube Data API; InnerTube from this
 * environment rejects third-party sessions. Issued tokens are persisted to
 * `~/.config/nixietube/oauth.properties` and refreshed automatically when
 * within 120s of expiry.
 *
 * @param tube InnerTube client the sessions produced here authenticate.
 */
class GoogleOAuth(private val tube: InnerTube) {
    private val http = HttpClient(CIO)
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Persisted OAuth token set for a Desktop-type client.
     *
     * @param accessToken Bearer token sent against InnerTube.
     * @param refreshToken Token used to mint new access tokens; may be blank on partial responses.
     * @param expiresAtSec Epoch seconds at which [accessToken] expires.
     */
    data class Tokens(val accessToken: String, val refreshToken: String, val expiresAtSec: Long)

    /**
     * Returns the stored OAuth client id/secret pair, or null when either is blank.
     *
     * @return The configured client credentials, or null when OAuth isn't set up.
     */
    fun savedClient(): Pair<String, String>? {
        val id = SysConfig.googleClientId
        val secret = SysConfig.googleClientSecret
        return if (id.isNotBlank() && secret.isNotBlank()) id to secret else null
    }

    // Standard browser login for Desktop-type clients ("normal" OAuth):
    // opens the Google consent page, captures the authorization code via a
    // loopback server (127.0.0.1, ephemeral port — no registered redirect
    // URI needed for installed-app clients), and exchanges it with PKCE +
    // the client secret. Web-application clients are NOT supported here:
    // they require a pre-registered redirect URI, so the loopback callback
    // fails with redirect_uri_mismatch on Google's side.
    /**
     * Runs the standard browser login for Desktop-type OAuth clients.
     *
     * Starts a loopback HTTP server, asks the caller to open the consent
     * page via [onBrowse], waits for the authorization-code callback, then
     * exchanges it (PKCE S256 + client secret) and saves the tokens.
     *
     * @param clientId Desktop-type OAuth client ID.
     * @param clientSecret OAuth client secret.
     * @param onBrowse Callback receiving the consent URL to open in a browser.
     * @param cancelled Poll abort check evaluated while waiting for the callback.
     * @return True when tokens were minted and saved.
     */
    suspend fun loginBrowser(
        clientId: String,
        clientSecret: String,
        onBrowse: (url: String) -> Unit,
        cancelled: () -> Boolean = { false },
    ): Boolean = withContext(Dispatchers.IO) {
        val verifier = newCodeVerifier()
        val challenge = codeChallenge(verifier)
        val state = newOAuthState()
        val server = try {
            java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        } catch (_: Exception) {
            return@withContext false
        }
        server.soTimeout = 1000
        val redirectUri = "http://127.0.0.1:${server.localPort}/callback"
        try {
            val authUrl = buildString {
                append("https://accounts.google.com/o/oauth2/v2/auth")
                append("?client_id=").append(enc(clientId))
                append("&redirect_uri=").append(enc(redirectUri))
                append("&response_type=code")
                append("&scope=").append(enc(SCOPE))
                append("&access_type=offline")
                append("&prompt=consent")
                append("&state=").append(enc(state))
                append("&code_challenge=").append(enc(challenge))
                append("&code_challenge_method=S256")
            }
            onBrowse(authUrl)
            val code = awaitLoopbackCode(server, state, cancelled) ?: return@withContext false
            if (cancelled()) return@withContext false
            val tokens = exchangeCode(clientId, clientSecret, code, redirectUri, verifier)
                ?: return@withContext false
            saveTokens(clientId, tokens)
            true
        } finally {
            runCatching { server.close() }
        }
    }

    // Returns a session with a valid (refreshed if needed) Bearer token,
    // or null when OAuth isn't set up. Used as InnerTube.authProvider.
    /**
     * Returns a session with a valid Bearer token, refreshing first if within 120s of expiry.
     *
     * Used as InnerTube.authProvider.
     *
     * @return An authenticated session, or null when OAuth isn't set up or refresh failed.
     */
    suspend fun validSession(): AuthSession? {
        val (clientId, tokens) = loadTokens() ?: return null
        val now = System.currentTimeMillis() / 1000
        if (tokens.expiresAtSec - now > TOKEN_EXPIRY_SKEW_SEC) {
            return AuthSession(accessToken = tokens.accessToken)
        }
        val refreshed = refresh(clientId, tokens) ?: return null
        return AuthSession(accessToken = refreshed.accessToken)
    }

    /** Deletes the persisted token file, signing the user out. */
    fun logout() {
        authFile().delete()
    }

    /**
     * Returns the current valid access token, refreshing first if needed.
     *
     * @return The Bearer token, or null when OAuth isn't set up or refresh failed.
     */
    suspend fun accessToken(): String? = validSession()?.accessToken

    /** Authorization-code exchange used by the browser (Desktop-client) flow. */
    private suspend fun exchangeCode(
        clientId: String,
        secret: String,
        code: String,
        redirectUri: String,
        codeVerifier: String? = null,
    ): Tokens? {
        return try {
            val text = http.submitForm(
                url = "https://oauth2.googleapis.com/token",
                formParameters = parameters {
                    append("code", code)
                    append("client_id", clientId)
                    append("client_secret", secret)
                    append("redirect_uri", redirectUri)
                    append("grant_type", "authorization_code")
                    if (!codeVerifier.isNullOrBlank()) append("code_verifier", codeVerifier)
                },
            ).bodyAsText()
            parseTokens(text)
        } catch (_: Exception) {
            null
        }
    }

    /** Waits for the loopback authorization-code callback; null on deny/timeout/cancel. */
    private fun awaitLoopbackCode(
        server: java.net.ServerSocket,
        expectedState: String,
        cancelled: () -> Boolean,
    ): String? {
        val deadline = System.currentTimeMillis() + MAX_POLL_DURATION_MS
        while (System.currentTimeMillis() < deadline && !cancelled()) {
            val socket = try {
                server.accept()
            } catch (_: java.net.SocketTimeoutException) {
                continue
            } catch (_: Exception) {
                return null
            }
            try {
                socket.soTimeout = 5000
                val input = socket.getInputStream().bufferedReader(Charsets.UTF_8)
                val requestLine = input.readLine() ?: continue
                // Consume the headers so the browser doesn't stall waiting.
                while (true) {
                    val header = input.readLine() ?: break
                    if (header.isEmpty()) break
                }
                val parts = requestLine.split(" ")
                if (parts.size < 2) {
                    respondLoopback(socket, 400, "Bad request.")
                    continue
                }
                val target = parts[1]
                if (!target.startsWith("/callback")) {
                    respondLoopback(socket, 404, "Not found.")
                    continue
                }
                val query = target.substringAfter("?", "")
                val params = query.split("&").mapNotNull { pair ->
                    val kv = pair.split("=", limit = 2)
                    if (kv.size == 2) {
                        URLDecoder.decode(kv[0], "UTF-8") to URLDecoder.decode(kv[1], "UTF-8")
                    } else {
                        null
                    }
                }.toMap()
                if (params["error"] != null) {
                    respondLoopback(
                        socket, 200,
                        "Sign-in denied. You can close this tab and return to NixieTube.",
                    )
                    return null
                }
                if (params["state"] != expectedState) {
                    respondLoopback(socket, 400, "State mismatch; ignoring.")
                    continue
                }
                val code = params["code"]?.takeIf { it.isNotBlank() }
                if (code == null) {
                    respondLoopback(socket, 400, "Missing code.")
                    continue
                }
                respondLoopback(
                    socket, 200,
                    "Signed in! You can close this tab and return to NixieTube.",
                )
                return code
            } catch (_: Exception) {
                // Fall through to close; keep waiting unless timed out.
            } finally {
                runCatching { socket.close() }
            }
        }
        return null
    }

    /** Sends a minimal HTML response to one loopback connection. */
    private fun respondLoopback(socket: java.net.Socket, status: Int, message: String) {
        val body = ("<html><body style=\"font-family:sans-serif\">" +
            message + "</body></html>").toByteArray(Charsets.UTF_8)
        val head = "HTTP/1.1 $status ${if (status == 200) "OK" else "Error"}\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: ${body.size}\r\n" +
            "Connection: close\r\n\r\n"
        val out = socket.getOutputStream()
        out.write(head.toByteArray(Charsets.US_ASCII))
        out.write(body)
        out.flush()
    }

    /** Generates a PKCE code verifier (unreserved chars, 64 random bytes). */
    private fun newCodeVerifier(): String {
        val bytes = ByteArray(64)
        java.security.SecureRandom().nextBytes(bytes)
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /** Derives a PKCE S256 code challenge from [verifier]. */
    private fun codeChallenge(verifier: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest(verifier.toByteArray(Charsets.US_ASCII))
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }

    /** Generates an opaque OAuth state token for CSRF protection. */
    private fun newOAuthState(): String {
        val bytes = ByteArray(16)
        java.security.SecureRandom().nextBytes(bytes)
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
    /** Refreshes the access token, preserving the old refresh token when the response omits one. */
    private suspend fun refresh(clientId: String, tokens: Tokens): Tokens? {
        val secret = SysConfig.googleClientSecret
        if (secret.isBlank()) return null
        return try {
            val text = http.submitForm(
                url = "https://oauth2.googleapis.com/token",
                formParameters = parameters {
                    append("refresh_token", tokens.refreshToken)
                    append("client_id", clientId)
                    append("client_secret", secret)
                    append("grant_type", "refresh_token")
                },
            ).bodyAsText()
            val fresh = parseTokens(text) ?: return null
            // Refresh responses usually omit a new refresh_token: keep the old one.
            val merged = if (fresh.refreshToken.isBlank()) fresh.copy(refreshToken = tokens.refreshToken) else fresh
            saveTokens(clientId, merged)
            merged
        } catch (_: Exception) {
            null
        }
    }

    /** Parses an OAuth token JSON response into [Tokens]. */
    private fun parseTokens(text: String): Tokens? {
        return try {
            val obj = json.parseToJsonElement(text).jsonObject
            val access = obj["access_token"]?.jsonPrimitive?.contentOrNull ?: return null
            val refresh = obj["refresh_token"]?.jsonPrimitive?.contentOrNull.orEmpty()
            val expiresIn = obj["expires_in"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 3600L
            Tokens(access, refresh, System.currentTimeMillis() / 1000 + expiresIn)
        } catch (_: Exception) {
            null
        }
    }

    /** Returns the token store file, creating its parent directory. */
    private fun authFile(): File =
        File(System.getProperty("user.home"), ".config/nixietube/oauth.properties").also {
            it.parentFile.mkdirs()
        }

    /** Writes tokens to the properties-backed token store. */
    private fun saveTokens(clientId: String, tokens: Tokens) {
        try {
            val p = Properties()
            p.setProperty("client_id", clientId)
            p.setProperty("access_token", tokens.accessToken)
            p.setProperty("refresh_token", tokens.refreshToken)
            p.setProperty("expires_at", tokens.expiresAtSec.toString())
            authFile().outputStream().use { p.store(it, null) }
        } catch (_: Exception) {
        }
    }

    /** Reads the stored client id and tokens, or null when absent or incomplete. */
    private fun loadTokens(): Pair<String, Tokens>? {
        val f = File(System.getProperty("user.home"), ".config/nixietube/oauth.properties")
        if (!f.exists()) return null
        return try {
            val p = Properties().also { f.inputStream().use { s -> it.load(s) } }
            val clientId = p.getProperty("client_id").orEmpty()
            val access = p.getProperty("access_token").orEmpty()
            val refresh = p.getProperty("refresh_token").orEmpty()
            val expires = p.getProperty("expires_at")?.toLongOrNull() ?: 0L
            if (clientId.isBlank() || access.isBlank()) null
            else clientId to Tokens(access, refresh, expires)
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        /** OAuth scope requested for YouTube access. */
        const val SCOPE = "https://www.googleapis.com/auth/youtube"
        /** URL-encodes a value as UTF-8 for form bodies. */
        private fun enc(s: String) = URLEncoder.encode(s, Charsets.UTF_8)
    }
}
