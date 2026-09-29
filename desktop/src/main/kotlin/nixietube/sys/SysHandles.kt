package nixietube.sys

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Handles owned by Main and exposed to the UI for the integrations card.
 *
 * Mirrors [MprisService] and [DiscordPresence] state into observable flows
 * for the settings UI, and applies user toggles back to the services.
 *
 * @param mpris MPRIS D-Bus service being mirrored.
 * @param discord Discord Rich Presence client being mirrored.
 * @param isLinux Whether MPRIS controls are applicable on this platform.
 * @param scope Scope used for the state-mirroring collectors.
 */
// Handles owned by Main, exposed to the UI for the integrations card.
class SysHandles(
    val mpris: MprisService,
    val discord: DiscordPresence,
    val lastfm: LastFm,
    val isLinux: Boolean,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val _mprisActive = MutableStateFlow(false)
    /** Whether the MPRIS service is currently active. */
    val mprisActive: StateFlow<Boolean> = _mprisActive.asStateFlow()

    private val _discordStatus = MutableStateFlow("disabled")
    /** Latest Discord presence status string polled from the presence client. */
    val discordStatus: StateFlow<String> = _discordStatus.asStateFlow()

    private val _mprisError = MutableStateFlow<String?>(null)
    /** Last MPRIS startup error, or null when healthy. */
    val mprisError: StateFlow<String?> = _mprisError.asStateFlow()

    private val _lastfmStatus = MutableStateFlow("disabled")
    /** Latest Last.fm state mirrored from the client. */
    val lastfmStatus: StateFlow<String> = _lastfmStatus.asStateFlow()

    /**
     * Publishes an MPRIS error for the UI to display.
     *
     * @param msg Error message, or null to clear the current error.
     */
    fun setMprisError(msg: String?) {
        _mprisError.value = msg
    }

    init {
        scope.launch {
            mpris.activeState.collect { active ->
                _mprisActive.value = active
                if (active) _mprisError.value = null
            }
        }
        scope.launch {
            discord.let {
                while (true) {
                    kotlinx.coroutines.delay(2000)
                    _discordStatus.value = it.status
                }
            }
        }
        lastfm.refreshStatus()
        scope.launch {
            lastfm.let {
                while (true) {
                    kotlinx.coroutines.delay(2000)
                    _lastfmStatus.value = it.status
                }
            }
        }
    }

    /** Re-reads the live MPRIS state into [mprisActive] after an out-of-band change. */
    fun refreshMprisState() {
        _mprisActive.value = mpris.active
    }

    /**
     * Persists the MPRIS toggle and starts or stops the service (Linux only).
     *
     * Records a descriptive error in [mprisError] when startup fails,
     * e.g. when another copy already owns the bus name.
     *
     * @param enabled Whether the MPRIS service should run.
     */
    fun setMprisEnabled(enabled: Boolean) {
        SysConfig.mprisEnabled = enabled
        setMprisError(null)
        if (!isLinux) return
        if (enabled) {
            if (mpris.start()) {
                _mprisActive.value = true
            } else {
                _mprisActive.value = false
                setMprisError((mpris.lastError ?: "failed to start") + ", is another copy running?")
            }
        } else {
            mpris.stop()
            _mprisActive.value = false
        }
    }

    /**
     * Persists Discord settings, forces the presence client to reconnect, and refreshes [discordStatus].
     *
     * @param appId Discord application ID.
     * @param enabled Whether Rich Presence should run.
     * @param statusText Which text mode to show as the activity name.
     */
    fun saveDiscord(
        appId: String,
        enabled: Boolean,
        statusText: String = SysConfig.discordStatusText,
    ) {
        SysConfig.discordAppId = appId.trim()
        SysConfig.discordEnabled = enabled
        SysConfig.discordStatusText = statusText
        discord.invalidate()
        _discordStatus.value = discord.status
    }

    /**
     * Persists Last.fm credentials and toggle, refreshing the mirrored status.
     *
     * Changing key/secret signs out the stored session since it belongs to
     * the previous application.
     *
     * @param apiKey Last.fm API key.
     * @param secret Last.fm shared secret.
     * @param enabled Whether scrobbling should run.
     */
    fun saveLastFm(apiKey: String, secret: String, enabled: Boolean) {
        if (apiKey.trim() != SysConfig.lastfmApiKey || secret.trim() != SysConfig.lastfmSecret) {
            lastfm.logout()
        }
        SysConfig.lastfmApiKey = apiKey.trim()
        SysConfig.lastfmSecret = secret.trim()
        SysConfig.lastfmEnabled = enabled
        lastfm.refreshStatus()
        _lastfmStatus.value = lastfm.status
    }

    /** Signs out of Last.fm, keeping key/secret for the next login. */
    fun logoutLastFm() {
        lastfm.logout()
        _lastfmStatus.value = lastfm.status
    }
}
