package nixietube

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import nixietube.innertube.InnerTube
import nixietube.player.MpvPlayerEngine
import nixietube.player.PlayerController
import nixietube.player.PlayerEngine
import nixietube.sys.DiscordPresence
import nixietube.sys.GoogleOAuth
import nixietube.sys.MprisService
import nixietube.sys.SysConfig
import nixietube.sys.SysHandles
import nixietube.ui.App
import nixietube.ui.AppState
import kotlin.time.Duration.Companion.milliseconds

/** True when running on Linux, where MPRIS and .desktop integration apply. */
private val isLinux = System.getProperty("os.name").lowercase().contains("linux")

/**
 * User-facing build tag, bumped on every user-facing fix to identify the running build.
 */
const val BUILD_TAG = "dev-72"

// Shells resolve the player entry (icon, actions) through the DesktopEntry
// name; without an installed .desktop file some panels degrade it.
/**
 * Installs `~/.local/share/applications/nixietube.desktop` when missing or stale.
 *
 * Shells resolve the player entry (icon, actions) through the DesktopEntry name;
 * without an installed .desktop file some panels degrade it.
 */
private fun installDesktopEntry() {
    try {
        val target = java.io.File(
            System.getProperty("user.home"),
            ".local/share/applications/nixietube.desktop",
        )
        val needsInstall = !target.exists() || runCatching {
            val lines = target.readText().lineSequence().toSet()
            "Exec=nixietube" !in lines || "Name=NixieTube" !in lines
        }.getOrDefault(true)
        if (needsInstall) {
            target.parentFile.mkdirs()
            target.writeText(
                """
                [Desktop Entry]
                Type=Application
                Name=NixieTube
                Comment=Native YouTube Music client
                Exec=nixietube
                Icon=audio-x-generic
                Categories=Audio;Music;AudioVideo;
                StartupNotify=true
                Terminal=false
                """.trimIndent(),
            )
        }
    } catch (_: Exception) {
    }
}

/**
 * Application entry point: selects the audio backend, wires player/services/UI state,
 * restores the previous session, starts MPRIS (Linux) and Discord presence, and opens
 * the main window. A shutdown hook persists the session and releases integrations.
 */
fun main() {
    Thread.setDefaultUncaughtExceptionHandler { t, e ->
        System.err.println("UNCAUGHT on ${t.name}: $e")
        e.printStackTrace()
    }
    val tube = InnerTube()
    val engine: PlayerEngine = if (MpvPlayerEngine.isAvailable()) {
        MpvPlayerEngine().also { println("Audio backend: mpv") }
    } else {
        System.err.println("mpv not found; audio backend unavailable.")
        MpvPlayerEngine(audioOutput = "null").also { println("Audio backend: mpv (no audio)") }
    }
    val player = PlayerController(engine, tube)
    val sysScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    var quitApp: () -> Unit = {}
    val mpris = MprisService(player, onQuit = { quitApp() })
    val discord = DiscordPresence { videoId ->
        tube.upNext(videoId)
            .firstOrNull { it.videoId == videoId }
            ?.thumbnails
            ?.filter {
                // Square YouTube Music art only (yt3/lh3); never a plain
                // YouTube video thumbnail.
                val host = it.url.substringAfter("://", "").substringBefore("/").lowercase()
                val size = Regex("""=w(\d+)-h(\d+)""").find(it.url)
                "googleusercontent.com" in host && "ytimg" !in host &&
                    ((it.width > 0 && it.height > 0 && it.width == it.height) ||
                        (size != null && size.groupValues[1] == size.groupValues[2]))
            }
            ?.maxByOrNull { it.width }
            ?.url
    }
    val sys = SysHandles(mpris, discord, isLinux)
    val oauth = GoogleOAuth(tube)
    // Restore the previous session (queue paused at its position) before
    // the UI shows, so relaunching never resets to 0:00.
    player.restoreSession()
    val appState = AppState(tube, player, sys, oauth)

    if (isLinux && SysConfig.mprisEnabled) {
        installDesktopEntry()
        sysScope.launch {
            // The bus name can be briefly unavailable at startup (stale
            // owner, session race) — retry instead of failing silently.
            var ok = false
            repeat(6) { attempt ->
                // The user may turn MPRIS off while the startup retry loop is
                // waiting; do not resurrect it after that toggle.
                if (!SysConfig.mprisEnabled) return@launch
                if (mpris.start()) {
                    ok = true
                    println("MPRIS active: ${MprisService.BUS_NAME}")
                    sys.setMprisError(null)
                    sys.refreshMprisState()
                    return@launch
                }
                sys.setMprisError(mpris.lastError ?: "unknown error (attempt ${attempt + 1}/6)")
                kotlinx.coroutines.delay(2000.milliseconds)
            }
            @Suppress("KotlinConstantConditions") // false positive: `ok` can be set to true inside the repeat lambda
            if (!ok) {
                sys.setMprisError((mpris.lastError ?: "failed to start") + " — toggle MPRIS off/on in Settings to retry")
                sys.refreshMprisState()
            }
        }
    }
    sysScope.launch {
        player.state.collect { discord.update(it) }
    }
    Runtime.getRuntime().addShutdownHook(Thread {
        player.saveSession()
        mpris.stop()
        discord.shutdown()
        try {
            engine.release()
        } catch (_: Exception) {
        }
    })

    application {
        quitApp = { exitApplication() }
        val windowState = rememberWindowState(size = DpSize(1280.dp, 800.dp))
        Window(
            onCloseRequest = ::exitApplication,
            state = windowState,
            title = "NixieTube",
        ) {
            App(appState)
        }
    }
}
