package nixietube.sys

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.forms.submitForm
import io.ktor.client.request.header
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
import java.net.URLEncoder
import java.util.Properties


// Google OAuth via the TV-device flow (client type "TVs and Limited Input
// devices"). music.youtube.com's InnerTube only accepts Bearer tokens minted
// for TV-device clients — Desktop-type clients get HTTP 400 on every call.
// Tokens are used directly against InnerTube (youtubei), which accepts
// `Authorization: Bearer`.
/**
 * Google OAuth via the TV-device flow (client type "TVs and Limited Input devices").
 *
 * music.youtube.com's InnerTube only accepts Bearer tokens minted for TV-device
 * clients — Desktop-type clients get HTTP 400 on every call. Tokens are used
 * directly against InnerTube (youtubei), which accepts `Authorization: Bearer`.
 * Issued tokens are persisted to `~/.config/nixietube/oauth.properties` and
 * refreshed automatically when within 120s of expiry.
 *
 * @param tube InnerTube client the sessions produced here authenticate.
 */
class GoogleOAuth(private val tube: InnerTube) {
    private val http = HttpClient(CIO)
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Persisted OAuth token set for a TV-device client.
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

    // Full interactive login: shows a user code, opens the verification page,
    // polls until granted. Returns true when tokens were minted; the caller
    // verifies via the Data API (InnerTube rejects these tokens here).
    /**
     * Runs the full interactive login: shows a user code, then polls until granted.
     *
     * The caller verifies the minted tokens via the Data API (InnerTube rejects
     * these tokens at this stage of the flow).
     *
     * @param clientId TV-device OAuth client ID.
     * @param clientSecret TV-device OAuth client secret.
     * @param onUserCode Callback receiving the user code and verification URL to show the user.
     * @param cancelled Poll abort check evaluated before each poll attempt.
     * @return True when tokens were minted and saved.
     */
    suspend fun loginDevice(
        clientId: String,
        clientSecret: String,
        onUserCode: (userCode: String, verifyUrl: String) -> Unit,
        cancelled: () -> Boolean = { false },
    ): Boolean = withContext(Dispatchers.IO) {
        val device = requestDeviceCode(clientId) ?: return@withContext false
        onUserCode(device.userCode, device.verifyUrlComplete ?: device.verifyUrl)
        val tokens = pollForTokens(clientId, clientSecret, device, cancelled) ?: return@withContext false
        saveTokens(clientId, tokens)
        true
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
        if (tokens.expiresAtSec - now > 120) {
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

    /** Device-code step state returned by the TV-device code endpoint. */
    private data class DeviceCode(
        val deviceCode: String,
        val userCode: String,
        val verifyUrl: String,
        val verifyUrlComplete: String?,
        val expiresIn: Long,
        val interval: Long,
    )

    /** Requests a user/device code pair from the TV-device code endpoint. */
    private suspend fun requestDeviceCode(clientId: String): DeviceCode? {
        return try {
            val text = http.submitForm(
                url = "https://www.youtube.com/o/oauth2/device/code",
                formParameters = parameters {
                    append("client_id", clientId)
                    append("scope", SCOPE)
                },
            ) {
                header("User-Agent", OAUTH_USER_AGENT)
            }.bodyAsText()
            val obj = json.parseToJsonElement(text).jsonObject
            DeviceCode(
                deviceCode = obj["device_code"]?.jsonPrimitive?.contentOrNull ?: return null,
                userCode = obj["user_code"]?.jsonPrimitive?.contentOrNull ?: return null,
                verifyUrl = obj["verification_url"]?.jsonPrimitive?.contentOrNull
                    ?: "https://www.google.com/device",
                verifyUrlComplete = obj["verification_url_complete"]?.jsonPrimitive?.contentOrNull,
                expiresIn = obj["expires_in"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 1800L,
                interval = obj["interval"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 5L,
            )
        } catch (_: Exception) {
            null
        }
    }

    /** Polls the legacy TV-device grant until approved, denied, expired, or cancelled. */
    private suspend fun pollForTokens(
        clientId: String,
        clientSecret: String,
        device: DeviceCode,
        cancelled: () -> Boolean,
    ): Tokens? {
        val deadline = System.currentTimeMillis() + (device.expiresIn * 1000).coerceAtMost(600_000)
        var intervalMs = (device.interval.coerceAtLeast(5)) * 1000
        while (System.currentTimeMillis() < deadline && !cancelled()) {
            kotlinx.coroutines.delay(intervalMs)
            try {
                // Legacy TV-device grant (not the RFC 8628 device_code grant).
                val text = http.submitForm(
                    url = "https://oauth2.googleapis.com/token",
                    formParameters = parameters {
                        append("client_id", clientId)
                        append("client_secret", clientSecret)
                        append("code", device.deviceCode)
                        append("grant_type", "http://oauth.net/grant_type/device/1.0")
                    },
                ) {
                    header("User-Agent", OAUTH_USER_AGENT)
                }.bodyAsText()
                val obj = json.parseToJsonElement(text).jsonObject
                if (obj["access_token"] != null) {
                    return parseTokens(text)
                }
                when (obj["error"]?.jsonPrimitive?.contentOrNull) {
                    "authorization_pending" -> Unit // keep polling
                    "slow_down" -> intervalMs += 5000
                    else -> return null // access_denied, expired_token, …
                }
            } catch (_: Exception) {
                return null
            }
        }
        return null
    }

    /** Legacy browser-redirect code exchange; kept for reference, unused by [loginDevice]. */
    private suspend fun exchangeCode(clientId: String, secret: String, code: String, redirectUri: String): Tokens? {
        // Legacy browser-redirect flow; kept for reference, unused by loginDevice.
        return try {
            val text = http.submitForm(
                url = "https://oauth2.googleapis.com/token",
                formParameters = parameters {
                    append("code", code)
                    append("client_id", clientId)
                    append("client_secret", secret)
                    append("redirect_uri", redirectUri)
                    append("grant_type", "authorization_code")
                },
            ).bodyAsText()
            parseTokens(text)
        } catch (_: Exception) {
            null
        }
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
        /** Browser-like User-Agent required by the TV-device OAuth endpoints. */
        const val OAUTH_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0 Cobalt/Version"
        /** URL-encodes a value as UTF-8 for form bodies. */
        private fun enc(s: String) = URLEncoder.encode(s, Charsets.UTF_8)
    }
}
