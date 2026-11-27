package com.example.nixietube

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI, gives audio_service its shared engine, and lets
 * Dart read the WebView cookie jar.
 *
 * The media session (notification, lock screen, Android Auto, headset
 * buttons) runs in an Android service that may outlive the activity, so
 * the activity has to hand it the same FlutterEngine instead of owning a
 * private one. AudioServiceActivity provides that plumbing; inheriting
 * from it is the whole integration.
 */
class MainActivity : AudioServiceActivity() {
    private var flutterEngine: FlutterEngine? = null

    /** Request code for the Android 13+ notification permission. */
    private val notificationsRequest = 1001

    /**
     * Cookie reader for the in-app sign-in page.
     *
     * `CookieManager.getCookie(url)` returns every cookie set for that
     * URL, HttpOnly ones included: unlike `document.cookie` it reads the
     * cookie store itself, which is where the YouTube session cookies
     * (`SAPISID`, `__Secure-1PSID`, …) that InnerTube authenticates with
     * live. Without this channel a phone would have to sign in on a
     * computer and paste the header by hand.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        this.flutterEngine = flutterEngine
        // Discord Social SDK bridge (AIDL RPC to the installed Discord app).
        flutterEngine.plugins.add(DiscordSdkPlugin())
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nixietube/cookies",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url")
                        ?: "https://music.youtube.com"
                    result.success(CookieManager.getInstance().getCookie(url))
                }
                else -> result.notImplemented()
            }
        }
        // Notification permission: Android 13+ suppresses the playback
        // notification, foreground-service one included, until the user
        // grants it. Dart asks once at startup and reposts the media
        // state when the answer is yes.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nixietube/permissions",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "notificationsGranted" -> result.success(hasNotificationPermission())
                "requestNotifications" -> {
                    if (hasNotificationPermission() || Build.VERSION.SDK_INT < 33) {
                        result.success(true)
                    } else {
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            notificationsRequest,
                        )
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Whether notifications may be posted (always true below Android 13). */
    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationsRequest) {
            // Tell Dart whether it can draw the playback notification now.
            try {
                MethodChannel(
                    flutterEngine!!.dartExecutor.binaryMessenger,
                    "nixietube/permissions",
                ).invokeMethod("notificationsResult", hasNotificationPermission())
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        // Closing the app closes it for good: when the user finishes the
        // activity (back gesture), tell Dart to stop playback and take the
        // media notification down, so the notification panel ends in the
        // same state a fully closed app leaves behind. The audio_service
        // engine outlives the activity, so the call still lands in Dart.
        if (isFinishing) {
            try {
                MethodChannel(
                    flutterEngine!!.dartExecutor.binaryMessenger,
                    "nixietube/lifecycle",
                ).invokeMethod("closeForGood", null)
            } catch (_: Exception) {
            }
        }
        super.onDestroy()
    }
}
